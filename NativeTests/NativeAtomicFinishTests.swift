import XCTest
@testable import NativePolicy

final class NativeAtomicFinishTests: XCTestCase {
    private func request(_ id: String = "lease", policy: String = "return_chat", origin: String? = "chat-123") throws -> NativeFinishRequest {
        var p: [String: JSONValue] = ["lease_id": .string(id), "completion_policy": .string(policy), "stop_service": .bool(true)]
        if let origin { p["origin_session_id"] = .string(origin) }
        return try XCTUnwrap(NativeFinishRequest(params: p))
    }
    func testFinishSealsAdmissionAndDuplicateDoesNotRepeatEffect() throws {
        let sessions = NativeAutomationSession()
        _ = try sessions.begin(owner: "minis", id: "lease", ttl: 120, now: 1, date: Date())
        let r = try request()
        let first = try sessions.finish(owner: "minis", request: r, now: 2)
        XCTAssertTrue(first.first); XCTAssertEqual(first.values["state"], .string("ended"))
        XCTAssertTrue(sessions.isFinishing)
        XCTAssertFalse(sessions.gate(owner: "minis", id: "lease", now: 2))
        XCTAssertThrowsError(try sessions.begin(owner: "codex", id: "new", ttl: 120, now: 3, date: Date()))
        XCTAssertFalse(try sessions.finish(owner: "minis", request: r, now: 3).first)
        XCTAssertThrowsError(try sessions.finish(owner: "minis", request: request(policy: "stay", origin: nil), now: 3))
    }
    func testWrongOwnerAndStaleLeaseCannotSealForeignService() throws {
        let sessions = NativeAutomationSession()
        _ = try sessions.begin(owner: "minis", id: "old", ttl: 120, now: 1, date: Date())
        _ = try sessions.end(owner: "minis", id: "old", now: 2)
        _ = try sessions.begin(owner: "codex", id: "new", ttl: 120, now: 3, date: Date())
        XCTAssertThrowsError(try sessions.finish(owner: "minis", request: request("old"), now: 4))
        XCTAssertThrowsError(try sessions.finish(owner: "minis", request: request("new"), now: 4))
        XCTAssertFalse(sessions.isFinishing)
        XCTAssertTrue(sessions.gate(owner: "codex", id: "new", now: 4))
    }
    func testExpiredOwnerMayStopWithoutAcquiringAnotherUILease() throws {
        let sessions = NativeAutomationSession()
        _ = try sessions.begin(owner: "minis", id: "lease", ttl: 1, now: 1, date: Date())
        let receipt = try sessions.finish(owner: "minis", request: request(policy: "skip_unknown", origin: nil), now: 20)
        XCTAssertEqual(receipt.values["state"], .string("ended"))
        XCTAssertFalse(sessions.gate(owner: "minis", id: "lease", now: 20))
    }
    func testExplicitManualTakeoverRejectsOldFinishWithoutSealingService() throws {
        let service = ServiceKeepAwakeAuthorization()
        XCTAssertTrue(service.ready(ticket: try XCTUnwrap(service.prepareStart())))
        let source = try XCTUnwrap(service.source(lockGeneration: 0))
        let sessions = NativeAutomationSession()
        _ = try sessions.begin(owner: "minis", id: "lease", ttl: 120, now: 1, date: Date())
        sessions.revokeForManualTakeover()
        XCTAssertFalse(sessions.gate(owner: "minis", id: "lease", now: 2))
        XCTAssertThrowsError(try sessions.finish(owner: "minis", request: request(policy: "skip_unknown", origin: nil), now: 2))
        XCTAssertFalse(sessions.isFinishing)
        XCTAssertEqual(service.source(lockGeneration: 0), source)
        // A later task may use this service, but the old Minis task cannot stop it.
        XCTAssertNoThrow(try sessions.begin(owner: "codex", id: "new", ttl: 120, now: 3, date: Date()))
        XCTAssertTrue(sessions.gate(owner: "codex", id: "new", now: 4))
        XCTAssertThrowsError(try sessions.finish(owner: "minis", request: request(), now: 4))
        XCTAssertFalse(sessions.isFinishing)
    }
    func testHeartbeatExpiryAndHealthRevocationRetainOwnedCleanupAuthority() throws {
        for healthRevoked in [false, true] {
            let sessions = NativeAutomationSession()
            _ = try sessions.begin(owner: "minis", id: "lease", ttl: 120, now: 1, date: Date())
            if healthRevoked { sessions.revoke() }
            // With no explicit takeover/new owner, heartbeat silence and a lock
            // still permit bounded cleanup. This does not create a new UI lease.
            XCTAssertFalse(sessions.gate(owner: "minis", id: "lease", now: 20))
            XCTAssertEqual(try sessions.finish(owner: "minis", request: request(policy: "skip_unknown", origin: nil), now: 20).values["state"], .string("ended"))
            XCTAssertTrue(sessions.isFinishing)
        }
    }
    func testReturnRouteIsFixedAndSkipPoliciesDoNotOpenURL() throws {
        XCTAssertEqual(try request().returnURL?.absoluteString, "minis://sessions/chat-123")
        for policy in ["stay", "skip_unknown"] { XCTAssertNil(try request(policy: policy, origin: nil).returnURL) }
        for origin in ["../x", "a/b", "x?command=bad", "x#bad", "", "https://example.com"] {
            XCTAssertNil(NativeFinishRequest(params: ["lease_id": .string("lease"), "completion_policy": .string("return_chat"), "origin_session_id": .string(origin), "stop_service": .bool(true)]))
        }
        XCTAssertNil(NativeFinishRequest(params: ["lease_id": .string("lease"), "completion_policy": .string("return_chat"), "stop_service": .bool(true)]))
        XCTAssertNil(NativeFinishRequest(params: ["lease_id": .string("lease"), "completion_policy": .string("stay"), "stop_service": .bool(false)]))
    }
    func testOrdinaryCodexEndDoesNotSealServiceAdmission() throws {
        let sessions = NativeAutomationSession()
        _ = try sessions.begin(owner: "codex", id: "one", ttl: 120, now: 1, date: Date())
        _ = try sessions.end(owner: "codex", id: "one", now: 2)
        XCTAssertFalse(sessions.isFinishing)
        XCTAssertNoThrow(try sessions.begin(owner: "codex", id: "two", ttl: 120, now: 3, date: Date()))
    }
}
