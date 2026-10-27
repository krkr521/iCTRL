"""Actual POSIX locks/files with fake phone operations: no network or credentials."""
import contextlib
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "ictrl-ready/scripts"
sys.path.insert(0, str(SCRIPTS))
import task_session as task


@unittest.skipIf(os.name == "nt", "POSIX process locks are exercised under Ubuntu")
class PosixTaskFlow(unittest.TestCase):
    def test_seven_interactive_calls_hold_one_context_and_duplicate_is_read_only(self):
        events = []
        class Session:
            cleanup_error = None
            def __init__(self, raw, **kwargs): self.local_deadline = time.monotonic() + 300
            def __enter__(self): events.append("begin"); return self
            def __exit__(self, *args): events.append("end")
            def call(self, method, params): events.append(method); return {"ok": True}
        @contextlib.contextmanager
        def managed(*args):
            events.append("autolock_start")
            class State: restore_status = "restored"
            try: yield State()
            finally: events.append("autolock_restore")
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp); task_id = "a" * 32
            directory = base / task_id; directory.mkdir(mode=0o700)
            task.atomic(base / "active", task_id)
            task.atomic(directory / "state", {"phase": "starting", "pid": os.getpid(),
                                               "store_key": "device:synthetic", "client_path": None})
            worker = threading.Thread(target=task.worker, args=(base, task_id, "device:synthetic"),
                                      kwargs={"loader": lambda *a, **k: (None, True),
                                              "session_cls": Session, "manager_cls": lambda *a: None,
                                              "managed": managed}, daemon=True)
            worker.start()
            limit = time.monotonic() + 5
            while task.public_status(directory)["status"] != "running" and time.monotonic() < limit:
                time.sleep(.01)
            self.assertEqual(task.public_status(directory)["status"], "running")
            methods = ["device_info", "launch_app", "find_element", "tap",
                       "find_element", "tap", "find_element"]
            try:
                for index, method in enumerate(methods):
                    request_id = f"{index:032x}"
                    command = {"method": method, "params": {}}
                    result = task.request_call(base, task_id, request_id, command,
                                               base / f"reply-{index}", wait=2)
                    self.assertEqual(result["status"], "complete")
                    again = task.request_call(base, task_id, request_id, command,
                                              base / f"again-{index}", wait=2)
                    self.assertEqual(again["status"], "complete")
                    self.assertEqual(events.count("begin"), 1)
                    self.assertNotIn("end", events)
            finally:
                with task.locked(base): task.atomic(directory / "stop", {"stop_requested": True})
                worker.join(timeout=5)
            self.assertFalse(worker.is_alive())
            self.assertEqual(events, ["begin", "autolock_start", *methods, "autolock_restore", "end"])
            self.assertEqual(task.public_status(directory)["status"], "complete")
            self.assertEqual((directory / "state").stat().st_mode & 0o777, 0o600)

    def test_waiting_timeout_removes_unclaimed_command(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp); task_id = "a" * 32; request_id = "b" * 32
            directory = base / task_id; directory.mkdir(mode=0o700)
            task.atomic(base / "active", task_id)
            task.atomic(directory / "state", {"phase": "running", "pid": os.getpid()})
            result = task.request_call(base, task_id, request_id, {"method": "tap", "params": {}},
                                       base / "reply", wait=.02)
            self.assertEqual(result["status"], "expired")
            self.assertFalse((directory / f"req-{request_id}.json").exists())
            self.assertFalse((directory / f"claim-{request_id}").exists())


if __name__ == "__main__": unittest.main()
