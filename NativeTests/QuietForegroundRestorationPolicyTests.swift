import XCTest
@testable import NativePolicy

final class QuietForegroundRestorationPolicyTests: XCTestCase {
    private func observe(_ policy: inout QuietForegroundRestorationPolicy, target: Int32 = 42,
                         front: Int32 = 42, at time: TimeInterval,
                         authorized: Bool = true) -> QuietForegroundRestorationPolicy.Outcome {
        guard policy.beginObservation(authorized: authorized, now: time) else {
            return .failed(policy.failure ?? .invalidPhase)
        }
        return policy.finishObservation(targetPID: target, frontmostPID: front,
                                        authorized: authorized, now: time)
    }

    func testSlowAdmittedActivationDoesNotSpendFreshConfirmationBudget() {
        // The previous implementation expires before its first matching read.
        var old = QuietForegroundConfirmation(startedAt: 10, budget: 2)
        XCTAssertTrue(old.permitsAction(now: 11.8))
        XCTAssertEqual(old.observe(targetPID: 42, frontmostPID: 42, now: 12.2), .expired)

        var policy = QuietForegroundRestorationPolicy(startedAt: 10)
        XCTAssertTrue(policy.admitActivation(authorized: true, now: 11.8))
        XCTAssertTrue(policy.activationReturned(accepted: true, authorized: true, now: 12.1))
        XCTAssertEqual(observe(&policy, at: 12.2), .waiting)
        XCTAssertEqual(observe(&policy, at: 12.31), .confirmed)
        XCTAssertTrue(policy.mayCommit(authorized: true, now: 12.32))
    }

    func testQueueCannotAdmitActivationAtOrAfterOriginalActionDeadline() {
        for now in [12.0, 12.1] {
            var policy = QuietForegroundRestorationPolicy(startedAt: 10)
            XCTAssertFalse(policy.admitActivation(authorized: true, now: now))
            XCTAssertEqual(policy.failure, .actionAdmissionExpired)
            XCTAssertFalse(policy.activationReturned(accepted: true, authorized: true, now: now))
        }
    }

    func testGateEvaluationPrecedesFreshClockSnapshot() {
        var time: TimeInterval = 11.9
        func gate() -> Bool { time = 12.1; return true }
        func clock() -> TimeInterval { time }
        var policy = QuietForegroundRestorationPolicy(startedAt: 10)
        XCTAssertFalse(policy.admitActivation(authorized: gate(), now: clock()))
        XCTAssertEqual(policy.failure, .actionAdmissionExpired)
    }

    func testOriginalAuthorizationLostDuringActivationCannotBeRenewedByNewClock() {
        var policy = QuietForegroundRestorationPolicy(startedAt: 10)
        XCTAssertTrue(policy.admitActivation(authorized: true, now: 10.1))
        // Models the existing 8s window/Begin TTL/nonce/server gate expiring.
        XCTAssertFalse(policy.activationReturned(accepted: true, authorized: false, now: 18.1))
        XCTAssertEqual(policy.failure, .authorizationLost)
        XCTAssertFalse(policy.alreadyForeground(authorized: true, now: 18.2))
        XCTAssertFalse(policy.beginObservation(authorized: true, now: 18.2))
        XCTAssertFalse(policy.mayCommit(authorized: true, now: 18.2))
    }

    func testActualQuietControlOuterWindowAndBeginTTLStillWin() throws {
        for ttl in [1, 240] {
            let control = QuietControl(enabled: true, port: 8200)
            _ = try control.register(owner: "test.owner", mode: "automation", now: 10)
            let begin = try control.begin(owner: "test.owner", ttl: ttl, now: 10, date: Date(timeIntervalSince1970: 10))
            let parts = try XCTUnwrap(URLComponents(url: begin.url, resolvingAgainstBaseURL: false))
            let text = try XCTUnwrap(parts.queryItems?.first(where: { $0.name == "text" })?.value)
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
            let body = try JSONSerialization.data(withJSONObject: [
                "nonce": try XCTUnwrap(input["nonce"]), "action": "begin",
                "deadline": try XCTUnwrap(input["deadline"]), "observed_focus": "iCTRL Automation"])
            let callback = try QuietCallback.parse(method: "POST", path: "/quiet-callback",
                contentType: "application/json", headerBytes: 100, body: body)
            XCTAssertTrue(control.callback(callback, now: 10.1))
            let restore = try XCTUnwrap(control.restorationForAcceptedCallback(callback, now: 10.1))
            var policy = QuietForegroundRestorationPolicy(startedAt: 10.1)
            XCTAssertTrue(policy.admitActivation(authorized: control.mayRestore(restore, now: 10.2), now: 10.2))
            let returnedAt: TimeInterval = ttl == 1 ? 11 : 18.2
            XCTAssertFalse(policy.activationReturned(accepted: true,
                authorized: control.mayRestore(restore, now: returnedAt), now: returnedAt))
            XCTAssertEqual(policy.failure, .authorizationLost)
            XCTAssertFalse(policy.beginObservation(authorized: true, now: returnedAt))
            XCTAssertNotNil(control.gate(owner: "test.manual", method: "tap", session: nil, now: returnedAt))
        }
    }

    func testOneActivationOnlyAndRejectedActivationNeverStartsProof() {
        var policy = QuietForegroundRestorationPolicy(startedAt: 10)
        XCTAssertTrue(policy.admitActivation(authorized: true, now: 10.1))
        XCTAssertFalse(policy.admitActivation(authorized: true, now: 10.2))
        XCTAssertEqual(policy.failure, .invalidPhase)
        XCTAssertFalse(policy.activationReturned(accepted: true, authorized: true, now: 10.3))
        var rejected = QuietForegroundRestorationPolicy(startedAt: 10)
        XCTAssertTrue(rejected.admitActivation(authorized: true, now: 10.1))
        XCTAssertFalse(rejected.activationReturned(accepted: false, authorized: true, now: 10.2))
        XCTAssertEqual(rejected.failure, .activationRejected)
        XCTAssertFalse(rejected.admitActivation(authorized: true, now: 10.3))
    }

    func testAlreadyForegroundStillRequiresTwoNewSeparatedFreshObservations() {
        var policy = QuietForegroundRestorationPolicy(startedAt: 10)
        XCTAssertTrue(policy.alreadyForeground(authorized: true, now: 10.1))
        XCTAssertFalse(policy.mayCommit(authorized: true, now: 10.11))
        XCTAssertEqual(policy.failure, .invalidPhase)
        var fresh = QuietForegroundRestorationPolicy(startedAt: 10)
        XCTAssertTrue(fresh.alreadyForeground(authorized: true, now: 10.1))
        XCTAssertEqual(observe(&fresh, at: 10.2), .waiting)
        XCTAssertEqual(observe(&fresh, at: 10.25), .waiting)
        XCTAssertEqual(observe(&fresh, at: 10.36), .confirmed)
    }

    func testMissingMismatchedOrChangedPIDsResetConsecutiveProof() {
        var policy = QuietForegroundRestorationPolicy(startedAt: 10)
        XCTAssertTrue(policy.alreadyForeground(authorized: true, now: 10))
        XCTAssertEqual(observe(&policy, at: 10.1), .waiting)
        XCTAssertEqual(observe(&policy, target: 0, at: 10.21), .waiting)
        XCTAssertEqual(policy.evidence, .targetPIDUnavailable)
        XCTAssertEqual(observe(&policy, front: 0, at: 10.32), .waiting)
        XCTAssertEqual(policy.evidence, .frontmostPIDUnavailable)
        XCTAssertEqual(observe(&policy, front: 7, at: 10.43), .waiting)
        XCTAssertEqual(policy.evidence, .pidMismatch)
        XCTAssertEqual(observe(&policy, at: 10.54), .waiting)
        XCTAssertEqual(observe(&policy, target: 43, front: 43, at: 10.65), .waiting)
        XCTAssertEqual(policy.evidence, .pidChanged)
        XCTAssertEqual(observe(&policy, target: 43, front: 43, at: 10.76), .confirmed)
    }

    func testOverlongNamedReadStopsBeforeNextFrontmostReadOrConfirmation() {
        var policy = QuietForegroundRestorationPolicy(startedAt: 10, confirmationBudget: 2)
        XCTAssertTrue(policy.alreadyForeground(authorized: true, now: 10))
        XCTAssertTrue(policy.beginObservation(authorized: true, now: 11.9))
        // The caller's synchronous named-PID query returns after the deadline.
        XCTAssertFalse(policy.mayContinueObservation(authorized: true, now: 12))
        XCTAssertEqual(policy.failure, .confirmationReadExpired)
        XCTAssertEqual(policy.evidence, .none)
        XCTAssertEqual(policy.finishObservation(targetPID: 42, frontmostPID: 42,
                                               authorized: true, now: 12.1), .failed(.confirmationReadExpired))
    }

    func testNoNewReadAtConfirmationDeadlineAndLateSecondMatchCannotConfirm() {
        var policy = QuietForegroundRestorationPolicy(startedAt: 10, confirmationBudget: 2)
        XCTAssertTrue(policy.alreadyForeground(authorized: true, now: 10))
        XCTAssertEqual(observe(&policy, at: 11.8), .waiting)
        XCTAssertTrue(policy.beginObservation(authorized: true, now: 11.95))
        XCTAssertEqual(policy.finishObservation(targetPID: 42, frontmostPID: 42,
                                               authorized: true, now: 12), .failed(.confirmationReadExpired))
        var noRead = QuietForegroundRestorationPolicy(startedAt: 10, confirmationBudget: 2)
        XCTAssertTrue(noRead.alreadyForeground(authorized: true, now: 10))
        XCTAssertFalse(noRead.beginObservation(authorized: true, now: 12))
        XCTAssertEqual(noRead.failure, .confirmationBudgetExpired)
    }

    func testAuthorizationCheckedBetweenReadsAndAgainBeforeCommit() {
        var policy = QuietForegroundRestorationPolicy(startedAt: 10)
        XCTAssertTrue(policy.alreadyForeground(authorized: true, now: 10))
        XCTAssertTrue(policy.beginObservation(authorized: true, now: 10.1))
        XCTAssertFalse(policy.mayContinueObservation(authorized: false, now: 10.2))
        XCTAssertEqual(policy.failure, .authorizationLost)
        var commit = QuietForegroundRestorationPolicy(startedAt: 10)
        XCTAssertTrue(commit.alreadyForeground(authorized: true, now: 10))
        XCTAssertEqual(observe(&commit, at: 10.1), .waiting)
        XCTAssertEqual(observe(&commit, at: 10.21), .confirmed)
        XCTAssertFalse(commit.mayCommit(authorized: false, now: 10.22))
        XCTAssertEqual(commit.failure, .authorizationLost)
    }

    func testCompletedProofStillCannotCommitAfterConfirmationBudget() {
        var policy = QuietForegroundRestorationPolicy(startedAt: 10, confirmationBudget: 2)
        XCTAssertTrue(policy.alreadyForeground(authorized: true, now: 10))
        XCTAssertEqual(observe(&policy, at: 10.1), .waiting)
        XCTAssertEqual(observe(&policy, at: 10.21), .confirmed)
        XCTAssertFalse(policy.mayCommit(authorized: true, now: 12))
        XCTAssertEqual(policy.failure, .confirmationBudgetExpired)
    }

    func testInvalidBudgetsAndNonMonotonicClockCannotAdmitOrConfirm() {
        for budget in [0, -1, 6.01, .nan, .infinity] as [TimeInterval] {
            var policy = QuietForegroundRestorationPolicy(startedAt: 10, confirmationBudget: budget)
            XCTAssertFalse(policy.admitActivation(authorized: true, now: 10.1))
            XCTAssertEqual(policy.failure, .invalidBudget)
        }
        for budget in [0, -1, 2.01, .nan, .infinity] as [TimeInterval] {
            var action = QuietForegroundRestorationPolicy(startedAt: 10, actionAdmissionBudget: budget)
            XCTAssertFalse(action.admitActivation(authorized: true, now: 10.1))
            XCTAssertEqual(action.failure, .invalidBudget)
        }
        var noClock = QuietForegroundRestorationPolicy(startedAt: .nan)
        XCTAssertFalse(noClock.admitActivation(authorized: true, now: 10))
        XCTAssertEqual(noClock.failure, .invalidClock)
        for now in [9.9, .nan, .infinity] {
            var policy = QuietForegroundRestorationPolicy(startedAt: 10)
            XCTAssertFalse(policy.admitActivation(authorized: true, now: now))
            XCTAssertEqual(policy.failure, .invalidClock)
        }
        var backwards = QuietForegroundRestorationPolicy(startedAt: 10)
        XCTAssertTrue(backwards.alreadyForeground(authorized: true, now: 10.2))
        XCTAssertFalse(backwards.beginObservation(authorized: true, now: 10.1))
        XCTAssertEqual(backwards.failure, .invalidClock)
    }

    func testFiniteDiagnosticsContainNoRuntimeIdentityOrPID() {
        var policy = QuietForegroundRestorationPolicy(startedAt: 10, confirmationBudget: 2)
        XCTAssertTrue(policy.alreadyForeground(authorized: true, now: 10))
        XCTAssertEqual(observe(&policy, target: 12345, front: 23456, at: 10.1), .waiting)
        XCTAssertFalse(policy.beginObservation(authorized: true, now: 12))
        XCTAssertEqual(policy.safeDiagnosticLine,
            "QuietRestore phase=failed reason=confirmation_budget_expired evidence=pid_mismatch")
        XCTAssertFalse(policy.safeDiagnosticLine.contains("12345"))
        XCTAssertFalse(policy.safeDiagnosticLine.contains("23456"))
        XCTAssertEqual(policy.legacyContextDiagnostic, "foreground_pid_unconfirmed")
        for value in QuietForegroundRestorationPolicy.Failure.allCases.map(\.rawValue) +
            QuietForegroundRestorationPolicy.Evidence.allCases.map(\.rawValue) +
            QuietForegroundRestorationPolicy.Phase.allCases.map(\.rawValue) {
            XCTAssertNotNil(value.range(of: "^[a-z_]+$", options: .regularExpression))
        }
    }

    func testTransitionPIDBeyondTwoSecondsCanConfirmWithinOriginalAuthorization() {
        var policy = QuietForegroundRestorationPolicy(startedAt: 10)
        XCTAssertTrue(policy.admitActivation(authorized: true, now: 10.1))
        XCTAssertTrue(policy.activationReturned(accepted: true, authorized: true, now: 10.2))
        XCTAssertEqual(observe(&policy, front: 7, at: 10.4), .waiting)
        // Models the observed End expiry with a prior PID mismatch. The device
        // log does not prove when its next matching PID would become available.
        XCTAssertEqual(observe(&policy, front: 7, at: 12.5), .waiting)
        XCTAssertEqual(observe(&policy, at: 13.1), .waiting)
        XCTAssertEqual(observe(&policy, at: 13.21), .confirmed)
        XCTAssertTrue(policy.mayCommit(authorized: true, now: 13.22))
    }

    func testDefaultReadBudgetStillExpiresAtSixSeconds() {
        var policy = QuietForegroundRestorationPolicy(startedAt: 10)
        XCTAssertTrue(policy.alreadyForeground(authorized: true, now: 10))
        XCTAssertEqual(observe(&policy, at: 15.8), .waiting)
        XCTAssertTrue(policy.beginObservation(authorized: true, now: 15.95))
        XCTAssertEqual(policy.finishObservation(targetPID: 42, frontmostPID: 42,
            authorized: true, now: 16), .failed(.confirmationReadExpired))
        XCTAssertFalse(policy.mayCommit(authorized: true, now: 16.1))
    }

    func testExtendedReadBudgetCannotOutliveActualCallbackWindowOrBeginTTL() throws {
        for ttl in [4, 240] {
            let control = QuietControl(enabled: true, port: 8200)
            _ = try control.register(owner: "test.owner", mode: "automation", now: 10)
            let begin = try control.begin(owner: "test.owner", ttl: ttl, now: 10, date: Date(timeIntervalSince1970: 10))
            let parts = try XCTUnwrap(URLComponents(url: begin.url, resolvingAgainstBaseURL: false))
            let text = try XCTUnwrap(parts.queryItems?.first(where: { $0.name == "text" })?.value)
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
            let body = try JSONSerialization.data(withJSONObject: [
                "nonce": try XCTUnwrap(input["nonce"]), "action": "begin",
                "deadline": try XCTUnwrap(input["deadline"]), "observed_focus": "iCTRL Automation"])
            let callback = try QuietCallback.parse(method: "POST", path: "/quiet-callback",
                contentType: "application/json", headerBytes: 100, body: body)
            XCTAssertTrue(control.callback(callback, now: 10.1))
            let restore = try XCTUnwrap(control.restorationForAcceptedCallback(callback, now: 10.1))
            var policy = QuietForegroundRestorationPolicy(startedAt: 10.1)
            XCTAssertTrue(policy.admitActivation(authorized: control.mayRestore(restore, now: 10.2), now: 10.2))
            let returnedAt: TimeInterval = ttl == 4 ? 12 : 16
            XCTAssertTrue(policy.activationReturned(accepted: true,
                authorized: control.mayRestore(restore, now: returnedAt), now: returnedAt))
            XCTAssertTrue(policy.beginObservation(authorized: control.mayRestore(restore, now: returnedAt + 0.1),
                now: returnedAt + 0.1))
            // Both original deadlines occur before the new local 6s cap.
            let expiredAt: TimeInterval = ttl == 4 ? 14 : 18.2
            XCTAssertFalse(policy.mayContinueObservation(authorized: control.mayRestore(restore, now: expiredAt),
                now: expiredAt))
            XCTAssertEqual(policy.failure, .authorizationLost)
            XCTAssertFalse(policy.mayCommit(authorized: true, now: expiredAt + 0.1))
            XCTAssertNotNil(control.gate(owner: "test.manual", method: "tap", session: nil, now: expiredAt))
        }
    }
}
