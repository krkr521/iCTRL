import XCTest
@testable import NativePolicy

final class QuietControlTests: XCTestCase {
    private func callback(from launch: QuietControl.Launch, action: String, focus: String) throws -> QuietCallback {
        let url = try XCTUnwrap(URLComponents(url: launch.url, resolvingAgainstBaseURL: false))
        let text = try XCTUnwrap(url.queryItems?.first(where: { $0.name == "text" })?.value)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        let nonce = try XCTUnwrap(input["nonce"]), deadline = try XCTUnwrap(input["deadline"])
        let body = try JSONSerialization.data(withJSONObject: ["nonce": nonce, "action": action,
                                                            "observed_focus": focus, "deadline": deadline])
        return try QuietCallback.parse(method: "POST", path: "/quiet-callback", contentType: "Application/JSON; charset=UTF-8", headerBytes: 100, body: body)
    }

    @discardableResult private func acceptAndRestore(_ control: QuietControl, launch: QuietControl.Launch,
                                                       focus: String, now: TimeInterval) throws -> Bool {
        let report = try callback(from: launch, action: launch.action, focus: focus)
        guard control.callback(report, now: now),
              let restore = control.restorationForAcceptedCallback(report, now: now) else { return false }
        return control.finishRestoration(restore, succeeded: true, diagnostic: nil, now: now + 0.1)
    }

    func testDisabledAndVerifiedGate() throws {
        let disabled = QuietControl(enabled: false, port: 8200)
        XCTAssertEqual(try disabled.register(owner: "agent", mode: "automation", now: 100), "automation")
        XCTAssertThrowsError(try disabled.begin(owner: "agent", ttl: 60, now: 100, date: Date()))
        XCTAssertNotNil(disabled.gate(owner: "agent", method: "tap", session: nil, now: 100))
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        try control.register(owner: "web", mode: "manual", now: 100)
        let launch = try control.begin(owner: "agent", ttl: 60, now: 100, date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: launch.leaseID, now: 101))
        XCTAssertNotNil(control.gate(owner: "web", method: "tap", session: nil, now: 101))
        XCTAssertTrue(try acceptAndRestore(control, launch: launch, focus: "iCTRL Automation", now: 102))
        XCTAssertNil(control.gate(owner: "agent", method: "tap", session: launch.leaseID, now: 103))
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: nil, now: 103))
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: "old", now: 103))
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: launch.leaseID, now: 160))
    }

    func testExistingFocusFailsAndCleanupIsBounded() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        let launch = try control.begin(owner: "agent", ttl: 10, now: 100, date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(try acceptAndRestore(control, launch: launch, focus: "previous_focus_active", now: 101))
        XCTAssertEqual(control.status(owner: "agent", requestedID: launch.leaseID, now: 101)["state"], "failed")
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: launch.leaseID, now: 102))
        let end = try XCTUnwrap(control.end(owner: "agent", id: launch.leaseID, now: 111))
        XCTAssertNil(try control.end(owner: "agent", id: launch.leaseID, now: 111))
        XCTAssertTrue(try acceptAndRestore(control, launch: end, focus: "preserved_user_focus", now: 112))
        XCTAssertEqual(control.takeoverState(now: 112), "manual_ready")
    }

    func testUncertainEarlyEndCannotReleaseManual() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        try control.register(owner: "web", mode: "manual", now: 100)
        let launch = try control.begin(owner: "agent", ttl: 60, now: 100, date: Date(timeIntervalSince1970: 1_800_000_000))
        let end = try XCTUnwrap(control.takeover(now: 101))
        XCTAssertFalse(control.callback(try callback(from: launch, action: "begin", focus: "iCTRL Automation"), now: 102))
        XCTAssertTrue(try acceptAndRestore(control, launch: end, focus: "off", now: 103))
        XCTAssertEqual(control.takeoverState(now: 103), "restoration_pending")
        XCTAssertNotNil(control.gate(owner: "web", method: "tap", session: nil, now: 103))
        XCTAssertThrowsError(try control.inspectForManual(owner: "web", now: 459))
        let inspect = try control.inspectForManual(owner: "web", now: 460)
        XCTAssertFalse(control.callback(try callback(from: launch, action: "begin", focus: "iCTRL Automation"), now: 461))
        XCTAssertNotNil(control.gate(owner: "web", method: "tap", session: nil, now: 461))
        XCTAssertTrue(try acceptAndRestore(control, launch: inspect, focus: "off", now: 462))
        XCTAssertEqual(control.takeoverState(now: 462), "manual_ready")
        XCTAssertNil(control.gate(owner: "web", method: "tap", session: nil, now: 463))
    }

    func testLostBeginAndEndCallbacksRecoverOnlyAfterFreshInspection() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        try control.register(owner: "web", mode: "manual", now: 100)
        let begin = try control.begin(owner: "agent", ttl: 10, now: 100, date: Date(timeIntervalSince1970: 1_800_000_000))
        let end = try XCTUnwrap(control.takeover(now: 101))
        XCTAssertEqual(control.takeoverState(now: 132), "restoration_pending")
        XCTAssertFalse(control.callback(try callback(from: end, action: "end", focus: "off"), now: 133))
        XCTAssertThrowsError(try control.inspectForManual(owner: "web", now: 409))
        let first = try control.inspectForManual(owner: "web", now: 410)
        XCTAssertThrowsError(try control.inspectForManual(owner: "web", now: 411))
        XCTAssertTrue(try acceptAndRestore(control, launch: first, focus: "iCTRL Automation", now: 412))
        XCTAssertNotNil(control.gate(owner: "web", method: "tap", session: nil, now: 413))
        let second = try control.inspectForManual(owner: "web", now: 414)
        XCTAssertFalse(control.callback(try callback(from: first, action: "inspect", focus: "off"), now: 415))
        XCTAssertTrue(try acceptAndRestore(control, launch: second, focus: "preserved_user_focus", now: 416))
        XCTAssertEqual(control.takeoverState(now: 416), "manual_ready")
        XCTAssertNil(control.gate(owner: "web", method: "tap", session: nil, now: 417))
        XCTAssertFalse(control.callback(try callback(from: begin, action: "begin", focus: "iCTRL Automation"), now: 418))
    }

    func testEarlyCallbackWaitsForConfirmedForegroundAndFailureStaysBlocked() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        try control.register(owner: "web", mode: "manual", now: 100)
        let begin = try control.begin(owner: "agent", ttl: 60, now: 100, date: Date(timeIntervalSince1970: 1_800_000_000))
        let report = try callback(from: begin, action: "begin", focus: "iCTRL Automation")
        XCTAssertTrue(control.callback(report, now: 101))
        XCTAssertEqual(control.status(owner: "agent", requestedID: begin.leaseID, now: 101)["state"], "restoring")
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: begin.leaseID, now: 102))
        XCTAssertNotNil(control.gate(owner: "web", method: "tap", session: nil, now: 102))
        let restore = try XCTUnwrap(control.restorationForAcceptedCallback(report, now: 102))
        XCTAssertTrue(control.finishRestoration(restore, succeeded: false,
                                                diagnostic: "foreground_restore_unconfirmed", now: 103))
        XCTAssertEqual(control.status(owner: "agent", requestedID: begin.leaseID, now: 103)["state"], "restoration_pending")
        XCTAssertEqual(control.status(owner: "agent", requestedID: begin.leaseID, now: 103)["context_diagnostic"], "foreground_restore_unconfirmed")
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: begin.leaseID, now: 104))
        XCTAssertFalse(control.finishRestoration(restore, succeeded: true, diagnostic: nil, now: 105))
    }

    func testExpiredOrSupersededRestoreCannotReleaseOldUI() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        try control.register(owner: "web", mode: "manual", now: 100)
        let begin = try control.begin(owner: "agent", ttl: 10, now: 100, date: Date(timeIntervalSince1970: 1_800_000_000))
        let report = try callback(from: begin, action: "begin", focus: "iCTRL Automation")
        XCTAssertTrue(control.callback(report, now: 101))
        let restore = try XCTUnwrap(control.restorationForAcceptedCallback(report, now: 101))
        XCTAssertFalse(control.mayRestore(restore, now: 110))
        XCTAssertFalse(control.finishRestoration(restore, succeeded: true, diagnostic: nil, now: 110))
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: begin.leaseID, now: 110))
        let end = try XCTUnwrap(control.takeover(now: 111))
        XCTAssertFalse(control.mayRestore(restore, now: 111))
        XCTAssertFalse(control.finishRestoration(restore, succeeded: true, diagnostic: nil, now: 111))
        XCTAssertTrue(try acceptAndRestore(control, launch: end, focus: "off", now: 112))
        XCTAssertEqual(control.takeoverState(now: 112), "restoration_pending")
    }

    func testEndCallbackCannotReleaseManualBeforeForegroundRestored() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        try control.register(owner: "web", mode: "manual", now: 100)
        let begin = try control.begin(owner: "agent", ttl: 60, now: 100, date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(try acceptAndRestore(control, launch: begin, focus: "iCTRL Automation", now: 101))
        let end = try XCTUnwrap(control.takeover(now: 102))
        let report = try callback(from: end, action: "end", focus: "off")
        XCTAssertTrue(control.callback(report, now: 103))
        XCTAssertEqual(control.takeoverState(now: 103), "restoring")
        XCTAssertNil(try control.end(owner: "agent", id: begin.leaseID, now: 103))
        XCTAssertNotNil(control.gate(owner: "web", method: "tap", session: nil, now: 103))
        let restore = try XCTUnwrap(control.restorationForAcceptedCallback(report, now: 103))
        XCTAssertTrue(control.finishRestoration(restore, succeeded: true, diagnostic: nil, now: 104))
        XCTAssertEqual(control.takeoverState(now: 104), "manual_ready")
        XCTAssertNil(control.gate(owner: "web", method: "tap", session: nil, now: 104))
    }

    func testRestoreQueueTimeoutLeavesManualBlocked() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        try control.register(owner: "web", mode: "manual", now: 100)
        let begin = try control.begin(owner: "agent", ttl: 60, now: 100, date: Date(timeIntervalSince1970: 1_800_000_000))
        let report = try callback(from: begin, action: "begin", focus: "iCTRL Automation")
        XCTAssertTrue(control.callback(report, now: 101))
        let restore = try XCTUnwrap(control.restorationForAcceptedCallback(report, now: 101))
        XCTAssertEqual(control.takeoverState(now: 109), "restoration_pending")
        XCTAssertEqual(control.takeoverDiagnostic(now: 109), "foreground_restore_timeout")
        XCTAssertFalse(control.finishRestoration(restore, succeeded: true, diagnostic: nil, now: 110))
        XCTAssertNotNil(control.gate(owner: "web", method: "tap", session: nil, now: 110))
    }

    func testKnownNoLaunchReleasesManualWithoutVerifyingBegin() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        try control.register(owner: "web", mode: "manual", now: 100)
        let begin = try control.begin(owner: "agent", ttl: 60, now: 100, date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(control.abortBeforeLaunch(begin, diagnostic: "foreground_before_helper_unknown", now: 101))
        XCTAssertEqual(control.status(owner: "agent", requestedID: begin.leaseID, now: 101)["state"], "ended")
        XCTAssertEqual(control.status(owner: "agent", requestedID: begin.leaseID, now: 101)["context_diagnostic"], "foreground_before_helper_unknown")
        XCTAssertEqual(control.takeoverState(now: 101), "manual_ready")
        XCTAssertNil(control.gate(owner: "web", method: "tap", session: nil, now: 101))
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: begin.leaseID, now: 101))
        XCTAssertFalse(control.callback(try callback(from: begin, action: "begin", focus: "iCTRL Automation"), now: 102))
        XCTAssertFalse(control.abortBeforeLaunch(begin, diagnostic: "again", now: 103))
        let late = try control.begin(owner: "agent", ttl: 1, now: 104, date: Date(timeIntervalSince1970: 1_800_000_100))
        XCTAssertFalse(control.mayLaunch(late, now: 106))
        XCTAssertTrue(control.abortBeforeLaunch(late, diagnostic: "helper_not_launched_before_deadline", now: 106))
        XCTAssertEqual(control.takeoverState(now: 106), "manual_ready")
    }

    func testAttemptedLaunchCannotUseSafeNoLaunchExit() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        try control.register(owner: "web", mode: "manual", now: 100)
        let begin = try control.begin(owner: "agent", ttl: 60, now: 100, date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(control.markLaunchAttempted(begin, now: 101))
        XCTAssertFalse(control.abortBeforeLaunch(begin, diagnostic: "no_launch", now: 102))
        control.failLaunch(begin, diagnostic: "shortcut_launch_failed", now: 102)
        XCTAssertEqual(control.takeoverState(now: 102), "restoration_pending")
        XCTAssertNotNil(control.gate(owner: "web", method: "tap", session: nil, now: 102))
        XCTAssertFalse(control.callback(try callback(from: begin, action: "begin", focus: "iCTRL Automation"), now: 103))
    }

    func testModePersistsAndCannotDowngradeOnRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QuietModeStore(url: directory.appendingPathComponent("quiet_control.json"))
        let first = QuietControl(enabled: false, port: 8200, store: store)
        XCTAssertEqual(try first.register(owner: "agent", mode: "automation", now: 100), "automation")
        XCTAssertTrue(try first.configure(enabled: true, now: 100))
        let second = QuietControl(enabled: false, port: 8200, store: store)
        XCTAssertEqual(second.mode(owner: "agent"), "automation")
        XCTAssertNotNil(second.gate(owner: "agent", method: "tap", session: nil, now: 101))
        XCTAssertThrowsError(try second.register(owner: "agent", mode: "manual", now: 101))
        XCTAssertTrue(second.isAvailable)
        try FileManager.default.removeItem(at: store.url)
        let missing = QuietControl(enabled: false, port: 8200, store: store)
        XCTAssertEqual(missing.storageState, "storage_failed")
        XCTAssertNotNil(missing.gate(owner: "agent", method: "tap", session: nil, now: 102))
    }

    func testCorruptModeStoreFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quiet_control.json")
        try Data("bad json".utf8).write(to: url)
        let control = QuietControl(enabled: false, port: 8200, store: QuietModeStore(url: url))
        XCTAssertEqual(control.storageState, "storage_failed")
        XCTAssertNotNil(control.gate(owner: "old-agent", method: "tap", session: nil, now: 100))
        XCTAssertThrowsError(try control.register(owner: "old-agent", mode: "manual", now: 100))
    }
}
