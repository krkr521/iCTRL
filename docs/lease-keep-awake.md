# F13 keep-awake scope

Build12/13 scoped F13 to an active automation lease. Build14 changes the scope at
explicit user request: a user-started Runner service keeps awake while waiting for
connections and between tasks. `automation_native_end`, absolute task TTL and a
lost heartbeat revoke UI control, but do not stop the service's F13 scheduler.

One serial scheduler targets ten-second intervals, at most one event per interval.
Long UI work or a blocked main thread may defer pulses; this is not a hard real-time
guarantee and Auto-Lock may still fire during a prolonged UI stall. A service-source
contains the current listener-start epoch and lock-health generation, not a client
owner or task lease. No client connection/heartbeat is necessary for the pulse.
The scheduler and UI actions share the existing serial RPC queue and main lane;
missed intervals are skipped, never caught up. The source and a fresh lock reading
are rechecked immediately before the event. A stop invalidates the service epoch
synchronously, and stale listener-ready callbacks cannot restart it. A main-thread
private event already entered cannot be recalled.

Manual lock or unknown state prevents F13. Active UI leases are revoked by health
generation. After the user unlocks, a successful read through the still-valid
registered monitor can authorize a new service source. It cannot revive any old
UI lease; a new explicit Begin is required for input. No wake button, unlock,
brightness, Auto-Lock setting or Focus change is used. Stopping the service releases
the foreground UIKit assertion too, so the system's existing Auto-Lock interval
applies normally. No new fixed interval is written to Settings.

`automation_native_capabilities` reports `keep_awake: "f13_service"`,
`keep_awake_scope: "runner_service"`, interval 10, and `ui_control_scope: "owner_lease"`.
`runtime_status` separately reports `service_keep_awake_running`,
`service_keep_awake_state` and `native_control_lease_active`. The old foreground
UIKit idle-assertion fields describe only the app-scoped UIKit feature; they are
not evidence of F13 effectiveness or task authority. An event success is not proof
that physical Auto-Lock was held off; that remains a device acceptance criterion.

The independent implementation uses private XCTest device-event selectors, guarded
by ABI introspection before the listener starts and before events on main. Apple
publicly documents F13, not a cross-app idle-reset guarantee. Mechanism reference:
https://github.com/leeguooooo/iphone-use/blob/18b3e199958754b0c89c1b226cfcb2111e5b6e1a/runner/IPhoneUseRunner/IPhoneUseRunnerUITests/IPURBridge.m#L1667-L1683
The reference revision is PolyForm Shield; no upstream source was copied.
https://developer.apple.com/documentation/xcuiautomation/xcuikeyboardkey/f13

Foundation tests exercise no-client waiting, task End/heartbeat expiry with continued
service pulses and denied old UI, manual lock/unlock, stale queued source rejection,
stop and late listener callbacks, cadence, unknown states and event failure latching.
These tests do not substitute for iOS compilation and physical device verification.
