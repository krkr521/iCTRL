"""No-network regressions for the user's real seven-batch pattern."""
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "ictrl-ready/scripts"
sys.path.insert(0, str(SCRIPTS))
import quiet_batch as batch
import minis_transport as transport


class ReadOnlyTests(unittest.TestCase):
    def test_four_observed_read_only_batches_never_begin_or_end(self):
        observed = [["device_info", "resolve_app"], ["find_element"],
                    ["find_element"], ["find_element"]]
        sent = []
        with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as sink:
            for methods in observed:
                batch.run_read_only([{"method": m, "params": {}} for m in methods],
                                    lambda m, p: sent.append(m) or {"ok": True}, sink)
            sink.seek(0)
            self.assertEqual(len(sink.read().splitlines()), 5)
        self.assertEqual(sent, [m for methods in observed for m in methods])
        self.assertFalse(any(m.startswith("automation_") for m in sent))

    def test_late_ui_or_write_rejects_entire_set_before_first_read(self):
        for command in [{"method": "tap", "params": {}},
                        {"method": "config", "params": {"allow_remote_access": True}},
                        {"method": "file_delete", "params": {}},
                        {"method": "unknown_future_method", "params": {}}]:
            with self.subTest(command=command), patch.object(batch, "load_transport") as load:
                sent = []
                with self.assertRaises(batch.TaskSessionRequired):
                    batch.run_read_only([{"method": "device_info", "params": {}}, command],
                                        lambda m, p: sent.append(m))
                self.assertEqual(sent, [])
                load.assert_not_called()

    def test_read_config_and_file_read_are_allowed_but_management_is_not(self):
        self.assertTrue(transport.is_read_only({"method": "config", "params": {}}))
        self.assertTrue(transport.is_read_only({"method": "file_read", "params": {"offset": 0}}))
        for command in [{"method": "automation_begin", "params": {}},
                        {"method": "page_source", "params": {"automation_session": "invented"}}]:
            with self.assertRaises(ValueError):
                batch.validate_commands([command])

    def test_read_timeout_is_not_replayed(self):
        calls = []
        def raw(method, params):
            calls.append(method)
            raise TimeoutError("synthetic")
        with self.assertRaises(TimeoutError):
            batch.run_read_only([{"method": "page_source", "params": {}}], raw)
        self.assertEqual(calls, ["page_source"])

    def test_ui_cli_rejects_before_pairing_read(self):
        args = ["quiet_batch.py", "synthetic.json", "--store-key", "device:synthetic"]
        with patch.object(sys, "argv", args), patch.object(Path, "read_text", return_value='[{"method":"tap"}]'), \
                patch.object(batch, "load_transport") as load:
            with self.assertRaises(batch.TaskSessionRequired):
                batch.main()
            load.assert_not_called()


class TransportTests(unittest.TestCase):
    def make_transport(self, calls, budget=None, exit_on=None):
        def call(host, record, method, params, timeout, request_id):
            calls.append((method, timeout))
            if method == exit_on:
                raise SystemExit("synthetic verification rejection")
            return 200, {"jsonrpc": "2.0", "id": request_id,
                         "result": {"device_id": "synthetic"} if method == "device_info" else {}}
        client = SimpleNamespace(_call_with=call, device_store_key=lambda d: "device:" + d)
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self): return b'{"methods":[{"name":"automation_begin"}]}'
        with patch.object(transport, "load_reference_client", return_value=client), \
                patch.object(transport, "load_existing_record", return_value={"synthetic": True}), \
                patch.object(transport.urllib.request, "build_opener", return_value=SimpleNamespace(open=lambda *a, **k: Response())):
            return transport.load_transport("device:synthetic", timeout_budget=budget)

    def test_ui_timeout_is_separate_from_status_timeout(self):
        calls = []
        raw, supported = self.make_transport(calls)
        self.assertTrue(supported)
        raw("page_source", {})
        raw("tap", {})
        raw("automation_status", {})
        self.assertEqual(calls, [("device_info", 5), ("page_source", 60), ("tap", 60), ("automation_status", 5)])

    def test_remaining_budget_caps_wait_without_replay(self):
        calls = []
        raw, _ = self.make_transport(calls, budget=lambda method: 2)
        raw("tap", {})
        self.assertEqual(calls, [("device_info", 2), ("tap", 2)])

    def test_exhausted_budget_sends_nothing(self):
        for value in [0, -1, float("nan"), float("inf"), True]:
            calls = []
            with self.subTest(value=value), self.assertRaises(TimeoutError):
                self.make_transport(calls, budget=lambda method: value)
            self.assertEqual(calls, [])

    def test_response_auth_failure_keeps_systemexit_cause_and_never_replays(self):
        calls = []
        raw, _ = self.make_transport(calls, exit_on="tap")
        with self.assertRaises(OSError) as caught:
            raw("tap", {})
        self.assertIsInstance(caught.exception.__cause__, SystemExit)
        self.assertEqual([m for m, _ in calls], ["device_info", "tap"])


if __name__ == "__main__":
    unittest.main()
