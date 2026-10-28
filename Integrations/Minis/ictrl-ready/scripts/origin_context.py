"""Resolve a completed prepare tool call to its originating Minis chat, never latest."""
import json
import re
import shlex
import subprocess

ID = re.compile(r"^[a-zA-Z0-9_-]{1,128}$")
NONCE = re.compile(r"^[a-f0-9]{32}$")

class OriginContextError(RuntimeError):
    pass


def is_prepare_command(command, task_id, nonce):
    if not isinstance(command, str) or len(command) > 50000: return False
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|")
        lexer.whitespace_split = True; lexer.commenters = "#"
        tokens = list(lexer)
    except ValueError: return False
    parts = []; current = []
    for token in tokens + ["&&"]:
        if token in {"&&", ";"}:
            parts.append(current); current = []
        elif token in {"|", "||", "&"}: return False
        else: current.append(token)
    expected = ["prepare", "--task-id", task_id, "--origin-nonce", nonce]
    found = 0
    for part in parts:
        if part and part[0] in {"python3", "python"}:
            args = part[1:]
            if args[:1] == ["-B"]: args = args[1:]
            if args and args[0].endswith("/.ictrl/runtime/task_session.py") and args[1:] in [expected, ["prepare"]]:
                found += 1
    return found == 1


def prepared_result(result, task_id, nonce):
    if result.get("success") is not True or result.get("output_truncated") is True: return False
    output = result.get("output")
    if not isinstance(output, str) or len(output) > 50000: return False
    matches = 0
    for line in output.splitlines():
        try: receipt = json.loads(line)
        except ValueError: continue
        if isinstance(receipt, dict) and receipt.get("kind") == "ictrl_origin_prepared" and receipt.get("task_id") == task_id and receipt.get("origin_nonce") == nonce:
            matches += 1
    return matches == 1


def cli_json(args):
    try:
        result = subprocess.run(["minis-sessions-cli", *args, "--compact"], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, check=True, timeout=8)
        if len(result.stdout) > 12 * 1024 * 1024: raise OriginContextError("origin response too large")
        value = json.loads(result.stdout)
        if not isinstance(value, dict) or not isinstance(value.get("data"), dict):
            raise OriginContextError("origin response invalid")
        return value["data"]
    except OriginContextError: raise
    except Exception: raise OriginContextError("origin query unavailable") from None


def resolve_origin(task_id, nonce, query=cli_json):
    if not NONCE.fullmatch(task_id) or not NONCE.fullmatch(nonce):
        raise OriginContextError("invalid origin correlation")
    # list queries parts_json globally before LIMIT. Two hits suffice to refuse ambiguity.
    listed = query(["list", "--keywords", nonce, "--limit", "2"])
    sessions = listed.get("sessions")
    if not isinstance(sessions, list) or type(listed.get("count")) is not int or listed["count"] != 1 or len(sessions) != 1:
        raise OriginContextError("origin must match exactly one session")
    candidate = sessions[0]; sid = candidate.get("session_id"); total = candidate.get("message_count")
    if not isinstance(sid, str) or not ID.fullmatch(sid) or type(total) is not int or total < 1:
        raise OriginContextError("origin session metadata invalid")
    # Prepare must belong to a prior completed tool round, not an old guessed chat.
    offset = max(0, total - 20)
    data = query(["messages", "--id", sid, "--offset", str(offset), "--limit", "20", "--full", "--tools"])
    messages = data.get("messages")
    if data.get("session_id") != sid or data.get("tools") is not True or not isinstance(messages, list):
        raise OriginContextError("origin tool records unavailable")
    matches = []; successes = set()
    for message in messages:
        for result in message.get("tool_results", []):
            if prepared_result(result, task_id, nonce) and isinstance(result.get("tool_use_id"), str):
                successes.add(result["tool_use_id"])
        if message.get("role") != "assistant": continue
        for call in message.get("tool_calls", []):
            if call.get("name") != "shell_execute" or call.get("input_truncated") is True: continue
            try: payload = json.loads(call["input"])
            except (ValueError, TypeError, KeyError): continue
            if is_prepare_command(payload.get("command"), task_id, nonce): matches.append(call.get("tool_use_id"))
    if len(matches) != 1 or not isinstance(matches[0], str) or matches[0] not in successes:
        raise OriginContextError("completed origin prepare tool not uniquely verified")
    return {"session_id": sid, "tool_use_id": matches[0], "source": "completed_prepare_tool_nonce"}
