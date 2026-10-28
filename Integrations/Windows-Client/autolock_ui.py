"""Conservative Chinese iOS Settings Auto-Lock adapter for a caller-held quiet session.

Only existing RPCs are used. Unknown UI or ambiguous completion stops; callers
must keep the policy's pending record and re-observe before another action.
"""

from __future__ import annotations

import re
from typing import Callable

from managed_autolock import DURATIONS, ManagedAutoLock, UserSettingChanged


PREFS = "com.apple.Preferences"
IDS = {"30s": "30", "1m": "60", "2m": "120", "3m": "180", "4m": "240", "5m": "300", "never": "-1"}
LABELS = {"30s": "30秒钟", "1m": "1分钟", "2m": "2分钟", "3m": "3分钟", "4m": "4分钟", "5m": "5分钟", "never": "永不"}
ROW = re.compile(r"^(?P<spaces> *)Cell, label: '(?P<label>[^']+)', id: '(?P<id>-?\d+)', \{\{(?P<x>\d+), (?P<y>\d+)\}, \{(?P<w>\d+), (?P<h>\d+)\}\}$")
BUNDLE_ID = re.compile(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+")


class UIConflict(RuntimeError):
    pass


def parse_parent(snapshot: dict) -> str:
    _snapshot(snapshot, "显示与亮度")
    source = snapshot["source"]
    found = re.findall(r"^ *Cell, label: '自动锁定、([^']+)', id: 'AUTOLOCK',", source, re.M)
    if len(found) != 1:
        raise UIConflict("Auto-Lock parent value is absent or ambiguous")
    matches = [key for key, label in LABELS.items() if label == found[0]]
    if len(matches) != 1:
        raise UIConflict("unknown Auto-Lock parent value")
    return matches[0]


def parse_options(snapshot: dict) -> str:
    _snapshot(snapshot, "自动锁定")
    lines = snapshot["source"].splitlines()
    found = {}
    selected = []
    for index, line in enumerate(lines):
        match = ROW.fullmatch(line)
        if not match:
            continue
        key = next((k for k, v in IDS.items() if v == match["id"]), None)
        if key is None or LABELS[key] != match["label"] or key in found:
            raise UIConflict("unexpected Auto-Lock option")
        found[key] = match
        indent = len(match["spaces"])
        descendants = []
        for following in lines[index + 1:]:
            if len(following) - len(following.lstrip(" ")) <= indent:
                break
            descendants.append(following)
        if any("Button, label: 'checkmark'" in item for item in descendants):
            selected.append(key)
    if set(found) != DURATIONS or len(selected) != 1:
        raise UIConflict("option set or selected checkmark is ambiguous")
    return selected[0]


def _snapshot(value: dict, nav: str) -> None:
    if not isinstance(value, dict) or value.get("bundle_id") != PREFS or value.get("truncated"):
        raise UIConflict("Settings source unavailable")
    if value.get("keyboard", {}).get("visible"):
        raise UIConflict("keyboard obscures Settings")
    if "Alert," in value.get("source", "") or "SBTransientOverlayWindow" in value.get("source", ""):
        raise UIConflict("system modal obscures Settings")
    if f"NavigationBar, id: '{nav}'" not in value.get("source", ""):
        raise UIConflict("unexpected Settings page or overlay")


class AutoLockUI:
    def __init__(self, rpc: Callable[[str, dict], dict]):
        self.rpc = rpc

    def _call(self, method: str, params: dict | None = None) -> dict:
        result = self.rpc(method, params or {})
        if not isinstance(result, dict) or result.get("error"):
            raise UIConflict(f"{method} failed")
        return result.get("result", result)

    def _foreground(self) -> str:
        info = self._call("device_info")
        system = info.get("system") or {}
        if system.get("screen_locked") is not False:
            raise UIConflict("device locked")
        app = system.get("foreground_app")
        if isinstance(app, dict):
            app = app.get("bundle_id")
        if not isinstance(app, str) or BUNDLE_ID.fullmatch(app) is None:
            raise UIConflict("foreground app unavailable")
        return app

    def _source(self) -> dict:
        if self._foreground() != PREFS:
            raise UIConflict("Settings lost foreground")
        return self._call("page_source", {"max_depth": 40, "max_children": 1000,
                                          "max_elements": 240, "visible_only": True})

    def _nav(self, snapshot: dict) -> str:
        if snapshot.get("bundle_id") != PREFS or snapshot.get("truncated"):
            raise UIConflict("Settings page unavailable")
        if "Alert," in snapshot.get("source", "") or "SBTransientOverlayWindow" in snapshot.get("source", ""):
            raise UIConflict("Settings modal is present")
        names = re.findall(r"^ *NavigationBar, id: '([^']+)'", snapshot["source"], re.M)
        if len(names) != 1:
            raise UIConflict("Settings navigation is ambiguous")
        return names[0]

    def enter_display(self) -> None:
        """Position at Display & Brightness; caller owns foreground return."""
        current = self._foreground()
        if current != PREFS:
            self._call("launch_app", {"bundle_id": PREFS})
        for _ in range(9):
            snap = self._source()
            nav = self._nav(snap)
            if nav == "显示与亮度":
                return
            if nav == "设置":
                break
            if "id: 'BackButton'" not in snap["source"]:
                raise UIConflict("Settings page has no known Back button")
            self._tap_id("BackButton", "button", nav)
        else:
            raise UIConflict("Settings root not reached within eight Back actions")
        # Scroll may report an off-screen/covered row; always re-find the live
        # button and require its centre in the content band before tapping.
        label = "显示与亮度"
        self._call("scroll_to_element", {"element_id": label, "element_type": "button",
                                          "bundle_id": PREFS, "match": "exact", "distance": 4})
        for _ in range(3):
            snap = self._source()
            if self._nav(snap) != "设置":
                raise UIConflict("Settings changed during navigation")
            hit = self._call("find_element", {"element_id": label, "element_type": "button",
                                              "bundle_id": PREFS, "match": "exact"})
            y = hit.get("center_y")
            height = self._call("device_info").get("point_height")
            if not isinstance(y, (int, float)) or not isinstance(height, (int, float)):
                raise UIConflict("target geometry unavailable")
            if 120 < y < height - 130 and hit.get("ref") and hit.get("match_count", 1) == 1:
                if self._foreground() != PREFS:
                    raise UIConflict("Settings lost foreground")
                self._call("tap", {"ref": hit["ref"]})
                if self._nav(self._source()) != "显示与亮度":
                    raise UIConflict("Display page not opened")
                return
            # Scroll a small amount, then fresh-find; never tap covered y≈850.
            self._call("swipe", {"x": 376, "y": min(height - 184, 690),
                                 "direction": "up", "distance": 280, "velocity": "slow"})
        raise UIConflict("Display row remains covered")

    def _tap_id(self, identifier: str, kind: str, nav: str) -> None:
        _snapshot(self._source(), nav)
        hit = self._call("find_element", {"element_id": identifier, "element_type": kind,
                                          "bundle_id": PREFS, "match": "exact"})
        ref = hit.get("ref")
        if (not ref or hit.get("found") is False or hit.get("match_count", 1) != 1
                or hit.get("visibility", "in_view") != "in_view" or hit.get("hittable") is False):
            raise UIConflict("target ref absent or ambiguous")
        if self._foreground() != PREFS:
            raise UIConflict("Settings lost foreground before tap")
        self._call("tap", {"ref": ref})  # Exactly one tap; exceptions are uncertain completion.

    def read_current(self) -> str:
        parent = self._source()
        value = parse_parent(parent)
        self._tap_id("AUTOLOCK", "button", "显示与亮度")
        child = self._source()
        selected = parse_options(child)
        if selected != value:
            raise UIConflict("parent and checkmark disagree")
        self._tap_id("BackButton", "button", "自动锁定")
        after = parse_parent(self._source())
        if after != value:
            raise UIConflict("Auto-Lock value changed during read")
        return value

    def set_once(self, duration: str, expected_current: str) -> None:
        if duration not in DURATIONS or expected_current not in DURATIONS:
            raise ValueError("unknown duration")
        parent = parse_parent(self._source())
        self._tap_id("AUTOLOCK", "button", "显示与亮度")
        selected = parse_options(self._source())
        if selected != parent:
            raise UIConflict("parent and checkmark disagree")
        if selected != expected_current:
            raise UserSettingChanged("Auto-Lock changed before write")
        if selected == duration:
            self._tap_id("BackButton", "button", "自动锁定")
            return
        self._tap_id(IDS[duration], "cell", "自动锁定")
        # One setting action only. The option page may remain open or auto-pop;
        # navigate back if needed so the policy can independently read back.
        after = self._source()
        if "NavigationBar, id: '自动锁定'" in after["source"]:
            self._tap_id("BackButton", "button", "自动锁定")
        else:
            _snapshot(after, "显示与亮度")


def managed_start(manager: ManagedAutoLock, device: str, owner: str, ui: AutoLockUI) -> dict:
    return manager.start(device, owner, ui.read_current, ui.set_once)


def managed_end(manager: ManagedAutoLock, device: str, owner: str, ui: AutoLockUI) -> dict:
    return manager.end(device, owner, ui.read_current, ui.set_once)


def _return_foreground(ui: AutoLockUI, original: str) -> bool:
    if original == PREFS:
        return ui._foreground() == PREFS
    if ui._foreground() != PREFS:
        return False  # User switched apps; don't seize foreground.
    try:
        nav = ui._nav(ui._source())
    except UIConflict:
        return False
    if nav not in ("显示与亮度", "自动锁定"):
        return False
    if original == "com.apple.springboard":
        snap = ui._call("page_source", {"bundle_id": "com.apple.springboard", "max_depth": 12,
                                        "max_elements": 120})
        source = snap.get("source", "")
        if ("SBTransientOverlayWindow" in source or "Alert," in source
                or not re.search(r"(?:Icon|Application), label:", source)):
            return False
        ui._call("home")
    elif BUNDLE_ID.fullmatch(original) is not None and original != PREFS:
        ui._call("launch_app", {"bundle_id": original})
    else:
        return False
    return ui._foreground() == original


def run_managed(manager: ManagedAutoLock, device: str, owner: str, ui: AutoLockUI,
                *, ending: bool = False) -> dict:
    """Run inside an existing native quiet session, before its EndFocus."""
    original = ui._foreground()
    if original == "com.apple.springboard":
        snap = ui._call("page_source", {"bundle_id": original, "max_depth": 12, "max_elements": 120})
        if "SBTransientOverlayWindow" in snap.get("source", "") or "Alert," in snap.get("source", ""):
            raise UIConflict("SpringBoard modal is present")
    result = None
    returned = False
    try:
        ui.enter_display()
        result = (managed_end if ending else managed_start)(manager, device, owner, ui)
    finally:
        try:
            returned = _return_foreground(ui, original)
        except Exception:
            returned = False
    if result is None:
        raise UIConflict("Settings navigation failed; no Auto-Lock result")
    return {**result, "returned_to_original_app": returned}
