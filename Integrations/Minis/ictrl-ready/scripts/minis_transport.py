"""Existing Minis pairing transport. Import/help performs no device or store I/O."""
from __future__ import annotations

import importlib.util
import json
import math
import re
import secrets
import urllib.request
from pathlib import Path

from automation_session import READ_ONLY


def load_reference_client(path):
    path = Path(path).expanduser().resolve()
    if not path.is_file():
        raise RuntimeError("Phone-served reference client is missing")
    spec = importlib.util.spec_from_file_location("ictrl_minis_reference", path)
    client = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(client)
    if (not callable(getattr(client, "load_token", None))
            or not callable(getattr(client, "_call_with", None))
            or Path(client.STORE).expanduser().resolve()
            != (Path.home() / ".ictrl/token.json").resolve()):
        raise RuntimeError("Unexpected reference client API or pairing store")
    return client


def load_existing_record(client, store_key):
    """Normalize the already installed legacy record only in memory."""
    official = client.load_token(store_key)
    if official is not None:
        return official
    store = Path(client.STORE).expanduser().resolve()
    if store != (Path.home() / ".ictrl/token.json").resolve():
        raise ValueError("Unexpected pairing store")
    try:
        entries = json.loads(store.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(entries, dict):
        raise ValueError("Invalid pairing store")
    legacy = entries.get(store_key)
    if legacy is None:
        return None
    if (not isinstance(legacy, dict) or set(legacy) != {"tokId", "keyHex", "name"}
            or not isinstance(legacy["tokId"], str)
            or re.fullmatch(r"[0-9a-fA-F]{8}", legacy["tokId"]) is None
            or not isinstance(legacy["keyHex"], str)
            or re.fullmatch(r"[0-9a-fA-F]{64}", legacy["keyHex"]) is None
            or not isinstance(legacy["name"], str)
            or not 1 <= len(legacy["name"]) <= 128):
        raise ValueError("Invalid existing pairing entry")
    return {"tok": legacy["tokId"], "key": legacy["keyHex"], "client_name": legacy["name"]}


def is_read_only(command):
    """Conservative no-change subset; config with arguments is a write."""
    return (command["method"] in READ_ONLY
            and (command["method"] != "config" or command["params"] == {}))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def load_transport(store_key, client_path=None, timeout_budget=None):
    if (not isinstance(store_key, str)
            or not ((store_key.startswith("device:") and len(store_key) > 7)
                    or store_key == "127.0.0.1:8200")):
        raise ValueError("Explicit existing Minis pairing key required")
    client = load_reference_client(client_path or Path.home() / ".ictrl/bin/ictrl_rpc.py")
    record = load_existing_record(client, store_key)
    if record is None:
        raise RuntimeError("Existing Minis pairing required; no pairing request sent")

    def raw(method, params):
        # UI/AX operations can legitimately take longer than a status read.
        timeout = 5 if method.startswith("automation_") or method in {
            "device_info", "is_locked", "logs", "recent_logs", "config"
        } else 60
        if timeout_budget is not None:
            remaining = timeout_budget(method)
            if (type(remaining) not in (int, float)
                    or not math.isfinite(remaining) or remaining <= 0):
                raise TimeoutError("Task request budget exhausted; nothing sent")
            timeout = min(timeout, remaining)
        request_id = secrets.randbelow(2**53)
        try:
            status, reply = client._call_with("127.0.0.1:8200", record,
                                             method, params, timeout, request_id)
        except SystemExit as error:
            raise OSError("Authenticated transport verification failed; outcome unknown") from error
        if (status != 200 or not isinstance(reply, dict)
                or reply.get("id") != request_id or reply.get("jsonrpc") != "2.0"
                or "error" in reply):
            raise RuntimeError("Authenticated RPC rejected or mismatched; not replayed")
        result = reply.get("result")
        if not isinstance(result, dict):
            raise RuntimeError("Malformed result")
        return result

    request = urllib.request.Request("http://127.0.0.1:8200/schema",
                                     headers={"Cache-Control": "no-cache"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=3) as response:
        if response.status != 200:
            raise RuntimeError("Schema response rejected")
        schema = json.load(response)
    if not isinstance(schema, dict) or not isinstance(schema.get("methods"), list):
        raise RuntimeError("Malformed schema")
    if store_key.startswith("device:"):
        info = raw("device_info", {})
        device_id = info.get("device_id")
        if (not isinstance(device_id, str)
                or client.device_store_key(device_id) != store_key):
            raise RuntimeError("Paired device identity mismatch")
    supported = any(isinstance(method, dict) and method.get("name") == "automation_begin"
                    for method in schema["methods"])
    return raw, supported
