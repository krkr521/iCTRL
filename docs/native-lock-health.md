# Recoverable lock health and audited native admission

This is a source fix for a demonstrated state-machine defect, not a claim that it
was the only cause of the observed build13 device admission failure. Previously,
one `notify_get_state` failure latched `monitorAvailable = false` forever while later
notifications could set cached `isLocked = false`. Capabilities separately retained
a startup snapshot. The three observations could therefore disagree legitimately.

## Health and authority

`ICLockHealthState` is the C transition core used by the real Objective-C monitor
and its offline tests. Registration/token validity and whether the current state
is known are separate. Unknown or locked observations advance a monotonic generation.
Transient read failure leaves a valid registration intact and denies admission. A
later successful fresh read on that same registered token may restore known state.
Registration failure or `NOTIFY_STATUS_INVALID_TOKEN` permanently invalidates that
monitor; a convenient successful value cannot restore registration.

The monitor owns one registered token. Callback delivery is suspended on its own
serial queue until registration initialization and the initial fresh read complete.
Callbacks from invalidated tokens are ignored. The notify read, health transition and
snapshot are serialized under the monitor lock; callbacks execute outside that lock.
No retry opens Settings, repairs pairing, unlocks, or silently registers a new monitor.

Every UI lease captures its admission health generation. Unknown/locked reads revoke
older generations. A later successful read only permits a new explicit Begin with a
new lease ID; gates and keep-awake source checks reject an older epoch. A delayed
invalidation callback revokes only older generations, not a new recovered Begin.
A delayed per-request failure revokes only its own lease ID. Begin refreshes again
after construction so a read failure between its first check and creation cannot
publish a usable stale lease. Event injection that has already begun is not cancellable.

The monitor lock is never held while acquiring the native session lock. The server
lifecycle lock orders listener ready/failed/cancelled callbacks with explicit stop;
its order is lifecycle -> service authorization, with no reverse acquisition. UI
source reads release the service-authorization lock before touching monitor health.
The monitor callback only revokes native leases and never calls back into the monitor.
A stopped service's queued scheduler callback and late listener-ready callback are
both invalidated synchronously.

F13/XCTest ABI availability is inspected on main once before HTTP starts, then cached
as a runtime capability. Dynamic HTTP readiness only refreshes the registered Darwin
notification token; it does not reflect on XCUIDevice from a background queue or
wait for the main thread. Actual F13 submission still checks its ABI and fresh lock
state on main; failure pauses that service source and revokes task authority.

## Diagnostics

Capabilities now refresh and expose `lock_monitor_registered`, `lock_state_known`,
`locked`, `interruption_guard_available`, `f13_abi_available`, `device_ready`,
`admission_reason`, `legacy_recovery_required` and the separate service pulse state.
No other owner identity, lease secret, private token, UI content or file path is returned.
`available` is current health plus service pulse readiness, not a stale startup flag.

Begin rejections are fixed values: `native_interruption_guard_unavailable`,
`native_f13_abi_unavailable`, `native_lock_monitor_unregistered`,
`native_lock_state_unknown`, `native_device_locked`, `native_service_not_running`,
`native_service_keep_awake_event_failed`, `native_automation_owner_required`,
`native_legacy_recovery_required`, `native_invalid_ttl` or
`native_lock_generation_changed`, `native_session_busy` or `native_session_invalid`.
Service revocation during admission may also report `native_service_keep_awake_unavailable`.
Legacy recovery remains required without revealing
which other owner has the old lease. Wrong-owner or wrong-session requests are rejected by the shared NativeControlAdmission
policy before health/mode side effects and cannot revoke another valid owner lease.
Persistent mode is checked for the captured active owner, not a manual requester.
Existing owner/TTL/heartbeat gates remain required.

## Verification boundary

`Scripts/test-lock-health.c` compiles the same C core that the Objective-C monitor
calls; it tests healthy -> read failure -> fresh recovery, locked, invalid token,
registration failure and epoch overflow. Swift tests additionally combine that core
with actual `NativeAutomationSession` transitions, delayed invalidation and stale
queued source checks. MSVC execution proves this portable C transition logic only.
Swift/Foundation tests, Objective-C notification integration and the signed iOS app
still require macOS CI. Physical lock/read recovery and service behavior require
explicit device acceptance. No state, pairing, private runtime or phone was changed
while authoring this source candidate.
