import XCTest
@testable import QuietLeasePrototype

final class QuietLeaseTests: XCTestCase {
    let nonce = String(repeating: "A", count: 43)
    func testOnlyVerifiedSessionRuns() throws {
        var l = try QuietLease(ownerTokId: "transport", id: "fresh-id", ttl: 60, now: 100)
        XCTAssertEqual(l.gate(tokId: "transport", session: "fresh-id", now: 100), .denied("preparing"))
        try l.prepareCallback(nonce: nonce, action: "begin", expectedDeadline: "D", now: 100)
        XCTAssertFalse(l.callback(nonce: "wrong", action: "begin", observed: "iCTRL Automation", reportedDeadline: "D", now: 101))
        XCTAssertFalse(l.callback(nonce: nonce, action: "begin", observed: "iCTRL Automation", reportedDeadline: "other", now: 101))
        XCTAssertTrue(l.callback(nonce: nonce, action: "begin", observed: "iCTRL Automation", reportedDeadline: "D", now: 101))
        XCTAssertFalse(l.callback(nonce: nonce, action: "begin", observed: "iCTRL Automation", reportedDeadline: "D", now: 102))
        XCTAssertEqual(l.gate(tokId: "transport", session: "fresh-id", now: 102), .allowed)
        XCTAssertEqual(l.gate(tokId: "transport", session: "old-id", now: 102), .denied("wrong_session"))
        XCTAssertEqual(l.gate(tokId: "transport", session: "fresh-id", now: 160), .denied("expired"))
    }
    func testNegativeAndExpiredCallback() throws {
        var l = try QuietLease(ownerTokId: "t", id: "s", ttl: 60, now: 100)
        try l.prepareCallback(nonce: nonce, action: "begin", expectedDeadline: "D", now: 100)
        XCTAssertFalse(l.callback(nonce: nonce, action: "begin", observed: "iCTRL Automation", reportedDeadline: "D", now: 131))
        l.failPending(now: 131)
        XCTAssertEqual(l.gate(tokId: "t", session: "s", now: 132), .denied("failed"))
        var l2 = try QuietLease(ownerTokId: "t", id: "s2", ttl: 60, now: 100)
        try l2.prepareCallback(nonce: nonce, action: "begin", expectedDeadline: "D", now: 100)
        XCTAssertTrue(l2.callback(nonce: nonce, action: "begin", observed: "previous_focus_active", reportedDeadline: "D", now: 101))
        XCTAssertEqual(l2.gate(tokId: "t", session: "s2", now: 102), .denied("failed"))
    }
    func testExpiredAndFailedCanStillCleanUpWithoutUI() throws {
        var l = try QuietLease(ownerTokId: "t", id: "s", ttl: 2, now: 100)
        try l.prepareCallback(nonce: nonce, action: "begin", expectedDeadline: "D", now: 100)
        XCTAssertTrue(l.callback(nonce: nonce, action: "begin", observed: "unavailable", reportedDeadline: "D", now: 101))
        XCTAssertTrue(l.end(tokId: "t", session: "s", now: 103))
        XCTAssertFalse(l.end(tokId: "t", session: "s", now: 103))
        XCTAssertEqual(l.gate(tokId: "t", session: "s", now: 103), .denied("ending"))
        let endNonce = String(repeating: "E", count: 43)
        try l.prepareCallback(nonce: endNonce, action: "end", expectedDeadline: "D", now: 103)
        XCTAssertTrue(l.callback(nonce: endNonce, action: "end", observed: "off", reportedDeadline: "D", now: 104))
        XCTAssertEqual(l.gate(tokId: "t", session: "s", now: 104), .denied("ended"))
    }
    func testPendingCannotBeReplacedAndCrossOwnerCannotEnd() throws {
        var l = try QuietLease(ownerTokId: "t", id: "s", ttl: 60, now: 100)
        try l.prepareCallback(nonce: nonce, action: "begin", expectedDeadline: "D", now: 100)
        XCTAssertThrowsError(try l.prepareCallback(nonce: String(repeating: "B", count: 43), action: "begin", expectedDeadline: "D", now: 101))
        XCTAssertFalse(l.end(tokId: "other", session: "s", now: 101))
        XCTAssertFalse(l.end(tokId: "t", session: "old", now: 101))
        XCTAssertTrue(l.callback(nonce: nonce, action: "begin", observed: "iCTRL Automation", reportedDeadline: "D", now: 102))
        XCTAssertTrue(l.end(tokId: "t", session: "s", now: 102))
        XCTAssertFalse(l.end(tokId: "t", session: "s", now: 102))
        XCTAssertThrowsError(try l.prepareCallback(nonce: nonce, action: "end", expectedDeadline: "D", now: 102))
        try l.prepareCallback(nonce: String(repeating: "E", count: 43), action: "end", expectedDeadline: "D", now: 102)
        l.failPending(now: 133)
        XCTAssertEqual(l.gate(tokId: "t", session: "s", now: 133), .denied("restoration_pending"))
    }
    func testWireStateValues() {
        XCTAssertEqual(QuietLease.State.quietVerified.rawValue, "quiet_verified")
        XCTAssertEqual(QuietLease.State.restorationPending.rawValue, "restoration_pending")
        XCTAssertEqual(QuietLease.State.preparing.rawValue, "preparing")
    }
    func testCallbackContentTypeBoundary() throws {
        let body = Data("{\"nonce\":\"\(nonce)\",\"action\":\"begin\",\"observed_focus\":\"iCTRL Automation\",\"deadline\":\"2026-10-26T00:00:00Z\"}".utf8)
        XCTAssertNoThrow(try QuietCallback.parse(method: "POST", path: "/quiet-callback", contentType: "Application/JSON; Charset=\"UTF-8\"", headerBytes: 100, body: body))
        XCTAssertThrowsError(try QuietCallback.parse(method: "POST", path: "/quiet-callback", contentType: "text/json", headerBytes: 100, body: body))
        XCTAssertThrowsError(try QuietCallback.parse(method: "POST", path: "/quiet-callback", contentType: "application/json; charset=latin1", headerBytes: 100, body: body))
        XCTAssertThrowsError(try QuietCallback.parse(method: "POST", path: "/quiet-callback", contentType: "application/json", headerBytes: 4097, body: body))
    }
}
