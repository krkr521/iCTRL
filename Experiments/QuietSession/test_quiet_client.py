import unittest
from unittest.mock import patch

from quiet_client import QuietClient, QuietUnavailable


class QuietClientTests(unittest.TestCase):
    def test_unknown_state_rejected_without_ui(self):
        calls = []
        def rpc(method, params):
            calls.append(method)
            if method == "automation_begin": return {"lease_id": "fresh"}
            if method == "automation_status": return {"state": "mystery"}
            return {}
        with self.assertRaises(QuietUnavailable):
            with QuietClient(rpc).session():
                self.fail("entered unverified session")
        self.assertEqual(calls, ["automation_begin", "automation_status", "automation_end"])

    def test_local_deadline_blocks_ui(self):
        now = [0.0]
        calls = []
        def rpc(method, params):
            calls.append((method, params))
            if method == "automation_begin": return {"lease_id": "fresh"}
            if method == "automation_status": return {"state": "quiet_verified"}
            return {}
        client = QuietClient(rpc, clock=lambda: now[0])
        with client.session(ttl_seconds=1):
            self.assertEqual(client.ui("tap", {"x": 1}) , {})
            now[0] = 1.0
            with self.assertRaises(QuietUnavailable): client.ui("tap", {"x": 2})
        self.assertEqual([x[0] for x in calls], ["automation_begin", "automation_status", "automation_status", "tap", "automation_end"])

    def test_unknown_begin_never_retries_or_ends(self):
        calls = []
        def rpc(method, params):
            calls.append(method)
            if method == "automation_begin": raise TimeoutError("lost reply")
            if method == "automation_owner_status": return {"state": "preparing"}
            self.fail("unexpected RPC")
        c = QuietClient(rpc)
        with self.assertRaises(QuietUnavailable):
            with c.session(): self.fail("entered")
        self.assertEqual(c.unknown_begin_status, {"state": "preparing"})
        self.assertEqual(calls, ["automation_begin", "automation_owner_status"])

    def test_end_error_does_not_replace_body_error(self):
        def rpc(method, params):
            if method == "automation_begin": return {"lease_id": "fresh"}
            if method == "automation_status": return {"state": "quiet_verified"}
            if method == "automation_end": raise OSError("cleanup")
            return {}
        c = QuietClient(rpc)
        with self.assertRaisesRegex(ValueError, "body"):
            with c.session(): raise ValueError("body")
        self.assertIsInstance(c.cleanup_error, OSError)

    def test_reject_bad_numeric_values(self):
        c = QuietClient(lambda *_: self.fail("RPC called"))
        for ttl, wait in [(True, 1), (120, float("nan")), (120, True), (301, 1)]:
            with self.assertRaises(ValueError):
                with c.session(ttl_seconds=ttl, wait_seconds=wait): pass


if __name__ == "__main__": unittest.main()
