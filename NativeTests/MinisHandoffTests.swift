import XCTest
@testable import NativePolicy

final class MinisHandoffTests: XCTestCase {
    private func request(_ policy: String = "return_chat") throws -> NativeFinishRequest {
        var params: [String: JSONValue] = ["lease_id": .string("lease"), "completion_policy": .string(policy), "stop_service": .bool(true)]
        if policy == "return_chat" { params["origin_session_id"] = .string("exact-origin") }
        return try XCTUnwrap(NativeFinishRequest(params: params))
    }
    func testReservationClosesBodyButDefersEndUntilHandoffTerminal() throws {
        let sessions = NativeAutomationSession()
        _ = try sessions.begin(owner: "minis", id: "lease", ttl: 120, now: 1, date: Date())
        let r = try request(); let (reserved, first) = try sessions.reserveFinish(owner: "minis", request: r, now: 2)
        XCTAssertTrue(first); XCTAssertEqual(reserved.deadline, 10)
        XCTAssertEqual(sessions.status(owner: "minis", now: 2)?["state"], .string("active"))
        XCTAssertFalse(sessions.gate(owner: "minis", id: "lease", now: 2))
        XCTAssertTrue(sessions.mayHandoff(reserved, now: 3))
        XCTAssertThrowsError(try sessions.begin(owner: "foreign", id: "new", ttl: 120, now: 3, date: Date()))
        let (duplicate, again) = try sessions.reserveFinish(owner: "minis", request: r, now: 3)
        XCTAssertFalse(again); XCTAssertEqual(duplicate, reserved)
        XCTAssertEqual(try sessions.completeFinish(reserved, now: 4)["state"], .string("ended"))
        XCTAssertFalse(sessions.mayHandoff(reserved, now: 4))
    }
    func testManualTakeoverCancelsReservedCallbackAndPreservesNewOwner() throws {
        let sessions = NativeAutomationSession()
        _ = try sessions.begin(owner: "minis", id: "lease", ttl: 120, now: 1, date: Date())
        let (reserved, _) = try sessions.reserveFinish(owner: "minis", request: request(), now: 2)
        sessions.revokeForManualTakeover()
        XCTAssertFalse(sessions.isFinishing); XCTAssertFalse(sessions.mayHandoff(reserved, now: 3))
        _ = try sessions.begin(owner: "codex", id: "new", ttl: 120, now: 3, date: Date())
        XCTAssertThrowsError(try sessions.completeFinish(reserved, now: 4))
        XCTAssertTrue(sessions.gate(owner: "codex", id: "new", now: 4))
        // The ten-second server fallback and any still-later callback remain stale.
        XCTAssertThrowsError(try sessions.completeFinish(reserved, now: 12))
        XCTAssertTrue(sessions.gate(owner: "codex", id: "new", now: 12))
        XCTAssertThrowsError(try sessions.completeFinish(reserved, now: 13))
        XCTAssertTrue(sessions.gate(owner: "codex", id: "new", now: 13))
    }
    func testExpiredAndUnknownNeverAcquireHandoffUIAuthorityButCanEnd() throws {
        for policy in ["return_chat", "stay", "skip_unknown"] {
            let sessions = NativeAutomationSession()
            _ = try sessions.begin(owner: "minis", id: "lease", ttl: 120, now: 1, date: Date())
            let (r, _) = try sessions.reserveFinish(owner: "minis", request: request(policy), now: 20)
            XCTAssertNil(r.deadline); XCTAssertFalse(sessions.mayHandoff(r, now: 20))
            XCTAssertEqual(try sessions.completeFinish(r, now: 21)["state"], .string("ended"))
        }
    }
    func testHandoffBoundNeverExtendsOriginalTTLOrHeartbeat() throws {
        for ttl in [3, 120] {
            let s = NativeAutomationSession(); _ = try s.begin(owner: "minis", id: "lease", ttl: ttl, now: 1, date: Date())
            let (r, _) = try s.reserveFinish(owner: "minis", request: request(), now: 2)
            XCTAssertLessThanOrEqual(try XCTUnwrap(r.deadline), min(1 + Double(ttl), 16))
            XCTAssertFalse(s.mayHandoff(r, now: 16))
            XCTAssertNoThrow(try s.completeFinish(r, now: 16))
        }
    }
    func testOneRouteAndTwoForegroundSamplesWithoutImplicitAlertHandling() {
        var p = MinisHandoffPolicy(deadline: 10)
        XCTAssertTrue(p.admitDispatch(authorized: true, now: 1))
        XCTAssertFalse(p.admitDispatch(authorized: true, now: 2))
        XCTAssertNil(p.observe(authorized: true, now: 2, alert: false, foreground: true))
        XCTAssertNil(p.observe(authorized: true, now: 3, alert: false, foreground: false))
        XCTAssertNil(p.observe(authorized: true, now: 4, alert: false, foreground: true))
        XCTAssertEqual(p.observe(authorized: true, now: 5, alert: false, foreground: true), "app_confirmed")
    }
    func testUnknownAlertCancellationAndCallbackLossFailClosedWithoutReplay() {
        var alert = MinisHandoffPolicy(deadline: 10)
        XCTAssertTrue(alert.admitDispatch(authorized: true, now: 1))
        XCTAssertEqual(alert.observe(authorized: true, now: 2, alert: true, foreground: true), "blocked_alert")
        XCTAssertFalse(alert.admitDispatch(authorized: true, now: 3))
        var lost = MinisHandoffPolicy(deadline: 10)
        XCTAssertTrue(lost.admitDispatch(authorized: true, now: 1))
        XCTAssertEqual(lost.observe(authorized: true, now: 10, alert: false, foreground: false), "timeout")
        var cancelled = MinisHandoffPolicy(deadline: 10)
        XCTAssertTrue(cancelled.admitDispatch(authorized: true, now: 1))
        XCTAssertEqual(cancelled.observe(authorized: false, now: 2, alert: false, foreground: true), "cancelled")
    }
}
