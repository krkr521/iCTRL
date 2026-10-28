import XCTest
@testable import NativePolicy

final class QuietManualInspectionTests: XCTestCase {
    private func pendingControl() throws -> QuietControl {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        try control.register(owner: "web", mode: "manual", now: 100)
        _ = try control.begin(owner: "agent", ttl: 60, now: 100,
                              date: Date(timeIntervalSince1970: 1_800_000_000))
        let end = try XCTUnwrap(control.takeover(now: 101))
        let components = try XCTUnwrap(URLComponents(url: end.url, resolvingAgainstBaseURL: false))
        let text = try XCTUnwrap(components.queryItems?.first(where: { $0.name == "text" })?.value)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        let body = try JSONSerialization.data(withJSONObject: [
            "nonce": try XCTUnwrap(input["nonce"]), "action": "end", "observed_focus": "off",
            "deadline": try XCTUnwrap(input["deadline"]),
        ])
        let report = try QuietCallback.parse(method: "POST", path: "/quiet-callback",
            contentType: "application/json", headerBytes: 100, body: body)
        XCTAssertTrue(control.callback(report, now: 102))
        let restore = try XCTUnwrap(control.restorationForAcceptedCallback(report, now: 102))
        XCTAssertTrue(control.finishRestoration(restore, succeeded: true, diagnostic: nil, now: 102))
        XCTAssertEqual(control.takeoverState(now: 102), "restoration_pending")
        return control
    }

    func testRelativeWaitMatchesOriginalAdmissionBoundary() throws {
        let control = try pendingControl()
        let before = control.manualInspectionAvailability(owner: "web", now: 459.1)
        XCTAssertFalse(before.ready)
        XCTAssertEqual(before.waitSeconds, 1)
        XCTAssertThrowsError(try control.inspectForManual(owner: "web", now: 459.9))
        let ready = control.manualInspectionAvailability(owner: "web", now: 460)
        XCTAssertTrue(ready.ready)
        XCTAssertEqual(ready.waitSeconds, 0)
        _ = try control.inspectForManual(owner: "web", now: 460)
        let pending = control.manualInspectionAvailability(owner: "web", now: 460.1)
        XCTAssertFalse(pending.ready)
        XCTAssertNil(pending.waitSeconds)
    }

    func testOnlyRegisteredManualClientReceivesAvailability() throws {
        let control = try pendingControl()
        for owner in ["agent", "unregistered"] {
            let result = control.manualInspectionAvailability(owner: owner, now: 460)
            XCTAssertFalse(result.ready)
            XCTAssertNil(result.waitSeconds)
        }
    }

    func testInvalidClockAndNoLeaseFailClosed() throws {
        let control = try pendingControl()
        for now in [Double.nan, Double.infinity, -Double.infinity] {
            let result = control.manualInspectionAvailability(owner: "web", now: now)
            XCTAssertFalse(result.ready)
            XCTAssertNil(result.waitSeconds)
        }
        let empty = QuietControl(enabled: true, port: 8200)
        try empty.register(owner: "web", mode: "manual", now: 100)
        XCTAssertFalse(empty.manualInspectionAvailability(owner: "web", now: 100).ready)
    }
}
