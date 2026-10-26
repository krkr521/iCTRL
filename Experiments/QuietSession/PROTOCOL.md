# iCTRL quiet lease v1 (prototype, not deployed)

## Preconditions and boundary

The human creates Focus `iCTRL Automation` with no ordinary notification exceptions and two reviewed Shortcuts. This prototype is disabled by default until those are installed and tested on the actual phone. An existing Focus of any name, including DND, makes Begin fail without changing it. Focus is global. A manual web session can keep normal notifications only after explicitly taking over and suspending an Agent lease. Unknown older clients cannot be classified by `clientName` or loopback origin; a production migration must explicitly register manual or automation mode. Current native2 does not implement this protocol.

## Authenticated RPC methods

The normal RPC authentication remains required. `automation_begin({ttl_seconds})` binds the lease to the authenticated transport's `opened.tokId`, accepts 1...300 seconds, creates a fresh random session/lease id per Begin with a hard absolute deadline no later than now+300s, and returns `{lease_id, state:"preparing", deadline}`. Never use `tokId` itself as session id; an old session from the same transport cannot be replayed. Exactly one Agent session may own it. Other sessions get `busy`; no UI is queued or replayed. The coordinator starts the Begin Shortcut through the existing Runner URL action on the normal UI lane, then returns immediately. `open_url` accepted is never success. It must not hold the UI lane while awaiting a callback.

`automation_status({lease_id})` is read-only and returns state/deadline. `automation_owner_status({})` is authenticated, read-only and scoped to the transport owner; it exposes current lease id/state after a lost Begin reply. Never blindly retry Begin after an unknown outcome. `automation_end({lease_id})` immediately revokes UI and starts Inspect/End even from failed/preparing/expired, since Set Focus may have happened without a callback. Repeated End is idempotent and does not launch a second Shortcut. A bounded cleanup window (up to 300 seconds after UI deadline; each callback at most 30 seconds) is separate from UI authorization. After it, mark `restoration_pending` for manual inspection. End never extends a lease. `automation_takeover({mode:"manual"})` is an explicit handoff: revoke the Agent UI gate first; only after Inspect/End confirms that Focus is off or a different Focus is active may the manual UI gate open. A failed/unconfirmed restore leaves takeover pending; it never silently lets Agent continue. Manual web operation never calls quiet Begin automatically.

Every Agent UI mutation carries `automation_session: lease_id`, plus the authenticated `opened.tokId` transport binding. An invalid, old or expired `automation_session` fails closed and never falls back to manual. UI mutations with no automation session follow the explicit manual/legacy path and never trigger quiet. While an Agent lease is active, all other clients' UI mutations are rejected until explicit takeover. Apply gate on the server before enqueue; execute gate-sensitive work on the normal UI lane. Read-only status remains available. Never infer Agent/manual identity from `clientName` or loopback. Server restart starts with no active leases.

## Shortcut callback

For each invocation server generates 32 random bytes (URL-safe base64, 43 chars), keeps only in memory with 30-second expiry, single use, lease id, action and deadline. Reject another pending registration and never reuse a nonce, including across Begin/End. The launched Shortcuts URL carries `action=begin|end`, `nonce`, `deadline` in UTC ISO-8601 and loopback callback URL. Never log that launch URL, nonce or input text, and never place the long-lived pairing key in Shortcut input or URL. The Shortcut sends `POST http://127.0.0.1:<fixed-port>/quiet-callback` with JSON `{nonce, action, observed_focus, deadline}` and `Content-Type: application/json`; nonce is only in the body, never callback path/query. The callback server accepts only fixed path/method/content type, caps total headers at 4 KiB and body at 1024 bytes, and accepts case-insensitive `application/json` with optional UTF-8 charset only, then validates exact nonce, action, deadline, single consumption, and either live Begin lease or bounded End cleanup window. It responds 204 or an error; do not log nonce/body. This is a report from the Shortcut, not cryptographic attestation of iOS state. No Safari x-success JSON is assumed.

Begin Shortcut must report `previous_focus_active` if Get Current Focus was nonempty before setting. Only `observed_focus:"iCTRL Automation"` after explicit Set Focus On Until Date permits `quiet_verified`. If End starts while Begin is still pending, revoke UI immediately and serialize/observe Shortcut completion before conditional cleanup; a stale Begin callback must never reauthorize UI. If Begin is still running or its callback was lost, an End callback reporting `off` does not prove Begin will not later set Focus On. Keep takeover in `restoration_pending` until the old invocation can be confirmed complete or the finite system deadline has passed and current Focus is actually rechecked. Never automatically replay Begin and do not assume a cancellation API. The absolute Focus deadline is the final fallback if Begin finishes after an early cleanup inspection. Any timeout, cancel, error, mismatch or unavailable action fails closed. End Shortcut rechecks Get Current Focus and sets Off only when still exactly `iCTRL Automation`; otherwise it reports `preserved_user_focus`. Do not Toggle or restore a prior name. Begin's system absolute Focus deadline is a crash fallback; background scheduling is not guaranteed to the second. User off/on of the same named Focus (ABA) cannot be detected reliably in v1, so exact preservation of user changes is not guaranteed. Physical touch pause has no reliable signal and is out of scope.

## Shortcut steps (human authored and reviewed)

### iCTRL Quiet Begin

1. Receive text input. Parse only `action=begin`, 43-char nonce, UTC absolute deadline and callback URL for exact fixed loopback route. Reject invalid/expired input. Do not use clipboard.
2. Get Current Focus. If any Focus is active, POST `{nonce, action:"begin", observed_focus:"previous_focus_active", deadline}` and Stop.
3. Set Focus `iCTRL Automation` On Until Date = input deadline. Never Toggle.
4. Get Current Focus again. POST exact observed name or `unavailable` with same nonce/action/deadline. Stop. Do not launch target app or tap.

### iCTRL Quiet Inspect/End

1. Receive and validate `action=end`, nonce, deadline and exact callback route.
2. Get Current Focus. If exactly `iCTRL Automation`, Set Focus `iCTRL Automation` Off, then Get Current Focus again; POST `off` only if empty, otherwise `preserved_user_focus`.
3. If current Focus differs, do not set anything; POST `preserved_user_focus`.

The actual Shortcuts actions, callback networking, lock-screen behavior, Focus configuration, and real message-banner suppression require phone validation before enabling. Focus may allow critical/emergency/system notifications even when configured to silence ordinary messages.
