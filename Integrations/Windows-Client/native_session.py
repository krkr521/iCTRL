"""Native12 task lease: no Settings writes and no Focus/Shortcuts changes.

Legacy recovery remains in automation_session.py. Never fall back to it here.
"""
from __future__ import annotations

import re
import http.client
import threading
import time
from datetime import datetime

from automation_session import AutomationUnavailable, RestorationUncertain, requires_ui, _verification_failure


class NativeSession:
    native = True
    def __init__(self, raw, *, ttl_seconds=120, supports_quiet=True,
                 clock=time.monotonic, wall_clock=time.time, **unused):
        if type(ttl_seconds) is not int or not 1 <= ttl_seconds <= 300:
            raise ValueError("ttl_seconds must be 1..300")
        self.raw, self.ttl, self.clock, self.wall = raw, ttl_seconds, clock, wall_clock
        self.local_deadline = 0
        self.lease_id = self.deadline = None
        self.legacy = False
        self.cleanup_error = None
        self._entered = False
        self._stop = threading.Event()
        self._thread = None
        self._failure = None
        self._lock = threading.Lock()

    def _validate(self, value, states=("active",)):
        if not isinstance(value, dict) or value.get("backend") != "native" or value.get("mode") != "automation":
            raise AutomationUnavailable("native owner unavailable")
        lease, deadline = value.get("lease_id"), value.get("deadline")
        if not isinstance(lease, str) or re.fullmatch(r"[A-Za-z0-9_-]{16,128}", lease) is None:
            raise AutomationUnavailable("invalid native lease")
        if self.lease_id is not None and lease != self.lease_id:
            raise AutomationUnavailable("native lease mismatch")
        try:
            if not isinstance(deadline, str) or not deadline.endswith("Z"):
                raise ValueError()
            stamp = datetime.fromisoformat(deadline.replace("Z", "+00:00")).timestamp()
        except (ValueError, TypeError, OverflowError):
            raise AutomationUnavailable("invalid native deadline") from None
        if self.deadline is not None and deadline != self.deadline:
            raise AutomationUnavailable("native deadline changed")
        if value.get("state") not in states:
            raise AutomationUnavailable("native lease not ready")
        if states == ("active",) and (stamp <= self.wall() or stamp > self.wall() + self.ttl + 5):
            raise AutomationUnavailable("native lease expired")
        return lease, deadline, stamp

    def __enter__(self):
        if self._entered:
            raise AutomationUnavailable("nested/reused session refused")
        self._entered = True
        caps = self.raw("automation_native_capabilities", {})
        expected = {"available": True, "native_automation_session": 1,
                    "keep_awake": "f13_lease", "interruption_policy": "explicit_alerts_only",
                    "notification_suppression": False}
        if not isinstance(caps, dict) or any(caps.get(k) != v for k, v in expected.items()):
            raise AutomationUnavailable("native12 capabilities required; no legacy fallback")
        registered = self.raw("automation_register", {"mode": "automation"})
        if registered.get("mode") != "automation":
            raise AutomationUnavailable("automation registration unavailable")
        prior = self.raw("automation_owner_status", {})
        if not isinstance(prior, dict) or prior.get("mode") != "automation" or prior.get("state") not in (None, "ended", "expired"):
            raise AutomationUnavailable("owner already has a lease; no native Begin")
        started = self.clock()
        self.local_deadline = started + self.ttl
        try:
            try:
                value = self.raw("automation_native_begin", {"ttl_seconds": self.ttl})
            except (OSError, http.client.HTTPException) as error:
                if _verification_failure(error): raise
                # Owner identity cannot distinguish concurrent clients sharing a token.
                # Observe once, but never adopt or End an unproven lease.
                try:
                    self.raw("automation_owner_status", {})
                except BaseException:
                    pass
                raise RestorationUncertain("Begin outcome unknown; no UI or End; await heartbeat expiry") from error
            lease, deadline, stamp = self._validate(value)
            self.lease_id, self.deadline = lease, deadline
            self.local_deadline = min(self.local_deadline, self.clock() + stamp - self.wall())
            if self.clock() >= self.local_deadline:
                raise AutomationUnavailable("native Begin expired")
            self._thread = threading.Thread(target=self._heartbeat, name="ictrl-native-lease", daemon=True)
            self._thread.start()
            return self
        except BaseException:
            if self.lease_id is not None:
                self._cleanup()
            raise

    def _heartbeat(self):
        while not self._stop.wait(5):
            try:
                with self._lock:
                    if self._stop.is_set(): return
                    if self.clock() >= self.local_deadline:
                        raise AutomationUnavailable("native deadline passed")
                    self._validate(self.raw("automation_native_heartbeat", {"lease_id": self.lease_id}))
            except BaseException as error:
                self._failure = error
                self._stop.set()
                return

    def call(self, method, params=None, *, raw=None):
        if method.startswith("automation_"):
            raise ValueError("session management belongs to raw transport")
        params = dict(params or {})
        if "automation_session" in params:
            raise ValueError("session owns automation_session")
        transport = raw or self.raw
        if not requires_ui(method): return transport(method, params)
        with self._lock:
            if self._failure is not None or self._stop.is_set() or self.lease_id is None or self.clock() >= self.local_deadline:
                raise AutomationUnavailable("native lease unavailable")
            self._validate(self.raw("automation_native_status", {"lease_id": self.lease_id}))
            if self.clock() >= self.local_deadline:
                raise AutomationUnavailable("native lease expired before UI")
            # No input retries, including lost responses.
            lease = self.lease_id
        return transport(method, {**params, "automation_session": lease})

    def _cleanup(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=6)
            if self._thread.is_alive():
                raise RestorationUncertain("native heartbeat still in flight; lease expiry required")
        if self.lease_id is None: return
        try:
            with self._lock:
                value = self.raw("automation_native_end", {"lease_id": self.lease_id})
                self._validate(value, ("ended",))
        finally:
            self.lease_id = None

    def __exit__(self, kind, error, traceback):
        try:
            self._cleanup()
        except BaseException as cleanup:
            self.cleanup_error = RestorationUncertain("native End unconfirmed; do not replay")
            if error is None: raise self.cleanup_error from cleanup
            error.automation_cleanup_error = self.cleanup_error
        return False
