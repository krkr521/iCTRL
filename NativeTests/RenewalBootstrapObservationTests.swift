import XCTest
@testable import NativePolicy

final class RenewalBootstrapObservationTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-26T21:00:00Z")! }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private func snapshot(observed: Date? = nil, companionDays: Double = 7, runnerDays: Double = 6.5,
                          verified: Bool = true, runnerID: String = "test.runner",
                          team: String? = "ABCDE12345") -> RenewalProfileSnapshot {
        RenewalProfileSnapshot(companionExpiry: now.addingTimeInterval(companionDays * day),
            runnerExpiry: now.addingTimeInterval(runnerDays * day), companionBundleID: "test.companion",
            runnerBundleID: runnerID, companionTeam: "ABCDE12345", runnerTeam: team,
            observedAt: observed ?? now, runnerVerified: verified)
    }

    func testObservationComputesRealDueWithoutAttemptSuccessOrRefreshDay() {
        var state = RenewalGateState()
        let profiles = snapshot()
        XCTAssertTrue(state.observeInitialProfiles(profiles, now: now))
        XCTAssertEqual(state.lastObservedProfiles, profiles)
        XCTAssertEqual(state.nextDue(calendar: calendar), profiles.runnerExpiry.addingTimeInterval(-2 * day))
        XCTAssertNil(state.active); XCTAssertNil(state.lastSuccessAt); XCTAssertNil(state.lastRefreshDay)
        let plan = state.plan(now: now, reserveIfDue: false, calendar: calendar)
        XCTAssertEqual(plan["reason"], .string("not_due"))
        XCTAssertEqual(plan["attempt_id"], .string(""))
        XCTAssertEqual(plan["should_prepare"], .bool(false))
        // Even an observed already-due date does not reserve/authorize refresh.
        var due = RenewalGateState()
        XCTAssertTrue(due.observeInitialProfiles(snapshot(runnerDays: 1), now: now))
        XCTAssertNil(due.active); XCTAssertNil(due.lastRefreshDay)
        XCTAssertEqual(due.plan(now: now, reserveIfDue: false, calendar: calendar)["attempt_id"], .string(""))
    }

    func testRealFailedBootstrapCooldownAndFailureHistoryArePreserved() {
        var state = RenewalGateState()
        let token = state.plan(now: now, reserveIfDue: true, calendar: calendar)["prepare_token"]!.stringValue!
        _ = state.claimBefore(token: token, now: now, calendar: calendar)
        _ = state.begin(token: token, snapshot: nil, now: now, calendar: calendar)
        _ = state.completeRecovery(token: token, now: now, calendar: calendar)
        let retry = state.retryAfter, failureAt = state.lastFailureAt, failureReason = state.lastFailureReason
        XCTAssertTrue(state.observeInitialProfiles(snapshot(), now: now))
        XCTAssertEqual(state.retryAfter, retry)
        XCTAssertEqual(state.lastFailureAt, failureAt)
        XCTAssertEqual(state.lastFailureReason, failureReason)
        XCTAssertEqual(state.plan(now: now, reserveIfDue: true, calendar: calendar)["reason"], .string("retry_cooldown"))
        XCTAssertNil(state.active); XCTAssertNil(state.lastSuccessAt); XCTAssertNil(state.lastRefreshDay)
    }

    func testEveryActivePhaseIncludingCheckingBeforeIsStrictNoOp() {
        let phases: [RenewalGateState.Phase] = [.preparing, .checkingBefore, .refreshing, .verifying, .awaitingRestore]
        for phase in phases {
            var state = RenewalGateState()
            state.active = .init(id: UUID().uuidString, startedAt: now, phase: phase)
            let previous = state
            XCTAssertFalse(state.observeInitialProfiles(snapshot(), now: now))
            XCTAssertEqual(state, previous)
        }
    }

    func testExistingBaselineOrSuccessNeverChanges() {
        var baseline = RenewalGateState()
        XCTAssertTrue(baseline.observeInitialProfiles(snapshot(), now: now))
        var success = RenewalGateState(); success.lastSuccessAt = now
        var partialDue = RenewalGateState(); partialDue.initialDueAt = now
        var partialObservation = RenewalGateState(); partialObservation.lastObservedProfiles = snapshot()
        for original in [baseline, success, partialDue, partialObservation] {
            var state = original
            XCTAssertFalse(state.observeInitialProfiles(snapshot(runnerDays: 8), now: now))
            XCTAssertEqual(state, original)
        }
    }

    func testInvalidExpiredUnverifiedAndStaleSnapshotsAreNoOps() {
        let invalid = [snapshot(verified: false), snapshot(runnerID: ""), snapshot(runnerID: "bad/id"),
                       snapshot(runnerID: "test.companion"), snapshot(team: nil), snapshot(team: "OTHER12345"),
                       snapshot(observed: now.addingTimeInterval(-121)), snapshot(observed: now.addingTimeInterval(61)),
                       snapshot(companionDays: 0), snapshot(runnerDays: -1), snapshot(runnerDays: .infinity)]
        for profiles in invalid {
            var state = RenewalGateState(); let previous = state
            XCTAssertFalse(state.observeInitialProfiles(profiles, now: now))
            XCTAssertEqual(state, previous)
        }
    }

    func testStoreReturnsUpdatedPersistedPlanWithoutClearingCooldown() throws {
        let suite = "bootstrap-observation-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var state = RenewalGateState(); state.retryAfter = now.addingTimeInterval(12 * 60 * 60)
        state.lastFailureAt = now; state.lastFailureReason = "fresh_profile_unavailable"
        defaults.set(try JSONEncoder().encode(state), forKey: RenewalGateStore.key)
        let result = RenewalGateStore.observeInitialProfiles(snapshot(), defaults: defaults, now: now, calendar: calendar)
        XCTAssertNotEqual(result["next_due_at"], .null)
        XCTAssertEqual(result["baseline_runner_expires_at"], .string(ISO8601DateFormatter().string(from: snapshot().runnerExpiry)))
        XCTAssertEqual(result["reason"], .string("retry_cooldown"))
        XCTAssertEqual(result["attempt_id"], .string(""))
        let saved = try JSONDecoder().decode(RenewalGateState.self, from: defaults.data(forKey: RenewalGateStore.key)!)
        XCTAssertEqual(saved.retryAfter, state.retryAfter)
        XCTAssertNil(saved.lastSuccessAt); XCTAssertNil(saved.lastRefreshDay); XCTAssertNil(saved.active)
    }
}
