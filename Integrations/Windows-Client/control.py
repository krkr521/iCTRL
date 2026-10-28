"""Windows USB transport and DPAPI storage for the official iCTRL client."""
from __future__ import annotations

import argparse
import asyncio
import base64
import ctypes
import contextvars
from ctypes import wintypes
import http.client
import ipaddress
import json
import logging
import msvcrt
import os
import re
from pathlib import Path
import socket
import subprocess
import sys
import time
import webbrowser
import contextlib
import threading
from automation_session import AutomationSession, requires_ui
from native_session import NativeSession

import psutil

import ictrl_rpc as rpc
import ssh_transport
import remote_page
import file_transfer
from browser_download import DownloadSpool

HERE = Path(__file__).resolve().parent
STATE = HERE / ".state"
KEYS = STATE / "pairing.dpapi"
STOP = STATE / "bridge.stop"
CONNECTION = STATE / "connection.json"
PORT = 18200
IDENTITY_TIMEOUT = 6.0
SSH_GET_TIMEOUT = 10.0
BRIDGE_LOCAL_START_TIMEOUT = 8.0
HOST = f"127.0.0.1:{PORT}"
REMOTE = f"http://{HOST}/remote"


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


class Blob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_ubyte))]


def dpapi(data: bytes, *, decrypt: bool = False) -> bytes:
    """Current-user Windows encryption; the key never goes to console or JSON."""
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    raw = ctypes.create_string_buffer(data)
    source = Blob(len(data), ctypes.cast(raw, ctypes.POINTER(ctypes.c_ubyte)))
    result = Blob()
    if decrypt:
        operation = crypt.CryptUnprotectData
        operation.restype = wintypes.BOOL
        operation.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p,
                              ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD,
                              ctypes.POINTER(Blob)]
        ok = operation(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(result))
    else:
        operation = crypt.CryptProtectData
        operation.restype = wintypes.BOOL
        operation.argtypes = [ctypes.POINTER(Blob), wintypes.LPCWSTR, ctypes.c_void_p,
                              ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD,
                              ctypes.POINTER(Blob)]
        ok = operation(ctypes.byref(source), "iCTRL Windows pairing", None, None, None, 1,
                       ctypes.byref(result))
    if not ok:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return ctypes.string_at(result.pbData, result.cbData)
    finally:
        kernel.LocalFree(ctypes.cast(result.pbData, ctypes.c_void_p))


def read_keys() -> dict:
    if not KEYS.exists():
        return {}
    return json.loads(dpapi(KEYS.read_bytes(), decrypt=True).decode("utf-8"))


def save_key(device_key: str, record: dict):
    records = read_keys()
    records[device_key] = record
    STATE.mkdir(exist_ok=True)
    pending = STATE / "pairing.dpapi.tmp"
    pending.write_bytes(dpapi(json.dumps(records).encode("utf-8")))
    os.replace(pending, KEYS)


# Keep the upstream pairing/cryptography unchanged; replace only its file store.
rpc.save_token = save_key


def get_json(path: str, timeout: float | None = None) -> dict:
    if timeout is None:
        timeout = SSH_GET_TIMEOUT if connection_target()["transport"] == "ssh" else 5
    connection = http.client.HTTPConnection("127.0.0.1", PORT, timeout=timeout)
    try:
        connection.request("GET", path)
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError(f"iCTRL HTTP {response.status}")
        return json.loads(response.read())
    finally:
        connection.close()


def port_open() -> bool:
    try:
        with socket.create_connection(("127.0.0.1", PORT), timeout=0.5):
            return True
    except OSError:
        return False


def connection_target() -> dict:
    if not CONNECTION.exists():
        return {"transport": "usb"}
    target = json.loads(CONNECTION.read_text(encoding="utf-8"))
    if target.get("transport") == "usb":
        return {"transport": "usb"}
    if target.get("transport") == "ssh":
        return {"transport": "ssh", "ssh_alias": ssh_transport.validate_alias(target.get("ssh_alias", "home-server"))}
    if target.get("transport") != "lan":
        raise ValueError("Unsupported phone connection transport")
    address = ipaddress.IPv4Address(target["host"])
    if not any(address in ipaddress.IPv4Network(n) for n in
               ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")):
        raise ValueError("LAN mode requires the phone's private IPv4 address")
    return {"transport": "lan", "host": str(address)}


def bridge_owned() -> bool:
    """Refuse to reuse another program listening at the browser's origin."""
    try:
        metadata = json.loads((STATE / "bridge.json").read_text(encoding="utf-8"))
        if metadata.get("port") != PORT or metadata.get("bind") != "127.0.0.1":
            return False
        process = psutil.Process(int(metadata["pid"]))
        arguments = process.cmdline()
        script = os.path.normcase(str(HERE / "control.py"))
        if "_bridge" not in arguments or not any(
            os.path.normcase(os.path.abspath(a)) == script for a in arguments[1:]
        ):
            return False
        return any(c.status == psutil.CONN_LISTEN and c.laddr.ip == "127.0.0.1"
                   and c.laddr.port == PORT for c in process.net_connections(kind="tcp"))
    except (OSError, ValueError, KeyError, psutil.Error):
        return False


def bridge_lock_available() -> bool:
    lock_path = STATE / "bridge.lock"
    if not lock_path.exists():
        return True
    with lock_path.open("r+b") as lock:
        lock.seek(0)
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            return False
        msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
        return True


def checked_request_header(header: bytes) -> bytes:
    """Validate the browser origin without touching bodies or stream tickets."""
    lines = header.decode("iso-8859-1").split("\r\n")
    method, target, version = lines[0].split(" ")
    if (method not in {"GET", "POST", "HEAD", "OPTIONS"}
        and not (method == 'DELETE' and target.startswith('/__ictrl/clipboard/'))) or not target.startswith("/"):
        raise ValueError("Unsupported request")
    if version not in {"HTTP/1.0", "HTTP/1.1"}:
        raise ValueError("Unsupported HTTP version")
    headers = {}
    outgoing = [lines[0]]
    for line in lines[1:]:
        if not line:
            continue
        key, value = line.split(":", 1)
        key = key.strip().lower()
        value = value.strip()
        if key in headers:
            raise ValueError("Duplicate header")
        headers[key] = value
        if key not in {"connection", "proxy-connection"}:
            outgoing.append(line)
    if headers.get("host") != HOST:
        raise ValueError("Unexpected Host")
    if headers.get("origin") not in {None, f"http://{HOST}"}:
        raise ValueError("Unexpected Origin")
    if headers.get("sec-fetch-site") == "cross-site":
        raise ValueError("Cross-site request")
    if "transfer-encoding" in headers:
        raise ValueError("Chunked requests are not supported")
    # One HTTP request per TCP connection. H.264 responses remain streaming.
    return ("\r\n".join(outgoing) + "\r\nConnection: close\r\n\r\n").encode("iso-8859-1")


class PrefixedReader:
    def __init__(self, prefix, reader):
        self.prefix, self.reader = prefix, reader

    async def read(self, length):
        if self.prefix:
            chunk, self.prefix = self.prefix[:length], self.prefix[length:]
            return chunk
        return await self.reader.read(length)


def clipboard_request_header(header: bytes) -> bytes:
    """Called only after the browser Host/Origin guard, for the private job API."""
    lines = header.decode('iso-8859-1').split('\r\n')
    method, target, version = lines[0].split(' ')
    path = target.removeprefix('/__ictrl/clipboard')
    if not re.fullmatch(r'/jobs(?:/[A-Za-z0-9_-]{43})?', path):
        raise ValueError('Unsupported clipboard job path')
    if method not in {'GET', 'POST', 'DELETE'}:
        raise ValueError('Unsupported clipboard job method')
    outgoing = [f'{method} {path} {version}', 'Host: 127.0.0.1:18303']
    for line in lines[1:]:
        if not line:
            continue
        name = line.split(':', 1)[0].strip().lower()
        if name not in {'host', 'origin', 'connection', 'proxy-connection'}:
            outgoing.append(line)
    return ('\r\n'.join(outgoing) + '\r\nConnection: close\r\n\r\n').encode('iso-8859-1')


async def _transport_unavailable(writer):
    payload = b'{"error":{"code":"transport_unavailable_before_send","message":"Owned SSH transport is reconnecting; no request was forwarded."}}'
    writer.write(b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: "
                 + str(len(payload)).encode("ascii") + b"\r\n\r\n" + payload)
    await writer.drain()


async def _pipe_once(reader, writer):
    while chunk := await reader.read(65536):
        writer.write(chunk)
        await writer.drain()


async def forward_ssh_once(header, reader, writer, supervisor, connect):
    """One upstream connection, one header write, never wait for/retry a tunnel.

    A 503 is allowed only before any upstream request write. Once even the
    header may have been submitted, failure closes this connection as unknown.
    Generation loss cannot move an old request to a new SSH forwarding job.
    """
    token = supervisor.ready_generation()
    remote = None
    connecting = None
    lost = None
    pipes = []
    submitted = False
    try:
        if token is None:
            await _transport_unavailable(writer)
            return
        lost = asyncio.create_task(token[1].wait())
        connecting = asyncio.create_task(connect())
        done, _ = await asyncio.wait({connecting, lost}, return_when=asyncio.FIRST_COMPLETED)
        if connecting not in done:
            await _transport_unavailable(writer)
            return
        remote = connecting.result()
        if not supervisor.is_current(token):
            await _transport_unavailable(writer)
            return
        submitted = True  # Set BEFORE write: a partial write is also unknown.
        remote.writer.write(header)
        await remote.writer.drain()
        if not supervisor.is_current(token):
            return
        pipes = [asyncio.create_task(_pipe_once(reader, remote.writer)),
                 asyncio.create_task(_pipe_once(remote.reader, writer))]
        await asyncio.wait({*pipes, lost}, return_when=asyncio.FIRST_COMPLETED)
    except Exception:
        if not submitted:
            await _transport_unavailable(writer)
        # Never log request headers/bodies or synthesize "not sent" after write.
    finally:
        tasks = [task for task in [connecting, lost, *pipes] if task is not None]
        for task in tasks:
            if not task.done():
                task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        if remote is None and connecting is not None and not connecting.cancelled():
            try:
                remote = connecting.result()
            except BaseException:
                pass
        if remote is not None:
            with contextlib.suppress(Exception):
                await remote.close()
        writer.close()
        with contextlib.suppress(ConnectionError, OSError):
            await writer.wait_closed()


async def serve_bridge():
    from pymobiledevice3.service_connection import ServiceConnection
    from pymobiledevice3.tcp_forwarder import UsbmuxTcpForwarder
    from pymobiledevice3.usbmux import list_devices

    target = connection_target()
    ssh_supervisor = None
    download_spool = DownloadSpool()
    clipboard_channel = contextvars.ContextVar('ictrl_clipboard_channel', default=False)

    class BrowserSafeForwarder(UsbmuxTcpForwarder):
        async def _establish_remote_connection(self):
            if target["transport"] == "lan":
                return await ServiceConnection.create_using_tcp(target["host"], 8200,
                                                                create_connection_timeout=8)
            # SSH is handled by forward_ssh_once, never by this upstream method
            # that would retain the local header/body while establishing a link.
            return await super()._establish_remote_connection()

        async def _handle_server_connection(self, reader, writer):
            task = asyncio.current_task()
            self._connection_tasks.add(task)
            delegated = False
            channel_token = None
            try:
                header = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
                if len(header) > 16384:
                    raise ValueError("Header too large")
                header = checked_request_header(header)
                method, request_target, _ = header.split(b'\r\n', 1)[0].decode('iso-8859-1').split(' ')
                if await download_spool.handle(method, request_target, header, reader, writer):
                    return
                if method in {'GET', 'HEAD'}:
                    local_asset = remote_page.asset(request_target)
                    if local_asset is not None:
                        mime, payload = local_asset
                        writer.write(remote_page.response(mime, payload, head=method == 'HEAD'))
                        await writer.drain()
                        return
                if request_target.startswith('/__ictrl/clipboard/'):
                    if target['transport'] != 'ssh':
                        writer.write(b'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                        await writer.drain()
                        return
                    header = clipboard_request_header(header)
                    channel_token = clipboard_channel.set(True)
                if target['transport'] == 'ssh':
                    port = ssh_transport.CLIPBOARD_PORT if clipboard_channel.get() else ssh_transport.DATA_PORT
                    delegated = True
                    await forward_ssh_once(header, reader, writer, ssh_supervisor,
                        lambda: ServiceConnection.create_using_tcp('127.0.0.1', port,
                                                                   create_connection_timeout=8))
                    return
                delegated = True
                await super()._handle_server_connection(PrefixedReader(header, reader), writer)
            except (ValueError, asyncio.LimitOverrunError):
                writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                await writer.drain()
            except (asyncio.IncompleteReadError, asyncio.TimeoutError, ConnectionError):
                pass
            finally:
                if channel_token is not None:
                    clipboard_channel.reset(channel_token)
                self._connection_tasks.discard(task)
                if not delegated:
                    writer.close()
                    try:
                        await writer.wait_closed()
                    except ConnectionError:
                        pass

    STATE.mkdir(exist_ok=True)
    # One owner per folder; lock is automatically released when the process exits.
    with (STATE / "bridge.lock").open("a+b") as lock:
        lock.seek(0)
        if not lock.read(1):
            lock.write(b"0")
            lock.flush()
        lock.seek(0)
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            return
        serial = None
        if target["transport"] == "usb":
            devices = [d for d in await list_devices() if d.connection_type == "USB"]
            if len(devices) != 1:
                raise RuntimeError("Connect exactly one iPhone by USB before starting.")
            serial = devices[0].serial
        STOP.unlink(missing_ok=True)
        metadata = STATE / "bridge.json"
        def write_metadata(supervisor=None):
            value = {"pid": os.getpid(), "port": PORT, "bind": "127.0.0.1",
                     "target_port": 8200, "target": target}
            if supervisor is not None:
                value.update(ssh_state=supervisor.state,
                             ssh_generation=supervisor.generation,
                             ssh_initial_attempt_done=supervisor.initial_attempt_done)
            pending = metadata.with_suffix('.json.tmp')
            pending.write_text(json.dumps(value), encoding="utf-8")
            os.replace(pending, metadata)
        if target["transport"] == "ssh":
            ssh_supervisor = ssh_transport.TunnelSupervisor(target["ssh_alias"], STATE,
                                                            on_state=write_metadata)
        supervisor_task = None
        ready = asyncio.Event()
        forwarder = BrowserSafeForwarder(
            serial, 8200, PORT, ready, usbmux_connection_type="USB"
        )
        server_task = asyncio.create_task(forwarder.start(address="127.0.0.1"))
        ready_task = asyncio.create_task(ready.wait())
        try:
            done, _ = await asyncio.wait({server_task, ready_task},
                                         return_when=asyncio.FIRST_COMPLETED)
            if server_task in done:
                await server_task
                return
            # Local assets/listener become available before SSH startup. They
            # remain available during subsequent reconnect/backoff cycles.
            write_metadata(ssh_supervisor)
            if ssh_supervisor is not None:
                supervisor_task = asyncio.create_task(ssh_supervisor.run())
            while not STOP.exists() and not server_task.done():
                if supervisor_task is not None and supervisor_task.done():
                    await supervisor_task
                    raise RuntimeError("The owned SSH supervisor stopped")
                await asyncio.sleep(0.5)
        finally:
            ready_task.cancel()
            if ssh_supervisor is not None:
                ssh_supervisor.request_stop()
            forwarder.stop()
            try:
                await server_task
            finally:
                if supervisor_task is not None:
                    await asyncio.shield(supervisor_task)
                (STATE / "bridge.json").unlink(missing_ok=True)
                STOP.unlink(missing_ok=True)


def start_bridge():
    if port_open():
        if bridge_owned():
            return
        raise RuntimeError("Port 18200 is owned by another program; refusing to reuse this browser origin.")
    for _ in range(24):
        if bridge_lock_available():
            break
        time.sleep(0.25)
    else:
        raise RuntimeError("The previous phone bridge is still starting or shutting down; retry shortly.")
    STATE.mkdir(exist_ok=True)
    with (STATE / "bridge.log").open("ab") as log:
        bridge_job = subprocess.Popen([sys.executable, str(HERE / "control.py"), "_bridge"],
                                      cwd=str(HERE), stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                      creationflags=subprocess.CREATE_NO_WINDOW)
    # A failed Python/import/lock startup must not consume an SSH dial budget.
    deadline = time.monotonic() + BRIDGE_LOCAL_START_TIMEOUT
    while time.monotonic() < deadline:
        if port_open() and bridge_owned():
            break
        if bridge_job.poll() is not None:
            raise RuntimeError("The local phone bridge exited before listening; check .state/bridge.log.")
        time.sleep(0.25)
    else:
        raise RuntimeError("Local phone bridge startup pending: no owned listener within the local startup budget; check .state/bridge.log.")
    if connection_target()["transport"] != "ssh":
        return
    # Only a newly launched bridge waits for its first attempt's result; an
    # existing reconnecting listener returns above and fails requests fast.
    # Neither phase contains an HTTP/RPC request that could be sent later.
    deadline = time.monotonic() + ssh_transport.START_RESULT_BUDGET
    while time.monotonic() < deadline:
        if bridge_job.poll() is not None and not bridge_owned():
            raise RuntimeError("The local phone bridge stopped during SSH startup; check .state/bridge.log.")
        try:
            initial_done = json.loads((STATE / "bridge.json").read_text(encoding="utf-8")).get("ssh_initial_attempt_done", True)
        except (OSError, ValueError):
            initial_done = False
        if initial_done:
            return
        time.sleep(0.25)
    raise RuntimeError("SSH startup is still pending; no control request was sent. The local page is retained.")


def stop_bridge():
    if not port_open():
        if not bridge_lock_available():
            raise RuntimeError("Phone bridge is still starting or shutting down; retry shortly.")
        emit({"bridge_stopped": True})
        return
    if not bridge_owned():
        raise RuntimeError("Port 18200 is not owned by this phone bridge; it was left untouched.")
    STOP.touch()
    for _ in range(90):
        if not port_open() and bridge_lock_available():
            emit({"bridge_stopped": True})
            return
        time.sleep(0.2)
    raise RuntimeError("Bridge has not stopped yet; no process was terminated.")


def identity() -> str:
    try:
        # Allow the SSH gateway's bounded eight-second dial to finish before
        # declaring this read-only preflight unavailable. No RPC was sent yet.
        identity_timeout = SSH_GET_TIMEOUT if connection_target()["transport"] == "ssh" else IDENTITY_TIMEOUT
        info = get_json("/whoami", timeout=identity_timeout)
    except (OSError, http.client.HTTPException):
        # Identity is a read-only preflight; no encrypted command was submitted.
        # A failure after the RPC POST must remain ambiguous and is never retried.
        raise RuntimeError(
            "iPhone connection check failed before any control command was sent. "
            "Check phone connectivity or run: Phone.cmd gateway-status"
        ) from None
    device_id = info.get("device_id")
    if not isinstance(device_id, str) or not device_id:
        raise RuntimeError("iCTRL did not provide a device identity.")
    return rpc.device_store_key(device_id)


def _rpc_call_raw(method: str, params: dict | None = None, timeout: float = 60, *, expected_device: str | None = None) -> dict:
    device = identity()
    if expected_device is not None and device != expected_device:
        raise RuntimeError("Phone identity changed during automation session; no RPC sent")
    try:
        record = read_keys().get(device)
    except OSError as error:
        # A local authorization-store failure is not a transient status read.
        raise RuntimeError("Saved phone authorization unavailable; no RPC sent") from error
    if record is None:
        raise RuntimeError("This iPhone is not paired with Codex Windows. Run: Phone.cmd pair")
    status, response = rpc._call_with(HOST, record, method, params, timeout, 1)
    if status != 200:
        if status == 401:
            error = response.get("error", {})
            code = error.get("code") if isinstance(error, dict) else None
            guidance = {
                "auth_failed": "Phone authorization expired or was revoked. Run: Phone.cmd pair --replace",
                "ts_skew": "Windows and iPhone clocks differ. Synchronize their date and time.",
                "nonce_replayed": "The phone rejected a repeated request nonce; no action was retried.",
                "nonce_flood": "The phone requested fewer concurrent authentication requests.",
                "bad_tag": "Request authentication failed; check the saved pairing and transport.",
                "auth_required": "The phone requires an encrypted request envelope.",
            }
            raise RuntimeError(guidance.get(code, "iCTRL returned an authentication error (HTTP 401)."))
        raise RuntimeError(f"iCTRL rejected the call (HTTP {status}). Check authorization on the phone.")
    if "error" in response:
        error = response["error"]
        raise RuntimeError(f"iCTRL {error.get('code', '')}: {error.get('message', 'RPC failed')}")
    return response.get("result", response)


_AUTOMATION_LOCK = threading.Lock()
_AUTOMATION_CONTEXT = contextvars.ContextVar("ictrl_automation_session", default=None)

@contextlib.contextmanager
def automation_session(*, legacy_setup=False, ttl_seconds=120, expected_device_key=None, legacy_recovery=False):
    if _AUTOMATION_CONTEXT.get() is not None:
        raise RuntimeError("Nested automation sessions are not allowed")
    expected_device = identity()
    if expected_device_key is not None and expected_device != expected_device_key:
        raise RuntimeError("Authenticated device identity changed before session")
    def raw(method, params, timeout=5):
        try:
            return _rpc_call_raw(method, params, timeout=timeout, expected_device=expected_device)
        except SystemExit as error:
            raise OSError("Authenticated transport verification failed; outcome unknown") from error
    if not legacy_setup and not legacy_recovery:
        from managed_autolock import ManagedAutoLock
        previous = ManagedAutoLock(STATE / "autolock").status(expected_device, "codex-windows")
        if previous.get("status") != "no_record":
            raise RuntimeError("LegacyAutoLockRecoveryRequired")
    # Schema discovers support only; it is never proof of native runtime readiness.
    methods = get_json("/schema").get("methods", [])
    supported = any(m.get("name") == "automation_begin" for m in methods if isinstance(m, dict))
    if not _AUTOMATION_LOCK.acquire(blocking=False):
        raise RuntimeError("Another automation task owns this client; not queued")
    try:
        session_type = AutomationSession if legacy_setup or legacy_recovery else NativeSession
        session_scope = session_type(raw, legacy_setup=legacy_setup, supports_quiet=supported, ttl_seconds=ttl_seconds)
        session_scope.bound_device_key = expected_device
        with session_scope as session:
            token = _AUTOMATION_CONTEXT.set(session)
            try:
                yield session
            finally:
                _AUTOMATION_CONTEXT.reset(token)
    finally:
        _AUTOMATION_LOCK.release()

def rpc_call(method: str, params: dict | None = None, timeout: float = 60) -> dict:
    active = _AUTOMATION_CONTEXT.get()
    if active is not None:
        return active.call(method, params,
            raw=lambda m, p: active.raw(m, p, timeout=timeout))
    return _rpc_call_raw(method, params, timeout)

def cli_rpc_call(method, params=None, *, legacy_setup=False):
    if not requires_ui(method):
        return rpc_call(method, params)
    with automation_session(legacy_setup=legacy_setup):
        return rpc_call(method, params)


def main() -> int:
    parser = argparse.ArgumentParser(description="iPhone control from Windows over USB, LAN or existing SSH")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("start", "stop", "status", "browser", "_bridge"):
        commands.add_parser(name)
    pair_parser = commands.add_parser("pair")
    pair_parser.add_argument("--replace", action="store_true", help="Request fresh phone approval")
    lan_parser = commands.add_parser("use-lan")
    lan_parser.add_argument("address", help="iPhone private IPv4 address, without port")
    commands.add_parser("use-usb")
    ssh_parser = commands.add_parser("use-ssh")
    ssh_parser.add_argument("alias", nargs="?", default="home-server")
    commands.add_parser("gateway-status")
    call_parser = commands.add_parser("call")
    call_parser.add_argument("method")
    call_parser.add_argument("--json", default="{}", help="JSON object of method parameters")
    call_parser.add_argument("--params", type=Path, help="UTF-8 JSON parameters file")
    shot_parser = commands.add_parser("shot")
    shot_parser.add_argument("output", type=Path)
    files = commands.add_parser("files")
    file_commands = files.add_subparsers(dest="file_command", required=True)
    file_commands.add_parser("list")
    up = file_commands.add_parser("upload")
    up.add_argument("source", type=Path)
    up.add_argument("--companion-bundle")
    up.add_argument("--legacy-setup", action="store_true", help="Explicit non-quiet setup only")
    down = file_commands.add_parser("download")
    down.add_argument("id")
    down.add_argument("--output", type=Path)
    down.add_argument("--directory", type=Path)
    fs = file_commands.add_parser("status")
    fs.add_argument("id")
    call_parser.add_argument("--legacy-setup", action="store_true", help="Explicit non-quiet setup on old/disabled Runner only")
    args = parser.parse_args()
    if args.command == "_bridge":
        logging.basicConfig(level=logging.CRITICAL)
        asyncio.run(serve_bridge())
        return 0
    if args.command == "stop":
        stop_bridge()
        return 0
    if args.command in {"use-lan", "use-usb", "use-ssh"}:
        target = {"transport": "usb"}
        if args.command == "use-ssh":
            target = {"transport": "ssh", "ssh_alias": ssh_transport.validate_alias(args.alias)}
        if args.command == "use-lan":
            address = ipaddress.IPv4Address(args.address)
            if not any(address in ipaddress.IPv4Network(n) for n in
                       ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")):
                raise ValueError("Use the iPhone's private LAN IPv4 address")
            target = {"transport": "lan", "host": str(address)}
        stop_bridge()
        STATE.mkdir(exist_ok=True)
        if CONNECTION.exists():
            (STATE / "connection.previous.json").write_text(CONNECTION.read_text(encoding="utf-8"), encoding="utf-8")
        CONNECTION.write_text(json.dumps(target), encoding="utf-8")
        start_bridge()
        schema = get_json("/schema")
        emit({"phone_ready": True, "transport": target["transport"],
              "server_version": schema.get("server_version"), "browser": REMOTE})
        return 0
    start_bridge()
    if args.command == "gateway-status":
        if connection_target()["transport"] != "ssh":
            raise RuntimeError("Gateway status requires use-ssh mode")
        connection = http.client.HTTPConnection("127.0.0.1", ssh_transport.HEALTH_PORT, timeout=5)
        try:
            connection.request("GET", "/health")
            response = connection.getresponse()
            emit(json.loads(response.read()))
        finally:
            connection.close()
    elif args.command == "start":
        schema = get_json("/schema")
        emit({"phone_ready": True, "transport": connection_target()["transport"],
              "server_version": schema.get("server_version"), "browser": REMOTE})
    elif args.command == "status":
        schema = get_json("/schema")
        emit({"phone_ready": True, "transport": connection_target()["transport"], "server_version": schema.get("server_version"),
              "codex_key_saved": identity() in read_keys(), "browser": REMOTE})
    elif args.command == "pair":
        device_key = identity()
        if device_key in read_keys() and not args.replace:
            rpc_call("logs", {"max_elements": 1})
            emit({"codex_paired": True, "authorization_verified": True})
        else:
            rpc.pair(HOST, "Codex Windows", plain=False, timeout=90, store_key=device_key)
            emit({"codex_paired": True, "storage": "Windows current-user DPAPI"})
    elif args.command == "browser":
        webbrowser.open(REMOTE)
        emit({"browser": REMOTE})
    elif args.command == "call":
        raw = args.params.read_text(encoding="utf-8-sig") if args.params else args.json
        params = json.loads(raw)
        if not isinstance(params, dict):
            raise ValueError("Parameters must be a JSON object.")
        if args.method == "screenshot":
            raise ValueError("Use 'shot FILE.jpg' to save image bytes without printing base64.")
        emit(cli_rpc_call(args.method, params, legacy_setup=args.legacy_setup))
    elif args.command == "files":
        if args.file_command == "list":
            emit(rpc_call("file_list", {"direction":"phone_to_pc"}))
        elif args.file_command == "status":
            emit(file_transfer.checked_status(rpc_call, args.id))
        elif args.file_command == "upload":
            # Upload save/restore uses activate_app, so acquire one batch lease.
            with automation_session(legacy_setup=args.legacy_setup):
                emit(file_transfer.upload(rpc_call, args.source, args.companion_bundle))
        else:
            emit(file_transfer.download(rpc_call, args.id, args.directory, args.output))
    elif args.command == "shot":
        result = rpc_call("screenshot", {"format": "jpeg", "scale": 1, "quality": 0.7})
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(base64.b64decode(result["data"]))
        emit({"saved": str(args.output.resolve()), "pixel_width": result.get("pixel_width"),
              "pixel_height": result.get("pixel_height")})
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as exc:
        # Do not include raw HTTP responses, pairing records or request envelopes.
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
