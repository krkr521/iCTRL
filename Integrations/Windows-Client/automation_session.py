"""Authenticated, fail-closed quiet lease. raw must never call this wrapper recursively."""
from __future__ import annotations
import math
import http.client
import re
import sys
import time
from datetime import datetime, timezone

READ_ONLY = frozenset("runtime_status device_info is_locked logs recent_logs config screenshot page_source view_tree ui_tree find_element find_elements resolve_app search_app search_apps list_apps installed_apps snapshot_api stream_ticket file_list file_read file_status".split())
def requires_ui(method):
    return method not in READ_ONLY and not method.startswith(("automation_", "file_"))

class AutomationUnavailable(RuntimeError): pass
class RestorationUncertain(AutomationUnavailable): pass

_STATUS_READ_ATTEMPTS = 3
_QUIET_PHASES = frozenset(("begin_config", "begin_register", "begin_prior_owner",
    "begin_send", "begin_owner_recovery", "begin_verify_status", "task_status",
    "task_send", "end_send", "end_restore_status"))

def quiet_failure_diagnostics(error):
    """Only fixed phase names may reach the task's public error summary."""
    result = {}
    for attribute, field in (("automation_phase", "quiet_phase"),
                             ("automation_cleanup_phase", "quiet_cleanup_phase")):
        phase = getattr(error, attribute, None)
        if isinstance(phase, str) and phase in _QUIET_PHASES:
            result[field] = phase
    return result

def _verification_failure(error):
    # Both existing adapters wrap response-authentication SystemExit in OSError.
    # Such an error must never be treated as a transient network read failure.
    seen = set()
    while error is not None and id(error) not in seen:
        if isinstance(error, SystemExit): return True
        seen.add(id(error))
        error = error.__cause__ or error.__context__
    return False

class AutomationSession:
    def __init__(self, raw, *, ttl_seconds=120, wait_seconds=30, cleanup_seconds=8,
                 legacy_setup=False, supports_quiet=True, clock=time.monotonic,
                 wall_clock=time.time, sleep=time.sleep):
        if type(ttl_seconds) is not int or not 1 <= ttl_seconds <= 300:
            raise ValueError("ttl_seconds must be 1..300")
        for n in (wait_seconds, cleanup_seconds):
            if type(n) not in (int,float) or not math.isfinite(n) or not 0 < n <= 30:
                raise ValueError("wait bounds must be finite and <=30 seconds")
        self.raw=raw; self.ttl=ttl_seconds; self.wait=wait_seconds; self.cleanup_wait=cleanup_seconds
        self.legacy_setup=legacy_setup; self.supported=supports_quiet
        self.clock=clock; self.wall=wall_clock; self.sleep=sleep
        self.lease_id=None; self.deadline=None; self.local_deadline=0
        self.verified=False; self.legacy=False; self.entered=False; self.cleanup_error=None
        self._phase="begin_config"

    def _raw_once(self, phase, method, params, *, transport=None):
        self._phase=phase
        try:
            return (transport or self.raw)(method,params)
        except BaseException as error:
            error.automation_phase=phase
            raise

    def _read_status(self, lease, until, phase):
        """Retry only this read, within one fixed window and at most 3 attempts.

        An already-started raw call cannot be cancelled. Check the clock again
        when it returns so an over-budget reply cannot release task UI.
        """
        self._phase=phase
        for attempt in range(_STATUS_READ_ATTEMPTS):
            if self.clock()>=until:
                raise AutomationUnavailable("status observation deadline passed")
            try:
                value=self._raw_once(phase,"automation_status",{"lease_id":lease})
            except (OSError,http.client.HTTPException) as error:
                if (_verification_failure(error) or attempt+1>=_STATUS_READ_ATTEMPTS
                        or self.clock()>=until):
                    raise
                self.sleep(min(.2,max(0,until-self.clock())))
                continue
            if self.clock()>=until:
                raise AutomationUnavailable("status response arrived after observation deadline")
            return value

    def _validate(self, value, *, expected=None, states=("preparing","restoring","quiet_verified"), require_live=True):
        if not isinstance(value,dict) or value.get("mode") != "automation":
            raise AutomationUnavailable("owner is not registered automation")
        lease=value.get("lease_id"); deadline=value.get("deadline")
        if not isinstance(lease,str) or re.fullmatch(r"[A-Za-z0-9_-]{16,128}",lease) is None:
            raise AutomationUnavailable("invalid lease identity")
        if expected is not None and lease != expected:
            raise AutomationUnavailable("lease response mismatch")
        try:
            if not isinstance(deadline,str) or not deadline.endswith("Z"): raise ValueError()
            stamp=datetime.fromisoformat(deadline.replace("Z","+00:00")).timestamp()
        except (ValueError,TypeError,OverflowError):
            raise AutomationUnavailable("invalid lease deadline") from None
        if self.deadline is not None and deadline != self.deadline:
            raise AutomationUnavailable("lease deadline changed")
        if value.get("state") not in states:
            raise AutomationUnavailable("lease not in required state")
        if (require_live and stamp <= self.wall()) or stamp > self.wall()+self.ttl+5:
            raise AutomationUnavailable("expired or out-of-bounds deadline")
        return lease,deadline,stamp

    def __enter__(self):
        if self.entered: raise AutomationUnavailable("nested/reused session refused")
        self.entered=True
        if not self.supported:
            if not self.legacy_setup: raise AutomationUnavailable("quiet unsupported; explicit legacy setup only")
            self.legacy=True;return self
        config=self._raw_once("begin_config","automation_config",{})
        if config.get("enabled") is not True:
            owner=self._raw_once("begin_prior_owner","automation_owner_status",{})
            if not self.legacy_setup or owner.get("mode") not in ("manual","manual_legacy"):
                raise AutomationUnavailable("quiet disabled; explicit unregistered legacy setup only")
            self.legacy=True;return self
        registered=self._raw_once("begin_register","automation_register",{"mode":"automation"})
        if registered.get("mode")!="automation" or registered.get("quiet_available") is not True:
            raise AutomationUnavailable("automation registration unavailable")
        prior=self._raw_once("begin_prior_owner","automation_owner_status",{})
        if prior.get("mode")!="automation" or prior.get("state") not in (None,"ended"):
            raise AutomationUnavailable("owner already has a lease; no new Begin")
        started=self.clock(); self.local_deadline=started+self.ttl
        try:
            try:
                reply=self._raw_once("begin_send","automation_begin",{"ttl_seconds":self.ttl})
                # Begin wire omits mode; mode was checked by authenticated register/owner reads.
                reply={"mode":"automation",**reply}
                lease,deadline,stamp=self._validate(reply,states=("preparing",))
            except (OSError, http.client.HTTPException, AutomationUnavailable, TypeError, ValueError) as begin_error:
                if _verification_failure(begin_error): raise
                # Exactly one owner-bound recovery read; never submit Begin again.
                try:
                    reply=self._raw_once("begin_owner_recovery","automation_owner_status",{})
                    lease,deadline,stamp=self._validate(reply,states=("preparing","restoring","quiet_verified","failed","expired","ending","restoration_pending"),require_live=False)
                    if lease==prior.get("lease_id"):raise AutomationUnavailable("recovered stale lease")
                except Exception:
                    raise RestorationUncertain("Begin outcome unknown; owner recovery unavailable; no UI permitted") from begin_error
            self.lease_id=lease;self.deadline=deadline
            self.local_deadline=min(self.local_deadline,self.clock()+stamp-self.wall())
            verify_by=min(self.local_deadline,started+self.wait)
            while self.clock()<verify_by:
                state=self._read_status(lease,verify_by,"begin_verify_status")
                self._validate(state,expected=lease)
                if state["state"]=="quiet_verified":self.verified=True;return self
                self.sleep(min(.2,max(0,verify_by-self.clock())))
            raise AutomationUnavailable("quiet verification timed out; no UI sent")
        except BaseException as error:
            if not hasattr(error,"automation_phase"): error.automation_phase=self._phase
            self._cleanup(error)
            raise

    def call(self, method, params=None, *, raw=None):
        if method.startswith("automation_"):
            raise ValueError("automation management RPCs belong to the session raw transport")
        params=dict(params or {})
        if "automation_session" in params:raise ValueError("session owns automation_session")
        transport=raw or self.raw
        if not requires_ui(method):return transport(method,params)
        if self.legacy:return transport(method,params)
        if not self.verified or self.lease_id is None or self.clock()>=self.local_deadline:
            raise AutomationUnavailable("no verified live quiet lease")
        try:
            status=self._raw_once("task_status","automation_status",{"lease_id":self.lease_id})
            self._validate(status,expected=self.lease_id,states=("quiet_verified",))
        except BaseException as error:
            error.automation_phase="task_status"
            raise
        if self.clock()>=self.local_deadline:raise AutomationUnavailable("lease expired before UI send")
        # One attempt only, including timeouts and lost responses.
        return self._raw_once("task_send",method,{**params,"automation_session":self.lease_id},transport=transport)

    def _cleanup(self, body_error=None):
        self.verified=False
        if self.lease_id is None:return
        lease=self.lease_id
        try:
            result=self._raw_once("end_send","automation_end",{"lease_id":lease})
            end_by=self.clock()+self.cleanup_wait
            while True:
                self._validate(result,expected=lease,states=("ending","restoring","ended","restoration_pending"),require_live=False)
                if result.get("state")=="ended":return
                if result.get("state") not in ("ending","restoring") or self.clock()>=end_by:
                    raise RestorationUncertain("quiet restoration not confirmed")
                self.sleep(min(.2,max(0,end_by-self.clock())))
                result=self._read_status(lease,end_by,"end_restore_status")
        except BaseException as error:
            self.cleanup_error=RestorationUncertain("End/restore outcome uncertain; do not retry UI or End")
            self.cleanup_error.automation_phase=self._phase
            if body_error is None:raise self.cleanup_error from error
            # Preserve the body exception, including on Python 3.10 (no add_note).
            body_error.automation_cleanup_error=self.cleanup_error
            body_error.automation_cleanup_phase=self._phase
            if hasattr(body_error,"add_note"):body_error.add_note(str(self.cleanup_error))
            print(str(self.cleanup_error),file=sys.stderr)
        finally:self.lease_id=None

    def __exit__(self, kind, error, traceback):
        self._cleanup(error)
        return False


def inspect_manual_recovery(raw, *, confirmed_waited=False, wait_seconds=30,
                            clock=time.monotonic, sleep=time.sleep):
    """Explicit human recovery only; never called by AutomationSession.
    Server enforces original deadline+300s; manual status does not disclose it.
    One inspection request, then bounded reads. Does not register/downgrade a token.
    """
    if confirmed_waited is not True:
        raise AutomationUnavailable("Explicit confirmation of deadline+300s wait required")
    if type(wait_seconds) not in (int,float) or not math.isfinite(wait_seconds) or not 0<wait_seconds<=30:
        raise ValueError("Invalid inspect wait")
    owner=raw("automation_owner_status",{})
    if owner.get("mode")!="manual" or owner.get("takeover_state")!="restoration_pending":
        raise AutomationUnavailable("Registered manual restoration_pending token required")
    try:
        raw("automation_inspect",{})
    except BaseException as error:
        raise RestorationUncertain("Inspection rejected or outcome unknown; no retry performed") from error
    until=clock()+wait_seconds
    while clock()<until:
        try:
            value=raw("automation_owner_status",{})
        except BaseException as error:
            raise RestorationUncertain("Inspection status unavailable; no retry performed") from error
        if value.get("mode")!="manual":raise RestorationUncertain("Manual recovery identity changed")
        if value.get("ui_blocked") is False and value.get("takeover_state")=="manual_ready":return value
        sleep(min(.2,max(0,until-clock())))
    raise RestorationUncertain("Fresh inspection did not confirm off/preserved Focus; UI remains blocked")
