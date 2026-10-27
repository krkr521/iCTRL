# Quiet control integration (disabled by default)

This is native server wiring, not a verified notification solution. After the human validates both Shortcuts and the dedicated Focus, an authenticated device-local client calls `automation_config {"enabled":true}`. `automation_config {}` reads the switch. It defaults false and persists alongside non-secret token-mode mapping in Runner Application Support `iCTRL/quiet_control.json`; corrupt/unreadable storage blocks UI rather than silently downgrading automation. Registration as automation is allowed while disabled but Begin fails. To retire an automation token, revoke its pairing using existing admin `config`; `automation_register(mode=manual)` cannot downgrade it. Restart loses process-local leases but retains token modes and the enabled switch; it does not reconstruct or modify a Focus. The phone requires a newly built IPA for this code; no current installed build has it.

## Authenticated RPC contract

Each method uses the existing encrypted `/rpc` envelope. The server binds ownership to the authenticated `opened.tokId`, never `client_name` or source address. `automation_register {"mode":"automation"|"manual"}` is per token and persisted across Runner restarts. Existing unregistered clients are legacy manual; they never trigger quiet. A token registered automation cannot send UI input without a valid verified lease, even when `automation_session` is omitted. A supplied invalid/old/expired `automation_session` never falls back to manual. A manual token can send UI while no Agent lease is active. During a lease, a manual token first calls `automation_takeover {"mode":"manual"}` and waits for `manual_ready`; it cannot continue on `ending` or `restoration_pending`.

`automation_begin {"ttl_seconds":1..300}` returns `{lease_id,state:"preparing",deadline:<UTC ISO8601>}`; only one Agent lease exists. It launches `iCTRL Quiet Begin` through the normal Runner UI lane. A lost Begin response is ambiguous: call read-only `automation_owner_status {}` and do not retry Begin. `automation_status {"lease_id":...}` is read-only. Every automated UI mutation carries `automation_session:<lease_id>` and must follow a `quiet_verified` status. `automation_end {"lease_id":...}` revokes UI permission immediately and launches `iCTRL Quiet Inspect End` once; repeat End returns current state without relaunch. On Begin timeout, fail/expiry or crash, no UI is replayed. The system Focus Until deadline is the crash fallback, not a guarantee of second-accurate background execution. After `restoration_pending` and the lease deadline plus 300 seconds, a registered manual token can call `automation_inspect {}`. It launches a new read-only inspection with a fresh nonce. Only a matching `off` or `preserved_user_focus` callback changes takeover state to `manual_ready`; missing callback or active dedicated Focus leaves manual UI blocked. Retry inspection with a new nonce after its 30-second timeout.

Each helper launch first captures the foreground app on the serial UI lane. Begin saves the pre-helper app; End and Inspect save the current task app or Home, falling back to Begin's saved app if Shortcuts is still in front. A matching callback enters `restoring` and is acknowledged without waiting for UI work. The Runner then restores the captured app on that same UI lane and confirms it is frontmost before `quiet_verified` or `manual_ready` can be reported. Home uses the verified Home-button path. If capture or confirmation fails, `context_diagnostic` explains the blocked state. A stale restoration completion after takeover or lease expiry cannot authorize input. The callback's HTTP 204 alone never authorizes input.
If Begin cannot capture a valid original app before it attempts to open Shortcuts, it ends that lease without ever granting automated input and releases manual UI immediately. The old callback nonce cannot revive it. Once opening a helper has been attempted, even a false return or exception is treated as uncertain and stays blocked. End and Inspect also stay blocked on a capture failure because an earlier Begin may have changed Focus.
If Begin's callback arrives but foreground restoration fails or times out, the lease remains blocked and permits one conditional End attempt. Once End has been attempted, later `restoration_pending` states cannot relaunch End; recovery uses the post-deadline read-only inspection.

## Exact Shortcut input and callback

The Runner opens Apple's `shortcuts://run-shortcut` URL with `name=iCTRL Quiet Begin` or `iCTRL Quiet Inspect End`, `input=text`, and URL-encoded JSON `text`. JSON fields: `action` (`begin`, `end`, or `inspect`), `nonce` (43 URL-safe base64 chars, fresh 32 random bytes), `deadline` (UTC ISO8601), `callback` (exactly `http://127.0.0.1:<Runner port>/quiet-callback`). For `inspect`, input also has `inspect_only:"1"`; the Inspect End Shortcut must only call Get Current Focus and report it, with no Set Focus action. The Runner must never log the launch URL or nonce. The Shortcut sends one `POST` to that fixed callback URL, `Content-Type: application/json`, JSON body `{ "nonce":"...", "action":"begin|end|inspect", "observed_focus":"...", "deadline":"..." }`. Body ≤1024 bytes, headers ≤4096 bytes; path has no query, and callback is accepted only from loopback within 30 seconds, once. Long-lived pairing keys never enter Shortcut input. This nonce reports the Shortcut's observation; it is not a system attestation.

Human-authored **Begin** actions: parse and validate input; reject stale Begin deadline. `Get Current Focus`; if nonempty, POST `observed_focus:"previous_focus_active"` and stop without changing it. If empty, `Set Focus iCTRL Automation On Until Date` from input, never Toggle. `Get Current Focus` again; POST `observed_focus:"iCTRL Automation"` only when that exact Focus is observed, otherwise `"unavailable"`. Do not tap the target app.

Human-authored **Inspect End** actions: validate fields and callback, but accept an already passed deadline for cleanup. `Get Current Focus`. If and only if exactly `iCTRL Automation`, `Set Focus iCTRL Automation Off`; read Focus again and POST `"off"` if empty, else `"preserved_user_focus"`. If another Focus or no Focus is active, do not set anything and POST `"preserved_user_focus"` (or `"off"` for empty). Never restore a saved Focus name or Toggle.

The user configures `iCTRL Automation` with no ordinary allowed apps/people and relevant breakthrough options off, and verifies actual message banners. An existing DND/Work/Sleep Focus makes Begin fail rather than overwrite it. Focus is global, so Agent and manual web cannot simultaneously have opposite notification behavior. iOS may still show critical/emergency/system alerts. The app's `INFocusStatusCenter` cannot report the Focus name or set Focus; it is not used here.

## Safe diagnostic observations

Diagnostics do not change the TTL, callback admission, single-use nonce,
foreground confirmation, End idempotency, or manual-recovery rules. The only
accepted callback body and HTTP status behavior remain the contract above.

Quiet log lines use a finite `event`, `action`, `classification`, `focus_result`,
`state`, `reason`, and optional End `source`. They never include a callback body,
URL, nonce, lease/token identity, arbitrary Focus/app name, or exception text.
Framing rejection is `framing_413`; forbidden origin/query is
`origin_query_403`; parser failures are `contract_400`, `content_type_400`,
`size_400`, `json_shape_400`, `nonce_shape_400`, `action_400`, `focus_value_400`,
or `deadline_400`. Parser/HTTP rejection uses `action=unknown`. A fully parsed
report can use only begin/end/inspect and dedicated/previous/unavailable/off/
preserved/other_allowed. These are reported observations, not system attestation.
Lease rejection identifies a missing pending callback, nonce/action/deadline
mismatch, invalid clock, elapsed callback window, expired lease, or wrong state
with a fixed `_409` classification. Accepted is `accepted_204`; it still requires
foreground restoration before authorization. End source is exactly `owner_end`,
`ttl_expiry`, or `manual_takeover` when an End launch is actually prepared.

Owner-bound `automation_status` / `automation_owner_status` may additionally
return `begin_diagnostic`, `begin_callback_classification`, `begin_focus_result`,
`begin_context_diagnostic`,
`last_callback_classification`, and `last_callback_action`. They are process-local,
reset for a new lease, and absent for another token's lease. End does not erase
the Begin result: a successful End can leave `context_diagnostic` empty while
`begin_diagnostic=callback_window_elapsed` still explains why recovery is pending.
Only nonce-associated parsed reports update callback fields; malformed or
unmatched reports appear in safe logs without being attributed to an owner.
Missing owner callback fields do not prove that no HTTP request arrived.

Native clipboard logs contain only a validated method and fixed stage/reason.
The eight-second pending reply logs the last entered stage: queued, prepare,
foreground_lookup, foreground_activation, foreground_wait, access,
permission_pending, or restore. `permission_pending` means the string accessor
was entered; it does not prove that a system permission dialog is visible.
No clipboard text, byte count, change count, original app, or exception is logged.
Timeout still neither cancels UIKit nor releases busy, and must not trigger a
retry. Payload and RPC response behavior are unchanged.

`Scripts/build-unsigned.sh` runs the full Foundation `swift test` suite before
building the two apps. This includes `QuietDiagnosticTests` for parser classes,
safe formatting, unchanged lease boundaries, owner isolation, and preservation
of Begin failures through End. The iOS UI queue, real HTTP framing, clipboard
permission prompts, and installed Shortcuts still require device acceptance.

## Bounded foreground capture before a helper

Before the single helper launch, Quiet reads the foreground on the serial UI
lane for up to two seconds, polling at least 100 ms apart. A candidate bundle
name (including the Runner itself, direct XCTest naming, and remembered apps)
is accepted only when its freshly queried PID equals the nonzero foreground
PID both before and after that query. Candidates are deduplicated; an incorrect
remembered candidate does not prevent checking other candidates. No PID/name
mapping or normal RPC resolver behavior is changed by this capture.

Two consecutive samples must agree on both bundle and PID. Unknown or changed
samples reset stability. Server identity, the existing lease/nonce launch gate,
and the capture budget are checked around each main-queue read and before the
one helper open. If a final check fails after launch was marked attempted, the
existing conservative failure path applies; it cannot release the lease as a
proved unsent Begin. Callback admission, Focus evidence, the original restore
PID confirmation, and End idempotency are unchanged.

The budget prevents starting another read or launch after it expires. A
synchronous private XCTest call already in progress cannot be interrupted; a
late result cannot authorize a launch. Missing candidate names or consistently
unavailable/inconsistent PID APIs still fail closed. Source/policy tests cannot
prove that a particular device transition is transient or that a real app has
been restored. `QuietForegroundCaptureTests` covers candidate mismatch,
read-gate cancellation, stability, and the existing lease boundaries.

## Limits requiring device acceptance

Confirm on this iOS build that Shortcuts exposes Get Current Focus and Set Focus Until Date, can receive the URL text while locked/backgrounded, and can POST to the Runner's loopback port. Confirm real message-banner behavior while the target app is visible and on manual takeover. Opening a Shortcut URL or obtaining HTTP 204 alone is insufficient. If Begin was still running or its callback was lost, an early End `off` report does not prove that Begin cannot turn Focus on later. The server retains `restoration_pending` and blocks manual UI until the deadline plus safety margin and a fresh inspection reports off or preserved user Focus. Same-name off/on (ABA) by the user remains unobservable. Physical touch pause is not implemented.
