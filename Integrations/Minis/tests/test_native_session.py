"""Offline protocol/safety tests; no claim of device keep-awake acceptance."""
import sys
import ast
import hashlib
import json
import zipfile
import contextlib
import contextvars
from unittest import mock
import tempfile
import threading
import unittest
from datetime import datetime, timezone
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "ictrl-ready/scripts"
sys.path.insert(0, str(SCRIPTS))
from native_session import NativeSession
from automation_session import AutomationUnavailable, RestorationUncertain
from task_context import managed_task, AutoLockNotReady, begin


class Phone:
    def __init__(self):
        self.calls = []
        self.state = "active"
        self.available = True
        self.fail_end = False
    def __call__(self, method, params):
        self.calls.append((method, params))
        if method == "automation_native_capabilities":
            return dict(available=self.available, native_automation_session=1,
                        keep_awake="f13_lease", interruption_policy="explicit_alerts_only",
                        notification_suppression=False)
        if method in {"automation_register", "automation_owner_status"}: return {"mode": "automation"}
        if method == "automation_native_end" and self.fail_end: raise TimeoutError()
        if method.startswith("automation_native_"):
            return dict(mode="automation", backend="native", lease_id="a" * 32,
                        state="ended" if method.endswith("_end") else self.state,
                        deadline=datetime.fromtimestamp(1120, timezone.utc).isoformat().replace("+00:00", "Z"))
        return {"ok": True}


class NativeSessionTests(unittest.TestCase):
    def session(self, phone):
        return NativeSession(phone, clock=lambda: 1, wall_clock=lambda: 1000)

    def test_capability_failure_never_registers_or_begins(self):
        phone = Phone(); phone.available = False
        with self.assertRaises(AutomationUnavailable):
            with self.session(phone): self.fail("body")
        self.assertEqual([m for m, p in phone.calls], ["automation_native_capabilities"])

    def test_native_does_not_call_legacy_or_settings(self):
        phone = Phone()
        with self.session(phone) as session:
            session.call("tap", {"x": 10, "y": 10})
        methods = [m for m, p in phone.calls]
        self.assertEqual(methods, ["automation_native_capabilities", "automation_register",
                                  "automation_owner_status", "automation_native_begin", "automation_native_status", "tap",
                                  "automation_native_end"])
        self.assertEqual(phone.calls[-2][1]["automation_session"], "a" * 32)

    def test_nonactive_state_blocks_input_but_ends(self):
        phone = Phone()
        with self.assertRaises(AutomationUnavailable):
            with self.session(phone) as session:
                phone.state = "interruption_blocked"
                session.call("tap", {})
        self.assertNotIn("tap", [m for m, p in phone.calls])
        self.assertEqual(phone.calls[-1][0], "automation_native_end")

    def test_end_timeout_is_not_replayed_and_preserves_body_error(self):
        phone = Phone(); phone.fail_end = True
        with self.assertRaises(ValueError) as caught:
            with self.session(phone): raise ValueError("body")
        self.assertIsInstance(caught.exception.automation_cleanup_error, RestorationUncertain)
        self.assertEqual([m for m, p in phone.calls].count("automation_native_end"), 1)

    def test_lost_input_response_is_never_replayed(self):
        phone = Phone()
        with self.assertRaises(TimeoutError):
            with self.session(phone) as session:
                def lost(m, p): phone.calls.append((m, p)); raise TimeoutError()
                session.call("tap", {}, raw=lost)
        self.assertEqual([m for m, p in phone.calls].count("tap"), 1)

    def test_lost_begin_never_adopts_unproven_owner_lease(self):
        phone = Phone()
        def raw(method, params):
            if method == "automation_native_begin":
                phone.calls.append((method, params)); raise TimeoutError()
            if method == "automation_owner_status":
                phone.calls.append((method, params))
                if sum(m == "automation_owner_status" for m, p in phone.calls) == 1:
                    return {"mode": "automation"}
                return dict(mode="automation", backend="native", state="active", lease_id="a" * 32,
                            deadline="1970-01-01T00:18:40Z")
            return phone(method, params)
        with self.assertRaises(RestorationUncertain):
            with NativeSession(raw, clock=lambda: 1, wall_clock=lambda: 1000): self.fail("body")
        methods = [m for m, p in phone.calls]
        self.assertEqual(methods.count("automation_native_begin"), 1)
        self.assertEqual(methods.count("automation_owner_status"), 2)
        self.assertNotIn("tap", methods)
        self.assertNotIn("automation_native_end", methods)

    def test_existing_owner_lease_is_not_adopted(self):
        phone = Phone()
        def raw(method, params):
            if method == "automation_owner_status":
                phone.calls.append((method, params))
                return dict(mode="automation", backend="native", state="active", lease_id="old")
            return phone(method, params)
        with self.assertRaises(AutomationUnavailable):
            with NativeSession(raw): self.fail("body")
        self.assertNotIn("automation_native_begin", [m for m, p in phone.calls])

    def test_legacy_pending_stays_untouched(self):
        class Manager:
            def status(self, *args): return {"status": "restore_pending"}
        phone = Phone()
        with self.assertRaises(AutoLockNotReady):
            with self.session(phone) as session:
                with managed_task(Manager(), "device:test", "owner", session): self.fail("body")
        self.assertNotIn("tap", [m for m, p in phone.calls])

    def test_standalone_native_begin_never_opens_settings(self):
        with self.assertRaises(AutoLockNotReady):
            begin(None, "device:test", "owner", type("Native", (), {"native": True})())

    def test_windows_all_native_entries_refuse_pending_before_begin(self):
        source = Path(__file__).resolve().parents[2] / "Windows-Client/control.py"
        tree = ast.parse(source.read_text(encoding="utf-8"))
        fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "automation_session")
        namespace = dict(contextlib=contextlib, _AUTOMATION_CONTEXT=contextvars.ContextVar("test", default=None),
                         identity=lambda: "device:test")
        exec(compile(ast.Module(body=[fn], type_ignores=[]), str(source), "exec"), namespace)
        with mock.patch("managed_autolock.ManagedAutoLock.status", return_value={"status": "restore_pending"}):
            namespace["STATE"] = Path("synthetic")
            with self.assertRaisesRegex(RuntimeError, "LegacyAutoLockRecoveryRequired"):
                with namespace["automation_session"](): self.fail("body")

    def test_minis_shipped_zip_matches_reviewed_source(self):
        base = Path(__file__).resolve().parents[1]
        manifest = json.loads((base / "manifest.json").read_text(encoding="utf-8"))
        archive = base / manifest["archive"]
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), manifest["sha256"])
        with zipfile.ZipFile(archive) as zipped:
            self.assertEqual(set(zipped.namelist()), set(manifest["files"]))
            for name, entry in manifest["files"].items():
                data = (base / name).read_bytes()
                self.assertEqual(zipped.read(name), data)
                self.assertEqual(hashlib.sha256(data).hexdigest(), entry["sha256"])

    def test_windows_native_client_stays_in_sync(self):
        windows = Path(__file__).resolve().parents[2] / "Windows-Client/native_session.py"
        self.assertEqual(windows.read_bytes(), (SCRIPTS / "native_session.py").read_bytes())

    def test_native_context_has_no_autolock_ui(self):
        class Manager:
            def status(self, *args): return {"status": "no_record"}
        with managed_task(Manager(), "device:test", "owner", type("Native", (), {"native": True})()) as state:
            self.assertEqual(state.restore_status, "not_required")


if __name__ == "__main__": unittest.main()
