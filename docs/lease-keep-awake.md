# Lease-scoped F13 keep-awake

This implementation does not read or change Settings Auto-Lock, brightness, Focus,
or the foreground application. It never unlocks the phone or presses a wake button.

## Contract

`LeaseKeepAwake` runs on the runner's existing serial `rpcQueue`. The server supplies
`LeaseKeepAwakePolicy.Lease(id:deadline:)` only for an active, authenticated automation
owner/session, within its monotonic absolute TTL and authenticated heartbeat window.
Preparing, failed, manual, suspended, expired, ending and ended sessions return nil.
A snapshot is not authority to begin a lease; it is a read-only view of server admission.
Do not infer disconnect from an individual short-lived HTTP request closing. Server
shutdown, authenticated owner revocation, heartbeat expiry or task termination must
revoke the snapshot. Clients must use finally/end on normal and exceptional exits;
an ungraceful loss is bounded by the server heartbeat deadline.

Construct once per server with the existing serial UI queue:

```swift
leaseKeepAwake = LeaseKeepAwake(
    queue: rpcQueue,
    snapshot: { [weak srv] in srv?.nativeKeepAwakeLease() },
    isLocked: { ICIdlePulse.isLockedOrUnknown() },
    pulse: { ICIdlePulse.sendF13() },
    log: { Self.logBuffer.append($0) })
leaseKeepAwake?.start()
```

Call `stop()` before server replacement/shutdown and release the instance. Stop
invalidates queued callbacks synchronously. A private XCTest event already entered
cannot be recalled. Never call start/stop from a separate unowned task or expose an
unauthenticated pulse RPC. Keep capability `keep_awake: "f13_lease"` and interval 10
separate from claims that device behavior has been verified.

The scheduler polls at 1 second, admits the first event immediately and subsequent
events no more often than 10 seconds, and skips missed intervals rather than replaying
a backlog. Before injection it rechecks generation, exact snapshot, TTL and a fresh
lock notification state on the same main-thread lane used for UI actions. The event
bridge queries lock state again. Unknown lock state fails closed. Observed lock or
pulse failure blocks that lease ID permanently, including after manual unlock. A new
explicitly authorized lease is required. No repeated wake attempts occur. First event
acceptance and lease/lock/error stops produce content-free runner log messages.

## Source and API evidence

Reviewed https://github.com/leeguooooo/iphone-use at revision `18b3e199958754b0c89c1b226cfcb2111e5b6e1a`. Its
`runner/IPhoneUseRunner/IPhoneUseRunnerUITests/IPURBridge.m` resetIdleTimer uses keyboard
page 0x07 and usage 0x68 (F13), and its author reports an iPhone 13/iOS 27 experiment
with ten-second pulses. That report is not an iCTRL device test.

The current upstream LICENSE/LICENSING.md offers PolyForm Shield 1.0.0, including a
competition restriction. No upstream implementation or documentation text is copied
into iCTRL. This bridge and policy are independently written from the observed API
mechanism, with no upstream dependencies.

Apple documents the F13 key constant:
https://developer.apple.com/documentation/xcuiautomation/xcuikeyboardkey/f13
Apple's public key constant does not establish that `XCDeviceEvent` or
`performDeviceEvent:error:` is supported on iOS, or that a key refreshes cross-app
idle time. `ICIdlePulse.isAvailable()` only inspects both selectors and runtime ABI signatures;
it neither creates nor submits a device event. Capabilities must require it. The
bridge rechecks the exact ABI before injection, catches Objective-C
exceptions and fails closed. It does not fall back to touches, Settings, or brightness.

## Validation boundary

Foundation tests cover cadence, no catch-up, lock latching, event failure, revocation,
stop, invalid/regressed monotonic clocks, expiry and stale owner/lease snapshots.
Windows source checks do not compile XCTest and do not prove iPhone behavior. Run
`swift test --filter LeaseKeepAwakeTests` on the supported macOS build host, then the
normal signed iOS build, before installation.

Authorized real-device acceptance is still required: Auto-Lock at 30 seconds held
off through several intervals, software keyboard/text unchanged, UI actions serialized,
manual lock stays locked, unknown lock state and unavailable private selectors stop,
TTL/end/disconnect/heartbeat loss stop pulses, and old leases cannot restart. Verify
that Auto-Lock resumes normally afterward without changing its setting. Existing
Auto-Lock/Quiet pending recovery records must remain untouched by this feature.
