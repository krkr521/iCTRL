"""Read-only Minis batch. A complete UI task uses the task-scoped worker."""
import argparse
import json
import os
import sys
from pathlib import Path
from automation_session import AutomationSession, AutomationUnavailable, RestorationUncertain


def validate_commands(value):
    if not isinstance(value, list) or not 1 <= len(value) <= 100:
        raise ValueError("Batch must have 1..100 commands")
    normalized = []
    for command in value:
        if (not isinstance(command, dict) or set(command) - {"method", "params"} or
                not isinstance(command.get("method"), str) or not command["method"] or
                not isinstance(command.get("params", {}), dict) or
                command["method"].startswith("automation_") or
                "automation_session" in command.get("params", {})):
            raise ValueError("Invalid command; entire batch rejected before Begin")
        # Validate JSON serializability and reject non-finite numbers before any RPC.
        json.dumps(command, allow_nan=False)
        normalized.append({"method": command["method"], "params": dict(command.get("params", {}))})
    return normalized


from minis_transport import is_read_only, load_transport, load_reference_client, load_existing_record


class TaskSessionRequired(ValueError):
    pass


def public_error_type(error):
    if isinstance(error, TaskSessionRequired):
        return "ui_requires_task_session"
    if isinstance(error, RestorationUncertain) or getattr(error, "automation_cleanup_error", None) is not None:
        return "restoration_uncertain"
    if isinstance(error, AutomationUnavailable):
        return "automation_unavailable"
    if isinstance(error, (ValueError, TypeError)):
        return "invalid_input"
    if isinstance(error, (OSError, TimeoutError)):
        return "transport_error"
    return "operation_error"


def open_results(path):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return os.fdopen(os.open(path, flags, 0o600), "w", encoding="utf-8")


def write_result(sink, item):
    if sink is None:
        return
    sink.write(json.dumps(item, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n")
    sink.flush()
    os.fsync(sink.fileno())


def run_read_only(commands, raw, sink=None):
    commands = validate_commands(commands)
    if not all(is_read_only(command) for command in commands):
        raise TaskSessionRequired("Use task_session.py start/call/finish; no session started")
    completed = 0
    for index, command in enumerate(commands):
        value = raw(command["method"], command["params"])
        write_result(sink, {"kind": "result", "index": index,
                            "method": command["method"], "result": value})
        completed += 1
    return completed


def main():
    parser = argparse.ArgumentParser(description="Read-only batch; UI uses task_session.py")
    parser.add_argument("batch", type=Path)
    parser.add_argument("--store-key", required=True)
    parser.add_argument("--results-file", type=Path, help="Exclusive private JSONL output")
    parser.add_argument("--client", type=Path, default=Path.home() / ".ictrl/bin/ictrl_rpc.py")
    args = parser.parse_args()
    commands = validate_commands(json.loads(args.batch.read_text(encoding="utf-8")))
    if not all(is_read_only(command) for command in commands):
        raise TaskSessionRequired("Use task_session.py start/call/finish; no session started")
    sink = open_results(args.results_file) if args.results_file is not None else None
    try:
        raw, _ = load_transport(args.store_key, args.client)
        completed = run_read_only(commands, raw, sink)
        write_result(sink, {"kind": "terminal", "status": "ended", "session_started": False,
                            "autolock_restoration": "not_required", "quiet_restoration": "not_required",
                            "commands_completed": completed})
    except BaseException as error:
        write_result(sink, {"kind": "terminal", "status": "failed", "session_started": False,
                            "error_type": public_error_type(error)})
        raise
    finally:
        if sink is not None:
            sink.close()
    print("Read-only batch finished; no Quiet session started")


if __name__ == "__main__":
    try:
        main()
    except BaseException as error:
        if isinstance(error, SystemExit) and error.code == 0:
            raise
        print("Batch failed: " + public_error_type(error), file=sys.stderr)
        if isinstance(error, TaskSessionRequired):
            print("Use task_session.py start/call/finish; do not retry the old UI batch.", file=sys.stderr)
        raise SystemExit(1) from None
