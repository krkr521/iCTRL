"""Crash-recoverable Auto-Lock policy. UI interaction is supplied by the caller.

All times are canonical Settings labels. The caller must hold its native quiet
session; this module never opens a session or touches the device directly.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Callable


DURATIONS = frozenset({"30s", "1m", "2m", "3m", "4m", "5m", "never"})
_LOCAL_LOCK = threading.RLock()


class UserSettingChanged(RuntimeError):
    """The setting changed between policy read and the single proposed write."""


def _check_duration(value: str) -> str:
    if value not in DURATIONS:
        raise ValueError("unknown Auto-Lock duration")
    return value


@contextmanager
def _file_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with _LOCAL_LOCK, open(path, "a+b") as stream:
        stream.seek(0)
        stream.write(b"0")
        stream.flush()
        stream.seek(0)
        if os.name == "nt":
            import msvcrt

            msvcrt.locking(stream.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl

            fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == "nt":
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


class ManagedAutoLock:
    def __init__(self, state_dir: str | Path):
        self.state_dir = Path(state_dir)

    def _path(self, device: str) -> Path:
        if not device:
            raise ValueError("device identity is required")
        return self.state_dir / (hashlib.sha256(device.encode("utf-8")).hexdigest() + ".json")

    def status(self, device: str, owner: str) -> dict:
        """Read ownership without phone UI; fail closed on corrupt state."""
        if not owner:
            raise ValueError("owner is required")
        path = self._path(device)
        with _file_lock(path.with_suffix(".lock")):
            state = self._load(path)
            if state is None:
                return self._result("no_record", pending=False, owned_change=False)
            if state["owner"] != owner:
                return self._result("other_owner_pending", pending=True,
                                    owned_change=state["owned_change"])
            return self._result(state["phase"], pending=state["phase"] != "active",
                                owned_change=state["owned_change"])

    @staticmethod
    def _load(path: Path) -> dict | None:
        if not path.exists():
            return None
        value = json.loads(path.read_text(encoding="utf-8"))
        if (type(value) is not dict or type(value.get("version")) is not int or value["version"] != 1
                or type(value.get("original")) is not str or value["original"] not in DURATIONS
                or type(value.get("owner")) is not str or not value["owner"]
                or type(value.get("owned_change")) is not bool
                or type(value.get("phase")) is not str
                or value["phase"] not in {"active", "start_pending", "restore_pending"}
                or (value["original"] == "never" and value["owned_change"])):
            raise ValueError("invalid persisted Auto-Lock state")
        return value

    @staticmethod
    def _save(path: Path, value: dict | None) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        if value is None:
            path.unlink(missing_ok=True)
            return
        fd, name = tempfile.mkstemp(prefix=".autolock-", dir=path.parent)
        try:
            if os.name != "nt":
                os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
                json.dump(value, stream, ensure_ascii=False, separators=(",", ":"))
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, path)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    @staticmethod
    def _result(status: str, *, pending: bool, owned_change: bool) -> dict:
        return {"status": status, "pending": pending, "owned_change": owned_change}

    def _restore(self, path: Path, state: dict, read_current: Callable[[], str],
                 set_once: Callable[[str, str], None]) -> dict:
        current = _check_duration(read_current())
        if current != "never":
            self._save(path, None)
            return self._result("user_value_preserved", pending=False, owned_change=False)
        if not state["owned_change"]:
            self._save(path, None)
            return self._result("already_never", pending=False, owned_change=False)
        # Persist recovery intent before a possibly partial UI write. A failed
        # write stays pending; retries are explicit and never occur in this call.
        state["phase"] = "restore_pending"
        self._save(path, state)
        try:
            set_once(state["original"], "never")
            verified = _check_duration(read_current())
        except UserSettingChanged:
            self._save(path, None)
            return self._result("user_value_preserved", pending=False, owned_change=False)
        except Exception:
            return self._result("restore_pending", pending=True, owned_change=True)
        if verified != state["original"]:
            return self._result("restore_pending", pending=True, owned_change=True)
        self._save(path, None)
        return self._result("restored", pending=False, owned_change=False)

    def start(self, device: str, owner: str, read_current: Callable[[], str],
              set_once: Callable[[str, str], None]) -> dict:
        if not owner:
            raise ValueError("owner is required")
        path = self._path(device)
        with _file_lock(path.with_suffix(".lock")):
            state = self._load(path)
            if state:
                if state["owner"] != owner:
                    return self._result("other_owner_pending", pending=True,
                                        owned_change=state["owned_change"])
                if state["phase"] != "active":
                    recovery = self._restore(path, state, read_current, set_once)
                    if recovery["pending"]:
                        return recovery
                else:
                    current = _check_duration(read_current())
                    if current != "never":
                        self._save(path, None)
                        return self._result("user_value_preserved", pending=False,
                                            owned_change=False)
                    return self._result("already_active", pending=False,
                                        owned_change=state["owned_change"])
            current = _check_duration(read_current())
            if current == "never":
                self._save(path, {"version": 1, "owner": owner, "original": current,
                                  "owned_change": False, "phase": "active"})
                return self._result("already_never", pending=False, owned_change=False)
            state = {"version": 1, "owner": owner, "original": current,
                     "owned_change": True, "phase": "start_pending"}
            self._save(path, state)
            try:
                set_once("never", current)
                verified = _check_duration(read_current())
            except UserSettingChanged:
                self._save(path, None)
                return self._result("user_value_preserved", pending=False, owned_change=False)
            except Exception:
                return self._result("start_pending", pending=True, owned_change=True)
            if verified != "never":
                return self._result("start_pending", pending=True, owned_change=True)
            state["phase"] = "active"
            self._save(path, state)
            return self._result("active", pending=False, owned_change=True)

    def end(self, device: str, owner: str, read_current: Callable[[], str],
            set_once: Callable[[str, str], None]) -> dict:
        if not owner:
            raise ValueError("owner is required")
        path = self._path(device)
        with _file_lock(path.with_suffix(".lock")):
            state = self._load(path)
            if state is None:
                return self._result("no_record", pending=False, owned_change=False)
            if state["owner"] != owner:
                return self._result("other_owner_pending", pending=True,
                                    owned_change=state["owned_change"])
            return self._restore(path, state, read_current, set_once)

    def mark_restore_pending(self, device: str, owner: str) -> dict:
        """Record a failed end preflight without touching the phone."""
        if not owner:
            raise ValueError("owner is required")
        path = self._path(device)
        with _file_lock(path.with_suffix(".lock")):
            state = self._load(path)
            if state is None:
                return self._result("no_record", pending=False, owned_change=False)
            if state["owner"] != owner:
                return self._result("other_owner_pending", pending=True,
                                    owned_change=state["owned_change"])
            if state["owned_change"]:
                state["phase"] = "restore_pending"
                self._save(path, state)
                return self._result("restore_pending", pending=True, owned_change=True)
            self._save(path, None)
            return self._result("already_never", pending=False, owned_change=False)
