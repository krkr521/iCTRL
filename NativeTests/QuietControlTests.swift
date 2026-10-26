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
        XCTAssertTrue(control.callback(try callback(from: launch, action: "begin", focus: "iCTRL Automation"), now: 102))
        XCTAssertNil(control.gate(owner: "agent", method: "tap", session: launch.leaseID, now: 103))
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: nil, now: 103))
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: "old", now: 103))
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: launch.leaseID, now: 160))
    }

    func testExistingFocusFailsAndCleanupIsBounded() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        let launch = try control.begin(owner: "agent", ttl: 10, now: 100, date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(control.callback(try callback(from: launch, action: "begin", focus: "previous_focus_active"), now: 101))
        XCTAssertEqual(control.status(owner: "agent", requestedID: launch.leaseID, now: 101)["state"], "failed")
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: launch.leaseID, now: 102))
        let end = try XCTUnwrap(control.end(owner: "agent", id: launch.leaseID, now: 111))
        XCTAssertNil(try control.end(owner: "agent", id: launch.leaseID, now: 111))
        XCTAssertTrue(control.callback(try callback(from: end, action: "end", focus: "preserved_user_focus"), now: 112))
        XCTAssertEqual(control.takeoverState(now: 112), "manual_ready")
    }

    func testUncertainEarlyEndCannotReleaseManual() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        try control.register(owner: "web", mode: "manual", now: 100)
        let launch = try control.begin(owner: "agent", ttl: 60, now: 100, date: Date(timeIntervalSince1970: 1_800_000_000))
        let end = try XCTUnwrap(control.takeover(now: 101))
        XCTAssertFalse(control.callback(try callback(from: launch, action: "begin", focus: "iCTRL Automation"), now: 102))
        XCTAssertTrue(control.callback(try callback(from: end, action: "end", focus: "off"), now: 103))
        XCTAssertEqual(control.takeoverState(now: 103), "restoration_pending")
        XCTAssertNotNil(control.gate(owner: "web", method: "tap", session: nil, now: 103))
        XCTAssertThrowsError(try control.inspectForManual(owner: "web", now: 459))
        let inspect = try control.inspectForManual(owner: "web", now: 460)
        XCTAssertFalse(control.callback(try callback(from: launch, action: "begin", focus: "iCTRL Automation"), now: 461))
        XCTAssertNotNil(control.gate(owner: "web", method: "tap", session: nil, now: 461))
        XCTAssertTrue(control.callback(try callback(from: inspect, action: "inspect", focus: "off"), now: 462))
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
        XCTAssertTrue(control.callback(try callback(from: first, action: "inspect", focus: "iCTRL Automation"), now: 412))
        XCTAssertNotNil(control.gate(owner: "web", method: "tap", session: nil, now: 413))
        let second = try control.inspectForManual(owner: "web", now: 414)
        XCTAssertFalse(control.callback(try callback(from: first, action: "inspect", focus: "off"), now: 415))
        XCTAssertTrue(control.callback(try callback(from: second, action: "inspect", focus: "preserved_user_focus"), now: 416))
        XCTAssertEqual(control.takeoverState(now: 416), "manual_ready")
        XCTAssertNil(control.gate(owner: "web", method: "tap", session: nil, now: 417))
        XCTAssertFalse(control.callback(try callback(from: begin, action: "begin", focus: "iCTRL Automation"), now: 418))
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
