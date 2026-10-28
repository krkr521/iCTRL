"""Windows entry for managed iPhone Auto-Lock tasks.

Deploy beside control.py. No pairing or configuration changes occur.
"""

from __future__ import annotations

import argparse
import json
import runpy
import sys
from pathlib import Path

from managed_autolock import ManagedAutoLock
from task_context import AutoLockNotReady, RestorationUnconfirmed, begin, end, managed_task
from automation_session import quiet_failure_diagnostics


HERE = Path(__file__).resolve().parent
CONTROL_DIR = HERE
OWNER = "codex-windows"
STATE_DIR = HERE / ".state" / "autolock"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Managed iPhone Auto-Lock task")
    parser.add_argument("command", choices=("begin", "end", "run"))
    parser.add_argument("--script", type=Path)
    parser.add_argument("--legacy-setup", action="store_true")
    parser.add_argument("--ttl-seconds", type=int, default=120)
    args = parser.parse_args(argv)
    if not 1 <= args.ttl_seconds <= 300:
        parser.error("--ttl-seconds must be an integer from 1 to 300")
    if args.command == "begin" and not args.legacy_setup:
        parser.error("begin is legacy setup only; normal native tasks require run")
    if args.command == "run" and (args.script is None or not args.script.is_file()):
        parser.error("run requires an existing --script PATH")
    if args.command != "run" and args.script is not None:
        parser.error("--script is only valid for run")

    sys.path.insert(0, str(CONTROL_DIR))
    if not (CONTROL_DIR / "control.py").is_file():
        print(json.dumps({"ok": False, "error_type": "ControlModuleMissing",
                          "restore_status": "unknown", "quiet_restore_status": "unknown"}))
        return 1
    import control  # noqa: E402; same module used by the user's script

    manager = ManagedAutoLock(STATE_DIR)
    session = None
    try:
        control.start_bridge()
        expected_device = None
        if args.command == "end":
            expected_device = control.identity()
            local = manager.status(expected_device, OWNER)
            if local["status"] == "no_record":
                print(json.dumps({"ok": True, "result": {**local, "returned_to_original_app": True},
                                  "quiet_restore_status": "not_started"}, ensure_ascii=False))
                return 0
            if local["status"] == "other_owner_pending":
                print(json.dumps({"ok": False, "result": local,
                                  "quiet_restore_status": "not_started"}, ensure_ascii=False))
                return 1
            if local["owned_change"] is False:
                cleared = manager.mark_restore_pending(expected_device, OWNER)
                print(json.dumps({"ok": True, "result": {**cleared, "returned_to_original_app": True},
                                  "quiet_restore_status": "not_started"}, ensure_ascii=False))
                return 0
        with control.automation_session(legacy_setup=args.legacy_setup,
                                        expected_device_key=expected_device,
                                        ttl_seconds=args.ttl_seconds,
                                        legacy_recovery=args.command == "end") as session:
            quiet_result = "not_required" if getattr(session, "native", False) else ("legacy_setup" if session.legacy else "confirmed")
            device = getattr(session, "bound_device_key", None)
            if not isinstance(device, str) or not device:
                raise RuntimeError("SessionDeviceBindingMissing")
            if expected_device is not None and device != expected_device:
                raise RuntimeError("SessionDeviceBindingMismatch")
            if args.command == "begin":
                result = begin(manager, device, OWNER, session)
                confirmed = (result.get("status") in {"active", "already_active", "already_never"}
                             and result.get("pending") is False
                             and result.get("returned_to_original_app") is True)
            elif args.command == "end":
                result = end(manager, device, OWNER, session)
                confirmed = (result.get("pending") is False
                             and result.get("returned_to_original_app") is True
                             and result.get("status") in {"restored", "already_never",
                                                          "user_value_preserved", "no_record"})
            else:
                with managed_task(manager, device, OWNER, session) as state:
                    prior_argv = sys.argv
                    sys.argv = [str(args.script.resolve())]
                    try:
                        runpy.run_path(sys.argv[0], run_name="__main__")
                    finally:
                        sys.argv = prior_argv
                result = {"start": state.start, "end": state.end,
                          "restore_status": state.restore_status}
                confirmed = True
        if not confirmed:
            print(json.dumps({"ok": False, "result": result,
                              "quiet_restore_status": quiet_result}, ensure_ascii=False))
            return 1
        print(json.dumps({"ok": True, "result": result,
                          "quiet_restore_status": quiet_result}, ensure_ascii=False))
        return 0
    except BaseException as error:
        # Never print exception text: RPC failures may contain UI text or URLs.
        status = "unconfirmed" if isinstance(error, RestorationUnconfirmed) else getattr(
            error, "autolock_restore_status", "unknown")
        quiet_status = "unconfirmed" if (type(error).__name__ == "RestorationUncertain"
                                         or getattr(error, "automation_cleanup_error", None)) else "unknown"
        if quiet_status == "unknown" and session is not None and getattr(session, "cleanup_error", None) is None:
            quiet_status = "legacy_setup" if session.legacy else "confirmed"
        print(json.dumps({"ok": False, "error_type": type(error).__name__,
                          "restore_status": status,
                          "quiet_restore_status": quiet_status,
                          **quiet_failure_diagnostics(error)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
