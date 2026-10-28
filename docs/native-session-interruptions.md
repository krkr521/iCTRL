# Native session and interruption boundaries (2026-10-28)

The native backend changes no Focus, Shortcuts, Auto-Lock, or shared device settings. It does not suppress notifications. It replaces daily Quiet setup with a process-local owner lease. Existing Quiet callbacks, conditional restoration, persisted token modes, and client recovery records remain independent and must be recovered before starting this backend.

## Evidence

- Apple WWDC20 Handle interruptions and alerts in UI tests: https://developer.apple.com/videos/play/wwdc2020/10220/
- Current Apple API guidance: https://developer.apple.com/documentation/xctest/handling-ui-interruptions
- Current Apple monitor reference: https://developer.apple.com/documentation/xctest/xctestcase/adduiinterruptionmonitor(withdescription:handler:)
- Primary implementation evidence: https://github.com/appium/WebDriverAgent/blob/master/WebDriverAgentLib/Categories/XCUIApplication%2BFBUIInterruptions.m (single getter replacement).
- Private header signature evidence: https://github.com/appium/WebDriverAgent/blob/master/PrivateHeaders/XCTest/XCUIApplication.h (`@property (nonatomic) _Bool doesNotHandleUIInterruptions`, SDK 26.4 in currently fetched header).

Apple defines interruptions relative to the specific element being interacted with. A banner not covering that target is not an interruption. Expected alerts should be tested via explicit queries, not a monitor. Returning false falls through to the next monitor, including XCTest implicit cancel/default handling. Consequently this implementation does not register a monitor that falsely promises safe blocking. It narrowly disables implicit handling using the exact existing WebDriverAgent getter; missing selector or unexpected method argument/return signature reports native unavailable. No class inventory, selector discovery, alert allowlist, first-button, cancel/default, or permission auto-grant is used.

## Contract

Authenticated automation tokens use `automation_native_capabilities`, `automation_native_begin{ttl_seconds}`, `automation_native_status{lease_id}`, `automation_native_heartbeat{lease_id}`, `automation_native_end{lease_id}`. UI uses existing `automation_session`. Begin returns backend native, mode automation, active, lease_id, ISO8601 UTC absolute deadline, heartbeat_interval_seconds 5, notification_suppression false. Absolute TTL is 1..300 seconds; heartbeat silence for 15 seconds irrevocably expires the lease. Status does not renew. Owner checks run at receipt and again before queued UI. End is idempotent. Process restart loses this lease; no system setting needs native restoration. Manual takeover revokes native authorization. Legacy active/uncertain Quiet sessions block native begin; native active blocks legacy begin. Client-side old Quiet/Auto-Lock pending restoration must also complete before native begin.

Runner startup installs the fixed getter guard in setUpWithError, and configureServerCallbacks copies actual availability to each new server. Unsupported runtimes cannot begin native sessions. F13 is a separate implementation lane; integration must only report available after that scheduler is wired and its runtime mechanism is supported. `nativeKeepAwakeLease()` gives an active heartbeat-checked snapshot; map its id and min(deadline, heartbeat) to the scheduler. A new network HTTP request per RPC is normal, so disconnect is defined by the authenticated heartbeat timeout, not closure of any one HTTP connection.

In native UI dispatch, a detected SpringBoard system alert refuses mutation with -32041 and mutation_started false. Only a freshly discovered (under 15 seconds) explicit SpringBoard tap ref matching the current alert title can address an alert. Existing ordinary, explicitly targeted app alert interactions remain available. A human or agent must stay within the already authorized task when choosing a permission, payment, or account response; no new approval flow is introduced.

## Limits and validation

This is interruption-aware local automation, not Focus. It cannot stop arrival or sound of banners, calls, alarms, or all overlays. Detection happens before dispatch and can race with UI changes between inspection and event injection, particularly coordinate actions. The getter prevents XCTest implicit cancel/default behavior on the supported implementation; no real-device proof for this OS has been obtained. Unknown modal states may surface ordinary XCTest failure rather than -32041; no automatic action/retry follows. Two different alerts sharing a title are not a cryptographic identity and the fresh-ref check reduces, not eliminates, UI races.

Foundation XCTest cases cover owner isolation, no lease-id bypass, exclusivity, heartbeat expiry/no revival, TTL, invalid clocks/ranges, ISO8601 deadline, end idempotency, and revocation. Windows has no Swift compiler, so this lane adds but cannot execute these tests. `git diff --check` and a local source-contract verification were executed. macOS Foundation tests, Xcode Runner compilation, real notification/permission/call/alarm scenarios, F13 device behavior, and final recovery of historic pending state remain integration/device validation.


## Lock notification follow-up

Cross-review found that polling only on the UI queue could miss a short manual lock/unlock while that queue is blocked. LockStateMonitor now exposes monitorAvailable and an onLocked callback dispatched independently of UI work. All stored BOOL/block reads and writes are synchronized; callbacks are copied under the monitor lock and invoked after releasing it, so revocation never waits while holding that lock. Startup reads actual notification state and defaults to locked/unknown on failure. Existing lock/unlock actions retain their commands and timeout flow. Integration must require monitorAvailable in capabilities/admission, wire onLocked to native lease revocation, and clear/replace callback on Runner lifecycle changes. Unlock never invokes the callback or revives a lease. OS notification coalescing/delivery and event injection races still prevent an absolute real-time lock guarantee. This Objective-C path requires Xcode compilation and device validation; Windows source checks cannot prove callback delivery.

Client lost-Begin handling is deliberately fail-closed: owner status is observed once but never establishes ownership of this particular request. The client sends no heartbeat, input or End for an unproven lease; it reports unknown and waits for the server heartbeat bound. A prior owner read does not exclude concurrent clients sharing one token. No automatic Begin retry or lease adoption is permitted.
