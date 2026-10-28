import XCTest
@testable import NativePolicy

final class NativeAutomationSessionTests: XCTestCase {
    func testOwnershipHeartbeatExpiryAndNoRevival() throws {
        let sessions = NativeAutomationSession()
        _ = try sessions.begin(owner: "agent", id: "lease", ttl: 120, now: 100, date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(sessions.gate(owner: "agent", id: "lease", now: 101))
        XCTAssertFalse(sessions.gate(owner: "other", id: "lease", now: 101))
        XCTAssertFalse(sessions.gate(owner: "agent", id: nil, now: 101))
        XCTAssertNil(sessions.status(owner: "other", now: 101))
        _ = try sessions.heartbeat(owner: "agent", id: "lease", now: 110)
        XCTAssertNotNil(sessions.active(now: 124))
        XCTAssertNil(sessions.active(now: 125))
        XCTAssertThrowsError(try sessions.heartbeat(owner: "agent", id: "lease", now: 126))
        XCTAssertEqual(sessions.status(owner: "agent", now: 126)?["state"], .string("expired"))
    }
    func testAbsoluteTTLAndIdempotentEnd() throws {
        let sessions = NativeAutomationSession()
        let initial = try sessions.begin(owner: "agent", id: "lease", ttl: 20, now: 100, date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(initial["deadline"], .string("1970-01-01T00:00:20Z"))
        XCTAssertEqual(initial["notification_suppression"], .bool(false))
        XCTAssertThrowsError(try sessions.begin(owner: "agent", id: "second", ttl: 20, now: 101, date: Date()))
        _ = try sessions.heartbeat(owner: "agent", id: "lease", now: 110)
        XCTAssertNil(sessions.active(now: 120))
        XCTAssertThrowsError(try sessions.end(owner: "other", id: "lease", now: 120))
        XCTAssertEqual(try sessions.end(owner: "agent", id: "lease", now: 120)["state"], .string("ended"))
        XCTAssertEqual(try sessions.end(owner: "agent", id: "lease", now: 121)["state"], .string("ended"))
    }
    func testInvalidClockTTLAndRevocation() throws {
        let sessions = NativeAutomationSession()
        for ttl in [0, 301] { XCTAssertThrowsError(try sessions.begin(owner: "a", id: "l", ttl: ttl, now: 1, date: Date())) }
        XCTAssertThrowsError(try sessions.begin(owner: "a", id: "l", ttl: 1, now: .nan, date: Date()))
        _ = try sessions.begin(owner: "a", id: "l", ttl: 60, now: 1, date: Date())
        sessions.revoke()
        XCTAssertFalse(sessions.gate(owner: "a", id: "l", now: 2))
        XCTAssertNil(sessions.active(now: 2))
    }
}
