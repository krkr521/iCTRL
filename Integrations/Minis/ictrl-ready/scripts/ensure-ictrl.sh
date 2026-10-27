#!/bin/sh
# Run INSIDE Minis. No VPN changes, clipboard access, pairing or RPC replay.
# Official apple-open exit 0 may still contain data.opened=false.
set -eu
schema_url='http://127.0.0.1:8200/schema'
startup_url='ictrl-app://prepare?mount_if_needed=0&keep_awake=1&callback=minis%3A%2F%2F'
native_start_requested=false

if ! command -v curl >/dev/null 2>&1; then
    printf '%s\n' '{"ok":false,"reason":"curl_unavailable","native_start_requested":false,"requires_user_action":true}'
    exit 2
fi
if command -v python3 >/dev/null 2>&1; then
    json_parser=python3
elif command -v jq >/dev/null 2>&1; then
    json_parser=jq
else
    printf '%s\n' '{"ok":false,"reason":"json_parser_unavailable","native_start_requested":false,"requires_user_action":true,"next_step":"Install python3 or jq in Minis, then rerun this check"}'
    exit 2
fi

json_check() {
    # stdin is data, never shell code. Reject malformed JSON and wrong types.
    if [ "$json_parser" = python3 ]; then
        python3 -c '
import json, sys
try:
    obj = json.load(sys.stdin)
    valid = isinstance(obj, dict)
    if sys.argv[1] == "schema":
        valid = (valid and obj.get("protocol") == "JSON-RPC 2.0"
                 and type(obj.get("protocol_version")) in (int, float)
                 and obj["protocol_version"] >= 1 and obj["protocol_version"] % 1 == 0
                 and isinstance(obj.get("server_version"), str) and bool(obj["server_version"].strip())
                 and isinstance(obj.get("methods"), list) and bool(obj["methods"])
                 and all(isinstance(m, dict) and isinstance(m.get("name"), str)
                         and bool(m["name"].strip()) for m in obj["methods"]))
    else:
        valid = (valid and obj.get("ok") is True and obj.get("tool") == "apple-open"
                 and obj.get("action") == "open" and isinstance(obj.get("data"), dict)
                 and obj["data"].get("opened") is True and obj["data"].get("url") == sys.argv[2])
    sys.exit(0 if valid else 1)
except (ValueError, TypeError, KeyError, UnicodeError, RecursionError):
    sys.exit(1)
' "$1" "$startup_url" 2>/dev/null
    elif [ "$1" = schema ]; then
        jq -e -s 'length == 1 and (.[0] |
            type == "object" and .protocol == "JSON-RPC 2.0" and
            (.protocol_version | type == "number" and . >= 1 and floor == .) and
            (.server_version | type == "string" and test("\\S")) and
            (.methods | type == "array" and length > 0 and
                all(.[]; type == "object" and (.name | type == "string" and test("\\S")))))' >/dev/null 2>&1
    else
        jq -e -s --arg requested "$startup_url" 'length == 1 and (.[0] |
            type == "object" and .ok == true and .tool == "apple-open" and .action == "open" and
            (.data | type == "object" and .opened == true and .url == $requested))' >/dev/null 2>&1
    fi
}

probe() {
    # Bypass proxy routing for this loopback GET without modifying proxy env.
    # curl -f does not reject redirects. Require the actual endpoint's HTTP 200.
    response=$(curl -q -fsS --noproxy 127.0.0.1 --connect-timeout 1 --max-time 2 --write-out '\n%{http_code}' "$schema_url" 2>/dev/null) || return 1
    newline='
'
    status=${response##*"$newline"}
    [ "$status" = 200 ] || return 1
    result=${response%"$newline"*}
    printf '%s\n' "$result" | json_check schema
}

ready() {
    printf '{"ok":true,"reason":"schema_ready","native_start_requested":%s,"shortcut_requested":false,"vpn_change_requested":false,"readiness_scope":"schema_only"}\n' "$native_start_requested"
    exit 0
}

if probe; then
    ready
fi
if ! command -v apple-open >/dev/null 2>&1; then
    printf '%s\n' '{"ok":false,"reason":"apple_open_unavailable","native_start_requested":false,"requires_user_action":true,"next_step":"Open iCTRL manually, return to Minis and rerun this check"}'
    exit 2
fi
if ! command -v sleep >/dev/null 2>&1; then
    printf '%s\n' '{"ok":false,"reason":"sleep_unavailable","native_start_requested":false,"requires_user_action":true}'
    exit 2
fi

# One native prepare request. mount_if_needed=0 preserves the current VPN.
# The registered minis:// callback only asks iOS to foreground Minis. Its
# ictrl_result query is not delivered to this shell; do not invent a result.
# iOS may suspend this process while iCTRL/Runner is foreground. If the
# callback cannot return to the current conversation, return to Minis manually.
native_start_requested=true
if ! opened=$(apple-open "$startup_url" --compact 2>/dev/null); then
    printf '%s\n' '{"ok":false,"reason":"native_open_command_failed","native_start_requested":true,"shortcut_requested":false,"vpn_change_requested":false,"startup_verified":false,"requires_user_action":true,"next_step":"Check that the iCTRL build supports ictrl-app://prepare; return to Minis and check again after manual launch"}'
    exit 1
fi
if ! printf '%s\n' "$opened" | json_check open; then
    printf '%s\n' '{"ok":false,"reason":"native_open_not_confirmed","native_start_requested":true,"shortcut_requested":false,"vpn_change_requested":false,"startup_verified":false,"requires_user_action":true,"next_step":"apple-open did not confirm opening the native URL; install the matching iCTRL build or launch manually, then return to Minis"}'
    exit 1
fi

# At most 15 post-open GETs and 14 one-second sleeps. Each HTTP request has a
# two-second cap. This is an active-execution bound, not an iOS suspension SLA.
remaining=15
while [ "$remaining" -gt 0 ]; do
    if probe; then
        ready
    fi
    remaining=$((remaining - 1))
    [ "$remaining" -gt 0 ] || break
    if ! sleep 1; then
        printf '%s\n' '{"ok":false,"reason":"wait_interrupted","native_start_requested":true,"startup_verified":false,"requires_user_action":true}'
        exit 1
    fi
done
printf '%s\n' '{"ok":false,"reason":"startup_not_verified","native_start_requested":true,"shortcut_requested":false,"vpn_change_requested":false,"startup_verified":false,"ddi_status":"unobserved","requires_user_action":true,"next_step":"Return to Minis if needed. Check the existing DDI mounting page in iCTRL; if it shows DDI is not mounted, use Wi-Fi and the explicit Prepare DDI and Start flow. Older iCTRL builds may open without supporting prepare. Do not loop startup or replay control actions"}'
exit 1
