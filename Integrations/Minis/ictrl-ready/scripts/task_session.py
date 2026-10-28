"""Private, bounded Minis task worker. Import and --help do not contact a device."""
import argparse
import contextlib
import hashlib
import json
import math
import os
import re
import secrets
import subprocess
import sys
import threading
import time
from pathlib import Path

MAX_REQUEST = 1024 * 1024
ID = re.compile(r"^[0-9a-f]{32}$")
METHOD = re.compile(r"^[a-z][a-z0-9_]{0,63}$")


def root():
    return Path.home() / ".ictrl" / "tasks"


def prepare(base):
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    if base.is_symlink() or not base.is_dir():
        raise ValueError("invalid task directory")
    os.chmod(base, 0o700)


@contextlib.contextmanager
def locked(base):
    import fcntl
    prepare(base)
    fd = os.open(base / "lock", os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def sync_dir(path):
    if os.name == "nt": return  # Offline fake tests only; runtime locking requires POSIX.
    d = os.open(path, os.O_RDONLY)
    try: os.fsync(d)
    finally: os.close(d)


def atomic(path, obj):
    data = json.dumps(obj, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode()
    tmp = path.parent / ("." + secrets.token_hex(16))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
        sync_dir(path.parent)
    finally:
        if tmp.exists(): tmp.unlink()


def read(path, limit=MAX_REQUEST):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as f:
        data = f.read(limit + 1)
    if len(data) > limit: raise ValueError("file too large")
    return json.loads(data)


def validate(command):
    if not isinstance(command, dict) or set(command) != {"method", "params"}:
        raise ValueError("invalid command")
    method, params = command["method"], command["params"]
    if not isinstance(method, str) or not METHOD.fullmatch(method) or method.startswith("automation_"):
        raise ValueError("invalid method")
    if not isinstance(params, dict) or "automation_session" in params:
        raise ValueError("invalid params")
    encoded = json.dumps(command, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode()
    if len(encoded) > MAX_REQUEST: raise ValueError("request too large")
    return encoded


def alive(pid):
    try: os.kill(pid, 0); return True
    except (OSError, TypeError): return False


def current(base):
    try:
        task = read(base / "active")
        if not isinstance(task, str) or not ID.fullmatch(task): raise ValueError("invalid active pointer")
        directory = base / task
        if directory.is_symlink() or not directory.is_dir(): raise ValueError("invalid task directory")
        return task, directory
    except FileNotFoundError:
        return None, None


def public_status(directory):
    state = read(directory / "state")
    phase = state.get("phase", "unknown")
    if phase not in {"starting", "running", "stopping", "complete", "unknown"}: phase = "unknown"
    if phase in {"starting", "running", "stopping"} and not alive(state.get("pid")):
        phase = "unknown"
    from automation_session import _QUIET_PHASES
    out = {"ttl_seconds": state.get("ttl_seconds", 300), "status": phase, "restore": state.get("restore", "pending") if phase == "complete" else "pending"}
    if phase == "running" and type(state.get("body_deadline")) in (int, float) and math.isfinite(state["body_deadline"]):
        out["remaining_body_seconds"] = max(0, int(state["body_deadline"] - time.monotonic()))
    if phase == "stopping" and type(state.get("remaining_body_seconds")) is int:
        out["remaining_body_seconds"] = max(0, state["remaining_body_seconds"])
    for key in ("quiet_phase", "quiet_cleanup_phase"):
        if state.get(key) in _QUIET_PHASES: out[key] = state[key]
    out["return_to_chat"] = state.get("return_to_chat", {"status":"not_attempted", "verified":False})
    return out



def prepare_origin(base, task_id=None, nonce=None):
    task_id = task_id or secrets.token_hex(16); nonce = nonce or secrets.token_hex(16)
    if not ID.fullmatch(task_id) or not ID.fullmatch(nonce): raise ValueError("invalid origin correlation")
    with locked(base):
        folder = base / "origins"
        folder.mkdir(exist_ok=True, mode=0o700)
        if folder.is_symlink() or not folder.is_dir(): raise ValueError("invalid origin directory")
        path = folder / task_id
        value = {"kind":"ictrl_origin_prepared", "task_id":task_id, "origin_nonce":nonce}
        if path.exists():
            if read(path) != value: raise ValueError("origin preparation mismatch")
        else: atomic(path, value)
    return value


def automatic_origin(base, task_id):
    from origin_context import resolve_origin
    with locked(base):
        previous, directory = current(base)
        if previous == task_id:
            completion = read(directory / "state").get("completion", {})
            if completion.get("policy") == "return_chat":
                return completion_options("return_chat", completion.get("session_id"))["session_id"]
    prepared = read(base / "origins" / task_id)
    if prepared.get("task_id") != task_id: raise ValueError("origin preparation mismatch")
    return resolve_origin(task_id, prepared["origin_nonce"])["session_id"]


def completion_options(policy=None, origin_session_id=None, origin_title=None):
    # None preserves old on-disk tasks; new CLI tasks must choose the new contract.
    if policy is None:
        if origin_session_id is not None or origin_title is not None: raise ValueError("missing completion policy")
        return {"policy": "legacy_unconfirmed"}
    if policy not in {"return_chat", "stay"}: raise ValueError("invalid completion policy")
    if policy == "return_chat" and (not isinstance(origin_session_id, str) or
            not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", origin_session_id)):
        raise ValueError("trusted originating Minis session ID required")
    if origin_title is not None and (not isinstance(origin_title, str) or not 1 <= len(origin_title) <= 200):
        raise ValueError("invalid origin title")
    return {"policy": policy, "session_id": origin_session_id, "title": origin_title}


class MinisFinishTransport:
    """Minis-only cleanup: never changes Codex/Windows NativeSession policy."""
    def __init__(self, raw, completion):
        self.raw = raw
        self.completion = dict(completion)
        self.receipt = None
        self.finish_attempted = False
        self._finish_lock = threading.Lock()
        self.suppress_return = False

    def before_exit(self, kind, error, traceback):
        if kind is not None: self.suppress_return = True
        return False

    def __call__(self, method, params):
        if method == "automation_native_capabilities":
            value = self.raw(method, params)
            if type(value.get("minis_atomic_finish")) is not int or value["minis_atomic_finish"] != 1:
                from automation_session import AutomationUnavailable
                raise AutomationUnavailable("Minis atomic finish requires updated Runner")
            return value
        if method != "automation_native_end": return self.raw(method, params)
        policy = "skip_unknown" if self.suppress_return else self.completion["policy"]
        request = {"lease_id": params["lease_id"], "completion_policy": policy, "stop_service": True}
        if policy == "return_chat": request["origin_session_id"] = self.completion["session_id"]
        with self._finish_lock:
            if self.finish_attempted:
                from automation_session import RestorationUncertain
                raise RestorationUncertain("Minis finish already attempted; observe only")
            self.finish_attempted = True
        value = self.raw("automation_native_finish", request)
        if value.get("service_finish") != "closing":
            from automation_session import RestorationUncertain
            raise RestorationUncertain("Minis service finish not acknowledged; do not replay")
        self.receipt = {"service_finish": "closing", "return_route": value.get("return_route", "unavailable"),
                        "chat_verified": value.get("chat_verified") is True,
                        "policy": policy}
        return value


from native_session import NativeSession as _NativeSession

class MinisAutomationSession(_NativeSession):
    """Finish the owned lease once even when a bounded heartbeat join cannot settle."""
    def _cleanup(self):
        try:
            return super()._cleanup()
        except BaseException:
            transport = self.raw
            if (not isinstance(transport, MinisFinishTransport) or transport.finish_attempted or
                    self.lease_id is None or self._thread is None or not self._thread.is_alive()):
                raise
            # An in-flight heartbeat cannot revive the service's atomic finishing latch.
            # This does not retry an already-sent finish or any UI request.
            self._stop.set()
            transport.suppress_return = True
            try:
                value = transport("automation_native_end", {"lease_id": self.lease_id})
                self._validate(value, ("ended",))
                transport.receipt["heartbeat_join_unsettled"] = True
            finally:
                self.lease_id = None


def start_hash(task_id, store_key, client_path, ttl_seconds, completion=None):
    values = [task_id, store_key, client_path, ttl_seconds]
    if completion and completion.get("policy") != "legacy_unconfirmed": values.append(completion)
    raw = json.dumps(values, ensure_ascii=False, separators=(",", ":")).encode()
    return hashlib.sha256(raw).hexdigest()


def start(base, task_id, store_key, client_path=None, ttl_seconds=240, *, completion_policy="return_chat", origin_session_id=None, origin_title=None):
    completion = completion_options(completion_policy, origin_session_id, origin_title)
    if type(ttl_seconds) is not int or not 1 <= ttl_seconds <= 300: raise ValueError("invalid TTL")
    if not ID.fullmatch(task_id): raise ValueError("invalid task id")
    if not re.fullmatch(r"device:[A-Za-z0-9_-]{1,128}", store_key): raise ValueError("device store key required")
    request_hash = start_hash(task_id, store_key, client_path, ttl_seconds, completion)
    with locked(base):
        task, directory = current(base)
        if task:
            state = read(directory / "state")
            if state.get("store_key") != store_key or state.get("client_path") != client_path:
                raise ValueError("task ownership mismatch")
            status = public_status(directory)
            if task == task_id:
                if state.get("ttl_seconds", 300) != ttl_seconds or state.get("start_hash", request_hash) != request_hash: raise ValueError("task start mismatch")
                return {"task_id": task, **status}
            if status["status"] != "complete": raise RuntimeError("previous task not confirmed complete")
        if completion.get("policy") == "legacy_unconfirmed": raise ValueError("trusted originating Minis session ID required")
        if ttl_seconds <= 75: raise ValueError("TTL leaves no body budget")
        task = task_id; directory = base / task
        directory.mkdir(mode=0o700)
        atomic(directory / "state", {"phase": "starting", "pid": os.getpid(), "store_key":store_key, "client_path":client_path, "ttl_seconds":ttl_seconds, "start_hash":request_hash, "completion":completion})
        atomic(base / "active", task)
        log_fd = os.open(directory / "worker.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            argv = [sys.executable, str(Path(__file__).resolve()), "_worker", task, store_key, "--ttl-seconds", str(ttl_seconds)]
            if client_path: argv += ["--client-path", client_path]
            try:
                process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log_fd, stderr=log_fd, start_new_session=True, close_fds=True)
            except BaseException:
                atomic(directory / "state", {"phase": "unknown", "restore": "pending", "store_key":store_key, "client_path":client_path, "ttl_seconds":ttl_seconds, "start_hash":request_hash, "completion":completion})
                raise
            atomic(directory / "state", {"phase": "starting", "pid": process.pid, "store_key":store_key, "client_path":client_path, "ttl_seconds":ttl_seconds, "start_hash":request_hash, "completion":completion})
        finally: os.close(log_fd)
        return {"task_id": task, "status": "starting", "restore": "pending", "ttl_seconds":ttl_seconds}


def transport_budget(method, session, body, clock=time.monotonic, not_after=None):
    if method in {"automation_end", "automation_status", "automation_owner_status", "automation_native_end", "automation_native_finish", "automation_native_status"} and not body: return 5.0
    if session is None or not session.local_deadline: return 5.0
    deadline = session.local_deadline - (75 if body else 0)
    if body and not_after is not None: deadline = min(deadline, not_after)
    left = deadline - clock()
    if left <= 0: raise TimeoutError("task deadline")
    return left


class StartCancelled(Exception):
    pass


def worker(base, task, store_key, client_path=None, *, ttl_seconds=300, session_cls=None, manager_cls=None, managed=None, loader=None, clock=time.monotonic, sleep=time.sleep):
    from native_session import NativeSession as AutomationSession
    from managed_autolock import ManagedAutoLock
    from task_context import managed_task
    if loader is None:
        from minis_transport import load_transport
        loader = load_transport
    manager_cls = manager_cls or ManagedAutoLock; managed = managed or managed_task
    directory = base / task
    with locked(base):
        pass  # Parent persists the child PID before this worker can publish state.
    import fcntl
    lockfd = os.open(directory / "worker.lock", os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(lockfd); return
    state = read(directory / "state")
    if state.get("pid") != os.getpid() or state.get("phase") != "starting" or state.get("store_key") != store_key or state.get("client_path") != client_path or state.get("ttl_seconds", 300) != ttl_seconds or type(ttl_seconds) is not int or not 76 <= ttl_seconds <= 300:
        fcntl.flock(lockfd, fcntl.LOCK_UN); os.close(lockfd); return
    completion = state.get("completion", {"policy":"legacy_unconfirmed"})
    request_hash = start_hash(task, store_key, client_path, ttl_seconds, completion)
    if state.get("start_hash", request_hash) != request_hash:
        fcntl.flock(lockfd, fcntl.LOCK_UN); os.close(lockfd); return
    return_result = {"status":"not_attempted", "verified":False}
    finish_transport = None
    phase = {"body": False, "preparing": False, "not_after": None}; session = None; result = "unknown"; restore = "pending"; diagnostics = {}
    def budget(method):
        return transport_budget(method, session, phase["body"] or phase["preparing"], clock, phase["not_after"])
    try:
        with locked(base):
            if (directory / "stop").exists(): raise StartCancelled()
        raw, supported = loader(store_key, client_path=client_path, timeout_budget=budget)
        if completion.get("policy") in {"return_chat", "stay"}:
            finish_transport = MinisFinishTransport(raw, completion)
            raw = finish_transport
        selected_session = session_cls or (MinisAutomationSession if finish_transport is not None else AutomationSession)
        session = selected_session(raw, ttl_seconds=ttl_seconds, supports_quiet=supported)
        with contextlib.ExitStack() as stack:
            with locked(base):
                if (directory / "stop").exists(): raise StartCancelled()
                atomic(directory / "state", {"phase":"starting", "pid":os.getpid(), "store_key":store_key, "client_path":client_path, "ttl_seconds":ttl_seconds, "start_hash":request_hash, "stage_started":"begin"})
            stack.enter_context(session)
            if finish_transport is not None: stack.push(finish_transport.before_exit)
            with locked(base):
                if (directory / "stop").exists() or clock() >= session.local_deadline - 75: raise StartCancelled()
                atomic(directory / "state", {"phase":"starting", "pid":os.getpid(), "store_key":store_key, "client_path":client_path, "ttl_seconds":ttl_seconds, "start_hash":request_hash, "stage_started":"autolock"})
            manager = manager_cls(Path.home() / ".ictrl" / "autolock")
            phase["preparing"] = True
            try:
                task_state = stack.enter_context(managed(manager, store_key, "minis-agent", session))
            finally:
                phase["preparing"] = False
            if True:
                phase["body"] = True
                body_failed = False
                try:
                    atomic(directory / "state", {"phase":"running", "pid":os.getpid(), "store_key":store_key, "client_path":client_path, "ttl_seconds":ttl_seconds, "start_hash":request_hash, "body_deadline":session.local_deadline - 75})
                    while clock() < session.local_deadline - 75:
                        if (directory / "stop").exists(): break
                        with locked(base):
                            requests = sorted(directory.glob("req-*.json"))
                            if not requests:
                                request = None
                            else:
                                request = requests[0]
                                if request.is_symlink() or not re.fullmatch(r"req-[0-9a-f]{32}\.json", request.name): raise ValueError("invalid request path")
                                obj = read(request)
                                if not isinstance(obj, dict) or set(obj) != {"id", "hash", "command", "not_after"} or request.name != "req-" + obj.get("id", "") + ".json": raise ValueError("invalid request")
                                payload = validate(obj["command"])
                                if hashlib.sha256(payload).hexdigest() != obj["hash"]: raise ValueError("request hash mismatch")
                                if type(obj["not_after"]) not in (int, float) or not math.isfinite(obj["not_after"]) or clock() >= min(obj["not_after"], session.local_deadline - 75) or (directory / "stop").exists():
                                    atomic(directory / ("result-" + obj["id"]), {"status":"expired"})
                                    request.unlink()
                                    request = None
                                else:
                                    claim = directory / ("claim-" + obj["id"])
                                    fd = os.open(claim, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
                                    with os.fdopen(fd, "w") as f: f.write(obj["hash"]); f.flush(); os.fsync(f.fileno())
                                    sync_dir(directory)
                                    request.unlink()
                        if request is None:
                            sleep(.1); continue
                        try:
                            phase["not_after"] = obj["not_after"]
                            response = session.call(obj["command"]["method"], obj["command"]["params"])
                            atomic(directory / ("result-" + obj["id"]), {"status":"complete", "response":response})
                        except BaseException:
                            body_failed = True
                            atomic(directory / ("result-" + obj["id"]), {"status":"unknown"})
                            raise
                        finally:
                            phase["not_after"] = None
                except BaseException:
                    body_failed = True
                    raise
                finally:
                    with locked(base):
                        phase["body"] = False
                        atomic(directory / "state", {"phase":"stopping", "pid":os.getpid(), "store_key":store_key, "client_path":client_path, "ttl_seconds":ttl_seconds, "start_hash":request_hash, "remaining_body_seconds":max(0, int(session.local_deadline - 75 - clock()))})
                    if finish_transport is not None and body_failed:
                        finish_transport.suppress_return = True

        restore = task_state.restore_status
        result = "complete"
    except StartCancelled as error:
        if getattr(error, "automation_cleanup_error", None) is not None or (session is not None and getattr(session, "cleanup_error", None) is not None):
            from automation_session import quiet_failure_diagnostics
            diagnostics = quiet_failure_diagnostics(error)
            result = "unknown"; restore = "pending"
        else:
            result = "complete"; restore = "not_required"
    except BaseException as error:
        phase["body"] = False
        from automation_session import quiet_failure_diagnostics
        diagnostics = quiet_failure_diagnostics(error)
    finally:
        if finish_transport is not None:
            return_result = finish_transport.receipt or {"service_finish":"unconfirmed", "return_route":"unavailable", "chat_verified":False}
        atomic(directory / "state", {"phase":result, "pid":os.getpid(), "restore":restore, "store_key":store_key, "client_path":client_path, "ttl_seconds":ttl_seconds, "start_hash":request_hash, "completion":completion, "return_to_chat":return_result, **diagnostics})
        fcntl.flock(lockfd, fcntl.LOCK_UN)
        os.close(lockfd)


def require_task(base, task_id):
    if not ID.fullmatch(task_id): raise ValueError("invalid task id")
    task, directory = current(base)
    if task != task_id: raise ValueError("task mismatch")
    return directory


def request_call(base, task_id, request_id, command, result_path, wait=90):
    if not ID.fullmatch(request_id): raise ValueError("invalid request id")
    encoded = validate(command)
    if not isinstance(wait, (int, float)) or not 0 < wait <= 300: raise ValueError("invalid wait")
    digest = hashlib.sha256(encoded).hexdigest()
    fd = os.open(result_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as sink:
        with locked(base):
            directory = require_task(base, task_id)
            record = directory / ("record-" + request_id)
            request = directory / ("req-" + request_id + ".json")
            try:
                old = read(record)
                if old.get("hash") != digest: raise ValueError("request id already used")
            except FileNotFoundError:
                if public_status(directory)["status"] != "running" or (directory / "stop").exists(): raise RuntimeError("task not running")
                for pending in directory.glob("record-*"):
                    other = pending.name[7:]
                    if ID.fullmatch(other) and not (directory / ("result-" + other)).exists():
                        raise RuntimeError("another request is unfinished")
                deadline = time.monotonic() + wait
                atomic(record, {"hash":digest, "not_after":deadline})
                atomic(request, {"id":request_id, "hash":digest, "command":command, "not_after":deadline})
        deadline = time.monotonic() + wait
        result = {"status":"unknown"}
        while time.monotonic() < deadline:
            try:
                result = read(directory / ("result-" + request_id)); break
            except FileNotFoundError:
                if public_status(directory)["status"] != "running": break
                time.sleep(.1)
        if result["status"] == "unknown":
            with locked(base):
                try:
                    result = read(directory / ("result-" + request_id))
                except FileNotFoundError:
                    if request.exists() and not (directory / ("claim-" + request_id)).exists():
                        request.unlink()
                        result = {"status":"expired"}
                        atomic(directory / ("result-" + request_id), result)
        json.dump(result, sink, ensure_ascii=False, allow_nan=False); sink.flush(); os.fsync(sink.fileno())
    return {"task_id":task_id, "request_id":request_id, "status":result.get("status", "unknown"), "results_file":str(result_path)}



def wait_ready(base, task_id, wait=20, *, clock=time.monotonic, sleep=time.sleep):
    """Local-only bounded startup observation; never repeats Begin or holds the lock while waiting."""
    if type(wait) not in (int, float) or not math.isfinite(wait) or not 0 <= wait <= 90:
        raise ValueError("invalid ready wait")
    deadline = clock() + wait
    while True:
        with locked(base):
            state = public_status(require_task(base, task_id))
        if state["status"] != "starting" or clock() >= deadline:
            return {"task_id": task_id, **state}
        sleep(min(.1, max(0, deadline - clock())))


def finish(base, task_id, wait=30, *, clock=time.monotonic, sleep=time.sleep):
    """Request task cleanup once and observe it; only the captured Minis lease may close its service."""
    if type(wait) not in (int, float) or not math.isfinite(wait) or not 0 <= wait <= 90:
        raise ValueError("invalid finish wait")
    with locked(base):
        directory = require_task(base, task_id)
        state = public_status(directory)
        if state["status"] not in {"complete", "unknown"}:
            if not (directory / "stop").exists():
                atomic(directory / "stop", {"stop_requested": True})
    deadline = clock() + wait
    while state["status"] not in {"complete", "unknown"} and clock() < deadline:
        sleep(min(.1, max(0, deadline - clock())))
        with locked(base):
            state = public_status(directory)
    return {"task_id": task_id, **state,
            "control_end_confirmed": state["status"] == "complete" and state.get("restore") in
                {"restored", "already_never", "user_value_preserved", "no_record", "not_required"}}


def main(argv=None):
    parser = argparse.ArgumentParser(description="Bounded existing-pairing task session")
    sub = parser.add_subparsers(dest="action", required=True)
    o = sub.add_parser("prepare"); o.add_argument("--task-id"); o.add_argument("--origin-nonce")
    s = sub.add_parser("start"); s.add_argument("--task-id", required=True); s.add_argument("--store-key", required=True); s.add_argument("--client-path"); s.add_argument("--ttl-seconds", type=int, default=240); s.add_argument("--completion", choices=("return_chat","stay"), default="return_chat"); s.add_argument("--origin-session-id"); s.add_argument("--origin-title"); s.add_argument("--wait-ready", type=float, default=20)
    for name in ("status", "finish"):
        item = sub.add_parser(name); item.add_argument("--task-id", required=True)
        if name == "finish": item.add_argument("--wait", type=float, default=30)
    c = sub.add_parser("call"); c.add_argument("--task-id", required=True); c.add_argument("--request-id", required=True); c.add_argument("--method", required=True); c.add_argument("--params", default="{}"); c.add_argument("--results-file", required=True); c.add_argument("--wait", type=float, default=90)
    w = sub.add_parser("_worker"); w.add_argument("task"); w.add_argument("store_key"); w.add_argument("--client-path"); w.add_argument("--ttl-seconds", type=int, default=300)
    args = parser.parse_args(argv); base = root()
    try:
        if args.action == "_worker":
            if not ID.fullmatch(args.task): raise ValueError("invalid task")
            worker(base, args.task, args.store_key, args.client_path, ttl_seconds=args.ttl_seconds); return 0
        if args.action == "prepare": out = prepare_origin(base, args.task_id, args.origin_nonce)
        elif args.action == "start":
            if not math.isfinite(args.wait_ready) or not 0 <= args.wait_ready <= 90: raise ValueError("invalid ready wait")
            origin = args.origin_session_id
            if args.completion == "return_chat" and origin is None: origin = automatic_origin(base, args.task_id)
            out = start(base, args.task_id, args.store_key, args.client_path, args.ttl_seconds, completion_policy=args.completion, origin_session_id=origin, origin_title=args.origin_title)
        elif args.action == "call": out = request_call(base, args.task_id, args.request_id, {"method":args.method, "params":json.loads(args.params)}, args.results_file, args.wait)
        elif args.action == "finish": out = finish(base, args.task_id, args.wait)
        else:
            with locked(base):
                directory = require_task(base, args.task_id)
                task = args.task_id
                out = {"task_id":task, **public_status(directory)}
        if args.action == "start": out = wait_ready(base, args.task_id, args.wait_ready)
        print(json.dumps(out, ensure_ascii=False))
        if args.action == "finish" and not out["control_end_confirmed"]: return 2
        if args.action == "start" and out["status"] not in {"running", "complete"}: return 2
        return 0
    except Exception as error:
        codes = {"trusted originating Minis session ID required":"origin_context_required", "invalid completion policy":"invalid_completion_policy", "task start mismatch":"task_start_mismatch"}
        print(json.dumps({"status":"error", "error_code":codes.get(str(error), "task_operation_failed"), "error_type":type(error).__name__})); return 1


if __name__ == "__main__": raise SystemExit(main())
