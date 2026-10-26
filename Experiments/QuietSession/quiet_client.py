"""Prototype only. Explicit automation lease wrapper for existing authenticated RPC callable."""
from __future__ import annotations

import contextlib
import math
import sys
import time
from collections.abc import Callable, Iterator
from typing import Any


class QuietUnavailable(RuntimeError):
    pass


class QuietClient:
    def __init__(self, rpc: Callable[[str, dict[str, Any]], dict[str, Any]], *, clock=time.monotonic):
        self.rpc = rpc
        self.clock = clock
        self.lease_id: str | None = None
        self.local_deadline: float = 0
        self.cleanup_error: Exception | None = None
        self.unknown_begin_status: dict[str, Any] | None = None

    @contextlib.contextmanager
    def session(self, ttl_seconds: int = 120, wait_seconds: float = 30) -> Iterator["QuietClient"]:
        if (self.lease_id is not None or type(ttl_seconds) is not int or
                type(wait_seconds) not in (float, int) or not math.isfinite(wait_seconds) or
                not 1 <= ttl_seconds <= 300 or not 0 < wait_seconds <= 30):
            raise ValueError("invalid or nested quiet session")
        started = self.clock()
        if not isinstance(started, (float, int)) or not math.isfinite(started):
            raise ValueError("invalid clock")
        self.cleanup_error = None
        self.unknown_begin_status = None
        try:
            reply = self.rpc("automation_begin", {"ttl_seconds": ttl_seconds})
        except Exception as begin_error:
            # Lost response may mean Begin ran. Never retry Begin or pretend safe cleanup.
            try:
                self.unknown_begin_status = self.rpc("automation_owner_status", {})
            except Exception as status_error:
                if hasattr(begin_error, "add_note"):
                    begin_error.add_note(f"owner status unavailable: {status_error!r}")
            raise QuietUnavailable("Begin outcome unknown; no retry or UI permitted") from begin_error
        lease = reply.get("lease_id")
        if not isinstance(lease, str) or not lease:
            try:
                self.unknown_begin_status = self.rpc("automation_owner_status", {})
            except Exception:
                pass
            raise QuietUnavailable("Begin response lacks lease id; outcome unknown; no retry or UI")
        self.lease_id = lease
        self.local_deadline = started + ttl_seconds
        try:
            verify_by = min(self.local_deadline, started + wait_seconds)
            while self.clock() < verify_by:
                status = self.rpc("automation_status", {"lease_id": lease})
                state = status.get("state")
                if state == "quiet_verified":
                    yield self
                    return
                if state not in ("preparing",):
                    raise QuietUnavailable(f"quiet unavailable: {state or 'unknown'}")
                time.sleep(min(0.2, max(0, verify_by - self.clock())))
            raise QuietUnavailable("quiet verification timed out")
        finally:
            body_error = sys.exc_info()[1]
            try:
                self.rpc("automation_end", {"lease_id": lease})
            except Exception as cleanup_error:
                self.cleanup_error = cleanup_error
                if body_error is not None:
                    if hasattr(body_error, "add_note"):
                        body_error.add_note(f"quiet cleanup failed: {cleanup_error!r}")
                else:
                    raise QuietUnavailable("quiet cleanup failed; inspect server owner status") from cleanup_error
            finally:
                self.lease_id = None
                self.local_deadline = 0

    def ui(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        if self.lease_id is None or self.clock() >= self.local_deadline:
            raise QuietUnavailable("no live quiet session")
        status = self.rpc("automation_status", {"lease_id": self.lease_id})
        if status.get("state") != "quiet_verified":
            raise QuietUnavailable(f"quiet unavailable: {status.get('state', 'unknown')}")
        if self.clock() >= self.local_deadline:
            raise QuietUnavailable("local quiet deadline reached")
        # Server still checks transport tokId, random lease id and verified state.
        if "automation_session" in params:
            raise ValueError("automation_session is owned by QuietClient")
        return self.rpc(method, {**params, "automation_session": self.lease_id})
