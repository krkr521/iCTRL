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
    out = {"status": phase, "restore": state.get("restore", "pending") if phase == "complete" else "pending"}
    if phase == "running" and type(state.get("body_deadline")) in (int, float) and math.isfinite(state["body_deadline"]):
        out["remaining_body_seconds"] = max(0, int(state["body_deadline"] - time.monotonic()))
    if phase == "stopping" and type(state.get("remaining_body_seconds")) is int:
        out["remaining_body_seconds"] = max(0, state["remaining_body_seconds"])
    for key in ("quiet_phase", "quiet_cleanup_phase"):
        if state.get(key) in _QUIET_PHASES: out[key] = state[key]
    return out


def start(base, task_id, store_key, client_path=None):
    if not ID.fullmatch(task_id): raise ValueError("invalid task id")
    if not re.fullmatch(r"device:[A-Za-z0-9_-]{1,128}", store_key): raise ValueError("device store key required")
    with locked(base):
        task, directory = current(base)
        if task:
            state = read(directory / "state")
            if state.get("store_key") != store_key or state.get("client_path") != client_path:
                raise ValueError("task ownership mismatch")
            status = public_status(directory)
            if task == task_id: return {"task_id": task, **status}
            if status["status"] != "complete": raise RuntimeError("previous task not confirmed complete")
        task = task_id; directory = base / task
        directory.mkdir(mode=0o700)
        atomic(directory / "state", {"phase": "starting", "pid": os.getpid(), "store_key":store_key, "client_path":client_path})
        atomic(base / "active", task)
        log_fd = os.open(directory / "worker.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            argv = [sys.executable, str(Path(__file__).resolve()), "_worker", task, store_key]
            if client_path: argv += ["--client-path", client_path]
            try:
                process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log_fd, stderr=log_fd, start_new_session=True, close_fds=True)
            except BaseException:
                atomic(directory / "state", {"phase": "unknown", "restore": "pending", "store_key":store_key, "client_path":client_path})
                raise
            atomic(directory / "state", {"phase": "starting", "pid": process.pid, "store_key":store_key, "client_path":client_path})
        finally: os.close(log_fd)
        return {"task_id": task, "status": "starting", "restore": "pending"}


def transport_budget(method, session, body, clock=time.monotonic, not_after=None):
    if method in {"automation_end", "automation_status", "automation_owner_status"} and not body: return 5.0
    if session is None or not session.local_deadline: return 5.0
    deadline = session.local_deadline - (75 if body else 0)
    if body and not_after is not None: deadline = min(deadline, not_after)
    left = deadline - clock()
    if left <= 0: raise TimeoutError("task deadline")
    return left


class StartCancelled(Exception):
    pass


def worker(base, task, store_key, client_path=None, *, session_cls=None, manager_cls=None, managed=None, loader=None, clock=time.monotonic, sleep=time.sleep):
    from automation_session import AutomationSession
    from managed_autolock import ManagedAutoLock
    from task_context import managed_task
    if loader is None:
        from minis_transport import load_transport
        loader = load_transport
    session_cls = session_cls or AutomationSession; manager_cls = manager_cls or ManagedAutoLock; managed = managed or managed_task
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
    if state.get("pid") != os.getpid() or state.get("phase") != "starting" or state.get("store_key") != store_key or state.get("client_path") != client_path:
        fcntl.flock(lockfd, fcntl.LOCK_UN); os.close(lockfd); return
    phase = {"body": False, "not_after": None}; session = None; result = "unknown"; restore = "pending"; diagnostics = {}
    def budget(method):
        return transport_budget(method, session, phase["body"], clock, phase["not_after"])
    try:
        with locked(base):
            if (directory / "stop").exists(): raise StartCancelled()
        raw, supported = loader(store_key, client_path=client_path, timeout_budget=budget)
        session = session_cls(raw, ttl_seconds=300, supports_quiet=supported)
        with contextlib.ExitStack() as stack:
            with locked(base):
                if (directory / "stop").exists(): raise StartCancelled()
                atomic(directory / "state", {"phase":"starting", "pid":os.getpid(), "store_key":store_key, "client_path":client_path, "stage_started":"begin"})
            stack.enter_context(session)
            with locked(base):
                if (directory / "stop").exists(): raise StartCancelled()
                atomic(directory / "state", {"phase":"starting", "pid":os.getpid(), "store_key":store_key, "client_path":client_path, "stage_started":"autolock"})
            manager = manager_cls(Path.home() / ".ictrl" / "autolock")
            task_state = stack.enter_context(managed(manager, store_key, "minis-agent", session))
            if True:
                phase["body"] = True
                try:
                    atomic(directory / "state", {"phase":"running", "pid":os.getpid(), "store_key":store_key, "client_path":client_path, "body_deadline":session.local_deadline - 75})
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
                            atomic(directory / ("result-" + obj["id"]), {"status":"unknown"})
                            raise
                        finally:
                            phase["not_after"] = None
                finally:
                    with locked(base):
                        phase["body"] = False
                        atomic(directory / "state", {"phase":"stopping", "pid":os.getpid(), "store_key":store_key, "client_path":client_path, "remaining_body_seconds":max(0, int(session.local_deadline - 75 - clock()))})
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
        atomic(directory / "state", {"phase":result, "pid":os.getpid(), "restore":restore, "store_key":store_key, "client_path":client_path, **diagnostics})
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


def main(argv=None):
    parser = argparse.ArgumentParser(description="Bounded existing-pairing task session")
    sub = parser.add_subparsers(dest="action", required=True)
    s = sub.add_parser("start"); s.add_argument("--task-id", required=True); s.add_argument("--store-key", required=True); s.add_argument("--client-path")
    for name in ("status", "finish"):
        item = sub.add_parser(name); item.add_argument("--task-id", required=True)
    c = sub.add_parser("call"); c.add_argument("--task-id", required=True); c.add_argument("--request-id", required=True); c.add_argument("--method", required=True); c.add_argument("--params", default="{}"); c.add_argument("--results-file", required=True); c.add_argument("--wait", type=float, default=90)
    w = sub.add_parser("_worker"); w.add_argument("task"); w.add_argument("store_key"); w.add_argument("--client-path")
    args = parser.parse_args(argv); base = root()
    try:
        if args.action == "_worker":
            if not ID.fullmatch(args.task): raise ValueError("invalid task")
            worker(base, args.task, args.store_key, args.client_path); return 0
        if args.action == "start": out = start(base, args.task_id, args.store_key, args.client_path)
        elif args.action == "call": out = request_call(base, args.task_id, args.request_id, {"method":args.method, "params":json.loads(args.params)}, args.results_file, args.wait)
        else:
            with locked(base):
                directory = require_task(base, args.task_id)
                task = args.task_id
                if args.action == "finish":
                    atomic(directory / "stop", {"stop_requested":True})
                    out = {"task_id":task, "status":"stop_requested", "restore":"pending"}
                else: out = {"task_id":task, **public_status(directory)}
        print(json.dumps(out, ensure_ascii=False)); return 0
    except Exception:
        print(json.dumps({"status":"error"})); return 1


if __name__ == "__main__": raise SystemExit(main())
