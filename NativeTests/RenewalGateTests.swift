import XCTest
@testable import NativePolicy

final class RenewalGateTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-26T21:00:00Z")! }
    private func profiles(at time: Date, companionDays: Double = 2, runnerDays: Double = 2, runnerID: String = "test.runner", verified: Bool = true) -> RenewalProfileSnapshot {
        RenewalProfileSnapshot(companionExpiry: time.addingTimeInterval(companionDays * day), runnerExpiry: time.addingTimeInterval(runnerDays * day), companionBundleID: "test.companion", runnerBundleID: runnerID, companionTeam: "ABCDE12345", runnerTeam: "ABCDE12345", observedAt: time, runnerVerified: verified)
    }
    private func begin(_ state: inout RenewalGateState, at time: Date? = nil) -> String {
        let time = time ?? now
        let plan = state.plan(now: time, reserveIfDue: true, calendar: calendar)
        let token = plan["prepare_token"]!.stringValue!
        XCTAssertEqual(plan["next_action"], .string("prepare"))
        XCTAssertEqual(state.claimBefore(token: token, now: time, calendar: calendar)["ok"], .bool(true))
        XCTAssertEqual(state.begin(token: token, snapshot: profiles(at: time), now: time, calendar: calendar)["attempt_id"], .string(token))
        return token
    }

    func testReadOnlyPlanDoesNotClaimOrInventSuccess() {
        var state = RenewalGateState()
        let before = state
        let plan = state.plan(now: now, reserveIfDue: false, calendar: calendar)
        XCTAssertEqual(state, before)
        XCTAssertEqual(plan["next_action"], .string("idle"))
        XCTAssertEqual(plan["reason"], .string("baseline_needed"))
        XCTAssertEqual(plan["last_success_at"], .null)
        XCTAssertNil(state.active)
    }

    func testReservationPrecedesVPNAndDuplicatePlanCannotRefresh() {
        var state = RenewalGateState()
        let first = state.plan(now: now, reserveIfDue: true, calendar: calendar)
        XCTAssertEqual(first["pending"], .bool(true))
        XCTAssertEqual(first["attempt_id"], .string(""))
        let second = state.plan(now: now, reserveIfDue: true, calendar: calendar)
        XCTAssertEqual(second["next_action"], .string("idle"))
        XCTAssertEqual(second["prepare_token"], first["prepare_token"])
        XCTAssertEqual(second["attempt_id"], .string(""))
        XCTAssertEqual(state.plan(now: now.addingTimeInterval(601), reserveIfDue: false, calendar: calendar)["next_action"], .string("restore"))
    }

    func testBootstrapUsesRealMinimumExpiryMinus48HoursWithoutSuccess() {
        var state = RenewalGateState()
        let token = state.plan(now: now, reserveIfDue: true, calendar: calendar)["prepare_token"]!.stringValue!
        _ = state.claimBefore(token: token, now: now, calendar: calendar)
        let snapshot = profiles(at: now, companionDays: 7, runnerDays: 6.5)
        let result = state.begin(token: token, snapshot: snapshot, now: now, calendar: calendar)
        XCTAssertEqual(result["attempt_id"], .string(""))
        XCTAssertEqual(result["reason"], .string("not_due"))
        XCTAssertEqual(state.initialDueAt, snapshot.runnerExpiry.addingTimeInterval(-2 * day))
        XCTAssertEqual(state.lastObservedProfiles, snapshot)
        XCTAssertNil(state.lastSuccessAt)
        XCTAssertNil(state.lastRefreshDay)
        XCTAssertEqual(state.completeRecovery(token: token, now: now, calendar: calendar)["notification_kind"], .string("none"))
        XCTAssertEqual(state.plan(now: now, reserveIfDue: true, calendar: calendar)["next_action"], .string("idle"))
    }

    func testBeginRequiresMatchingReservationAndFreshVerifiedProfiles() {
        var state = RenewalGateState()
        let token = state.plan(now: now, reserveIfDue: true, calendar: calendar)["prepare_token"]!.stringValue!
        XCTAssertEqual(state.claimBefore(token: UUID().uuidString, now: now, calendar: calendar)["ok"], .bool(false))
        _ = state.claimBefore(token: token, now: now, calendar: calendar)
        XCTAssertEqual(state.claimBefore(token: token, now: now, calendar: calendar)["ok"], .bool(false))
        let result = state.begin(token: token, snapshot: profiles(at: now, verified: false), now: now, calendar: calendar)
        XCTAssertEqual(result["ok"], .bool(false))
        XCTAssertEqual(result["attempt_id"], .string(""))
        XCTAssertNil(state.lastSuccessAt)
        XCTAssertEqual(state.active?.phase, .awaitingRestore)
    }

    func testSuccessRequiresReceiptAndBothExtendedProfilesThenDayFiveIsDueAt21() {
        var state = RenewalGateState()
        let token = begin(&state)
        XCTAssertTrue(state.permitsReceipt(token: token))
        let finished = now.addingTimeInterval(120)
        _ = state.claimVerification(token: token, now: finished, calendar: calendar)
        XCTAssertFalse(state.permitsReceipt(token: token))
        let result = state.finalize(token: token, snapshot: profiles(at: finished, companionDays: 7, runnerDays: 7), receipt: RenewalGateReceipt(attemptID: token, completedAt: finished.addingTimeInterval(-1)), now: finished, calendar: calendar)
        XCTAssertEqual(result["reason"], .string("renewal_verified"))
        XCTAssertEqual(state.lastSuccessAt, finished)
        XCTAssertEqual(state.active?.phase, .awaitingRestore)
        XCTAssertEqual(state.completeRecovery(token: token, now: finished, calendar: calendar)["notification_kind"], .string("success"))
        XCTAssertEqual(state.plan(now: now.addingTimeInterval(4 * day), reserveIfDue: true, calendar: calendar)["next_action"], .string("idle"))
        // Exactly day five at 21:00, two minutes before 120 hours since success.
        XCTAssertEqual(state.plan(now: now.addingTimeInterval(5 * day), reserveIfDue: true, calendar: calendar)["next_action"], .string("prepare"))
        XCTAssertEqual(state.lastSuccessAt, finished)
    }

    func testWrongMissingAndOldReceiptsCannotCreateSuccess() {
        for kind in 0..<3 {
            var state = RenewalGateState()
            let token = begin(&state)
            _ = state.claimVerification(token: token, now: now.addingTimeInterval(120), calendar: calendar)
            let receipt: RenewalGateReceipt? = kind == 0 ? nil : RenewalGateReceipt(attemptID: kind == 1 ? UUID().uuidString : token, completedAt: now.addingTimeInterval(-60))
            let result = state.finalize(token: token, snapshot: profiles(at: now.addingTimeInterval(120), companionDays: 7, runnerDays: 7), receipt: receipt, now: now.addingTimeInterval(120), calendar: calendar)
            XCTAssertEqual(result["ok"], .bool(false))
            XCTAssertNil(state.lastSuccessAt)
            XCTAssertEqual(state.active?.phase, .awaitingRestore)
        }
    }

    func testPartialRenewalShortValidityIdentityChangeAndStaleSnapshotFail() {
        for kind in 0..<4 {
            var state = RenewalGateState()
            let token = begin(&state)
            let finish = now.addingTimeInterval(120)
            _ = state.claimVerification(token: token, now: finish, calendar: calendar)
            var after = profiles(at: finish, companionDays: 7, runnerDays: 7)
            if kind == 0 { after = RenewalProfileSnapshot(companionExpiry: now.addingTimeInterval(2 * day), runnerExpiry: finish.addingTimeInterval(7 * day), companionBundleID: "test.companion", runnerBundleID: "test.runner", companionTeam: "ABCDE12345", runnerTeam: "ABCDE12345", observedAt: finish, runnerVerified: true) }
            if kind == 1 { after = profiles(at: finish, companionDays: 5.9, runnerDays: 7) }
            if kind == 2 { after = profiles(at: finish, companionDays: 7, runnerDays: 7, runnerID: "wrong.runner") }
            if kind == 3 { after = profiles(at: now.addingTimeInterval(-300), companionDays: 7, runnerDays: 7) }
            XCTAssertEqual(state.finalize(token: token, snapshot: after, receipt: RenewalGateReceipt(attemptID: token, completedAt: finish), now: finish, calendar: calendar)["ok"], .bool(false))
            XCTAssertNil(state.lastSuccessAt)
        }
    }

    func testInterruptedPreparationHasRecoveryEvenBeforeBeginAndNoFakeSuccess() {
        var state = RenewalGateState()
        let token = state.plan(now: now, reserveIfDue: true, calendar: calendar)["prepare_token"]!.stringValue!
        XCTAssertEqual(state.completeRecovery(token: token, now: now.addingTimeInterval(1), calendar: calendar)["reason"], .string("attempt_still_active"))
        let tomorrow = now.addingTimeInterval(day)
        XCTAssertEqual(state.plan(now: tomorrow, reserveIfDue: false, calendar: calendar)["next_action"], .string("restore"))
        XCTAssertEqual(state.completeRecovery(token: token, now: tomorrow, calendar: calendar)["notification_kind"], .string("error"))
        XCTAssertNil(state.lastSuccessAt)
        XCTAssertNil(state.active)
        XCTAssertLessThanOrEqual(state.retryAfter!, tomorrow)
        XCTAssertEqual(state.plan(now: tomorrow, reserveIfDue: true, calendar: calendar)["next_action"], .string("prepare"))
    }

    func testFailedAttemptNeverRefreshesTwiceSameDayButCanRetryNextDay() {
        let early = calendar.startOfDay(for: now).addingTimeInterval(2 * 3600)
        var state = RenewalGateState()
        let token = begin(&state, at: early)
        _ = state.completeRecovery(token: token, now: early.addingTimeInterval(601), calendar: calendar)
        let later = early.addingTimeInterval(13 * 3600)
        XCTAssertEqual(state.plan(now: later, reserveIfDue: true, calendar: calendar)["reason"], .string("already_refreshed_today"))
        XCTAssertNil(state.lastSuccessAt)
        XCTAssertEqual(state.plan(now: early.addingTimeInterval(day), reserveIfDue: true, calendar: calendar)["next_action"], .string("prepare"))
    }

    func testStaleFinalizeCannotCommitAfterRecoveryOrOverwriteNewReservation() {
        var state = RenewalGateState()
        let old = begin(&state)
        _ = state.completeRecovery(token: old, now: now.addingTimeInterval(601), calendar: calendar)
        let tomorrow = now.addingTimeInterval(day)
        let current = state.plan(now: tomorrow, reserveIfDue: true, calendar: calendar)["prepare_token"]!.stringValue!
        XCTAssertNotEqual(current, old)
        XCTAssertEqual(state.finalize(token: old, snapshot: profiles(at: tomorrow, companionDays: 7, runnerDays: 7), receipt: RenewalGateReceipt(attemptID: old, completedAt: tomorrow), now: tomorrow, calendar: calendar)["reason"], .string("attempt_mismatch"))
        XCTAssertEqual(state.active?.id, current)
        XCTAssertNil(state.lastSuccessAt)
    }

    func testLocalCalendarCadenceSurvivesDaylightSavingWithoutUsing120Hours() {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var state = RenewalGateState()
        state.lastSuccessAt = ISO8601DateFormatter().date(from: "2026-10-31T04:02:00Z")!
        let due = state.nextDue(calendar: local)!
        XCTAssertEqual(local.component(.hour, from: due), 0)
        XCTAssertEqual(local.dateComponents([.day], from: local.startOfDay(for: state.lastSuccessAt!), to: due).day, 5)
    }

    func testUserDefaultsRoundTripReadOnlyAndCorruptionFailClosed() throws {
        let name = "renewal-gate-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let claim = RenewalGateStore.plan(reserveIfDue: true, defaults: defaults, now: now, calendar: calendar)
        let saved = defaults.data(forKey: RenewalGateStore.key)
        let read = RenewalGateStore.plan(defaults: defaults, now: now, calendar: calendar)
        XCTAssertEqual(read["prepare_token"], claim["prepare_token"])
        XCTAssertEqual(defaults.data(forKey: RenewalGateStore.key), saved)
        for corrupt: Any in [Data("bad".utf8), "wrong-type"] {
            defaults.set(corrupt, forKey: RenewalGateStore.key)
            XCTAssertEqual(RenewalGateStore.plan(reserveIfDue: true, defaults: defaults, now: now, calendar: calendar)["reason"], .string("state_corrupt"))
        }
        var unknown = RenewalGateState(); unknown.schemaVersion = 2
        defaults.set(try JSONEncoder().encode(unknown), forKey: RenewalGateStore.key)
        let result = RenewalGateStore.plan(reserveIfDue: true, defaults: defaults, now: now, calendar: calendar)
        XCTAssertEqual(result["reason"], .string("state_corrupt"))
        XCTAssertEqual(result["notification_kind"], .string("error"))
    }

    func testConcurrentReservationsAuthorizeExactlyOnePreparation() {
        let name = "renewal-gate-race-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let lock = NSLock()
        var winners = 0
        let time = now, calendar = self.calendar
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            let result = RenewalGateStore.plan(reserveIfDue: true, defaults: defaults, now: time, calendar: calendar)
            if result["next_action"] == .string("prepare") { lock.lock(); winners += 1; lock.unlock() }
        }
        XCTAssertEqual(winners, 1)
    }

    func testBackwardClockAndWrongReceiptPhaseDoNotAuthorizeWork() {
        var state = RenewalGateState()
        state.lastSuccessAt = now.addingTimeInterval(day)
        let clock = state.plan(now: now, reserveIfDue: true, calendar: calendar)
        XCTAssertEqual(clock["reason"], .string("clock_moved_backwards"))
        XCTAssertEqual(clock["notification_kind"], .string("error"))
        XCTAssertNil(state.active)
        state.lastSuccessAt = nil
        let token = state.plan(now: now, reserveIfDue: true, calendar: calendar)["prepare_token"]!.stringValue!
        XCTAssertFalse(state.permitsReceipt(token: token))
        XCTAssertFalse(state.permitsReceipt(token: UUID().uuidString))
    }
}
