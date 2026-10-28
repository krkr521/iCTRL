"""Auto-Lock lifecycle inside a caller-owned AutomationSession.

The caller must enter this context inside control.automation_session(); this
module never begins, pairs, or ends that quiet lease.
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass

from autolock_ui import AutoLockUI, run_managed
from managed_autolock import ManagedAutoLock


READY = frozenset({"active", "already_active", "already_never"})


class AutoLockNotReady(RuntimeError):
    pass


class RestorationUnconfirmed(RuntimeError):
    pass


@dataclass
class TaskState:
    start: dict | None = None
    end: dict | None = None
    restore_status: str = "not_attempted"


def begin(manager: ManagedAutoLock, device: str, owner: str, session) -> dict:
    return run_managed(manager, device, owner, AutoLockUI(session.call), ending=False)


def end(manager: ManagedAutoLock, device: str, owner: str, session) -> dict:
    current = manager.status(device, owner)
    if current["status"] in {"no_record", "other_owner_pending"}:
        return {**current, "returned_to_original_app": True}
    marker = manager.mark_restore_pending(device, owner)
    if marker["status"] in {"no_record", "already_never", "other_owner_pending"}:
        return {**marker, "returned_to_original_app": True}
    try:
        return run_managed(manager, device, owner, AutoLockUI(session.call), ending=True)
    except BaseException:
        try:
            manager.mark_restore_pending(device, owner)
        except Exception:
            pass
        raise


@contextmanager
def managed_task(manager: ManagedAutoLock, device: str, owner: str, session):
    if getattr(session, "native", False):
        previous = manager.status(device, owner)
        if previous.get("status") != "no_record":
            raise AutoLockNotReady("Legacy Auto-Lock record requires explicit recovery; unchanged")
        yield TaskState(start={"status": "native_ready", "pending": False},
                        end={"status": "not_required", "pending": False},
                        restore_status="not_required")
        return
    state = TaskState()
    task_error = None
    body_entered = False
    try:
        state.start = begin(manager, device, owner, session)
        if state.start.get("status") not in READY or state.start.get("pending") or not state.start.get("returned_to_original_app"):
            raise AutoLockNotReady("Auto-Lock start is not verified")
        body_entered = True
        yield state
    except BaseException as error:
        task_error = error
        raise
    finally:
        if not body_entered:
            # Start may have an in-flight, outcome-unknown setting tap or may
            # have lost foreground to the user. Never initiate a second UI
            # transaction here. A later explicit run first observes recovery.
            try:
                state.end = manager.mark_restore_pending(device, owner)
            except BaseException:
                pass
            state.restore_status = "unconfirmed"
        else:
            try:
                state.end = end(manager, device, owner, session)
                if state.end.get("pending") or not state.end.get("returned_to_original_app"):
                    state.restore_status = "unconfirmed"
                else:
                    state.restore_status = state.end.get("status", "unconfirmed")
            except BaseException:
                state.restore_status = "unconfirmed"
        if task_error is not None:
            task_error.autolock_restore_status = state.restore_status
        elif state.restore_status == "unconfirmed":
            raise RestorationUnconfirmed("Auto-Lock restoration unconfirmed")
