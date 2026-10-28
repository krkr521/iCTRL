import Foundation

/// Pure timing/observation policy, not a lease or UI authority. The caller must
/// supply the current server/quietMayRestore result at every boundary below.
/// The existing callback + 8s restoration window and Begin TTL remain decisive.
/// Keep argument order: evaluate the real gate before taking a fresh `now`.
struct QuietForegroundRestorationPolicy {
    enum Phase: String, CaseIterable {
        case awaitingActivation = "awaiting_activation"
        case activating, confirming, confirmed, failed
    }
    enum Failure: String, CaseIterable {
        case invalidBudget = "invalid_budget"
        case invalidClock = "invalid_clock"
        case authorizationLost = "authorization_lost"
        case invalidPhase = "invalid_phase"
        case actionAdmissionExpired = "action_admission_expired"
        case activationRejected = "activation_rejected"
        case confirmationBudgetExpired = "confirmation_budget_expired"
        case confirmationReadExpired = "confirmation_read_expired"
    }
    enum Evidence: String, CaseIterable {
        case none
        case targetPIDUnavailable = "target_pid_unavailable"
        case frontmostPIDUnavailable = "frontmost_pid_unavailable"
        case pidMismatch = "pid_mismatch"
        case pidChanged = "pid_changed"
        case oneMatch = "one_match"
        case confirmed
    }
    enum Outcome: Equatable { case waiting, confirmed, failed(Failure) }

    static let pollInterval: TimeInterval = 0.1
    private(set) var phase: Phase = .awaitingActivation
    private(set) var failure: Failure?
    private(set) var evidence: Evidence = .none
    private let startedAt: TimeInterval
    private let actionDeadline: TimeInterval
    private let confirmationBudget: TimeInterval
    private var confirmationStartedAt: TimeInterval
    private var confirmationDeadline: TimeInterval?
    private var proof: QuietForegroundConfirmation?
    private var lastNow: TimeInterval
    private var observationInFlight = false
    private var previousTargetPID: Int32 = 0
    private var previousFrontmostPID: Int32 = 0
    private var previousObservationAt: TimeInterval?

    init(startedAt: TimeInterval, actionAdmissionBudget: TimeInterval = 2,
         confirmationBudget: TimeInterval = 2) {
        self.startedAt = startedAt
        self.lastNow = startedAt
        self.actionDeadline = startedAt + actionAdmissionBudget
        self.confirmationBudget = confirmationBudget
        self.confirmationStartedAt = startedAt
        // Neither phase can be enlarged through a caller-provided budget.
        if !startedAt.isFinite {
            self.phase = .failed
            self.failure = .invalidClock
        } else if !actionAdmissionBudget.isFinite || !confirmationBudget.isFinite ||
            actionAdmissionBudget <= 0 || actionAdmissionBudget > 2 ||
            confirmationBudget <= 0 || confirmationBudget > 2 ||
            !actionDeadline.isFinite || actionDeadline <= startedAt {
            self.phase = .failed
            self.failure = .invalidBudget
        }
    }

    /// Consume the sole activation admission immediately before the one native
    /// open/activate call, after the caller's fresh foreground-change check.
    mutating func admitActivation(authorized: Bool, now: TimeInterval) -> Bool {
        guard require(.awaitingActivation), validate(authorized: authorized, now: now) else { return false }
        guard now < actionDeadline else { return reject(.actionAdmissionExpired) }
        phase = .activating
        return true
    }

    /// An activation already admitted may return after the action deadline.
    /// It gets a new confirmation budget only if the ORIGINAL lease gate still
    /// permits restoration. No second activation can be admitted.
    mutating func activationReturned(accepted: Bool, authorized: Bool, now: TimeInterval) -> Bool {
        guard require(.activating), validate(authorized: authorized, now: now) else { return false }
        guard accepted else { return reject(.activationRejected) }
        return startConfirmation(now: now)
    }

    /// For the existing beforePID == fresh targetPID path. This grants no UI
    /// action and still requires two NEW fresh PID observations.
    mutating func alreadyForeground(authorized: Bool, now: TimeInterval) -> Bool {
        guard require(.awaitingActivation), validate(authorized: authorized, now: now) else { return false }
        guard now < actionDeadline else { return reject(.actionAdmissionExpired) }
        return startConfirmation(now: now)
    }

    mutating func beginObservation(authorized: Bool, now: TimeInterval) -> Bool {
        guard require(.confirming), !observationInFlight else { return reject(.invalidPhase) }
        guard validate(authorized: authorized, now: now) else { return false }
        guard let deadline = confirmationDeadline, now < deadline else { return reject(.confirmationBudgetExpired) }
        observationInFlight = true
        return true
    }

    /// Call after each synchronous PID read, including between named/frontmost
    /// reads. An overlong read is discarded; no later read/action is started.
    mutating func mayContinueObservation(authorized: Bool, now: TimeInterval) -> Bool {
        guard require(.confirming), observationInFlight else { return reject(.invalidPhase) }
        guard validate(authorized: authorized, now: now) else { return false }
        guard let deadline = confirmationDeadline, now < deadline else { return reject(.confirmationReadExpired) }
        return true
    }

    mutating func finishObservation(targetPID: Int32, frontmostPID: Int32,
                                    authorized: Bool, now: TimeInterval) -> Outcome {
        guard mayContinueObservation(authorized: authorized, now: now) else {
            return .failed(failure ?? .invalidPhase)
        }
        observationInFlight = false
        // Reset the old two-consecutive-PID proof when polling too quickly.
        // This cannot turn two reads in one instant into independent proof.
        if let previousObservationAt, now - previousObservationAt < Self.pollInterval {
            proof = QuietForegroundConfirmation(startedAt: confirmationStartedAt,
                                                budget: confirmationBudget)
        }
        let changed = previousTargetPID > 0 &&
            (targetPID != previousTargetPID || frontmostPID != previousFrontmostPID)
        previousTargetPID = targetPID
        previousFrontmostPID = frontmostPID
        previousObservationAt = now
        if targetPID <= 0 { evidence = .targetPIDUnavailable }
        else if frontmostPID <= 0 { evidence = .frontmostPIDUnavailable }
        else if targetPID != frontmostPID { evidence = .pidMismatch }
        else { evidence = changed ? .pidChanged : .oneMatch }
        guard let outcome = proof?.observe(targetPID: targetPID, frontmostPID: frontmostPID, now: now) else {
            _ = reject(.invalidPhase)
            return .failed(.invalidPhase)
        }
        if outcome == .confirmed { phase = .confirmed; evidence = .confirmed; return .confirmed }
        if outcome == .expired {
            _ = reject(.confirmationReadExpired)
            return .failed(.confirmationReadExpired)
        }
        return .waiting
    }

    /// Still not authority to finish the lease: quietFinishRestoration must do
    /// its original locked nonce/owner/TTL check immediately after this.
    mutating func mayCommit(authorized: Bool, now: TimeInterval) -> Bool {
        guard require(.confirmed), validate(authorized: authorized, now: now) else { return false }
        guard let deadline = confirmationDeadline, now < deadline else { return reject(.confirmationBudgetExpired) }
        return true
    }

    /// All values are finite enums. No app/PID/nonce/URL/payload/error text.
    var safeDiagnosticLine: String {
        "QuietRestore phase=\(phase.rawValue) reason=\(failure?.rawValue ?? "none") evidence=\(evidence.rawValue)"
    }

    /// Compatibility for existing owner context + QuietDiagnostics.Reason.
    var legacyContextDiagnostic: String {
        switch failure {
        case .actionAdmissionExpired: return "foreground_restore_budget_expired"
        case .activationRejected: return "foreground_activation_rejected"
        case .confirmationReadExpired: return "foreground_restore_budget_expired"
        case .confirmationBudgetExpired:
            return evidence == .none || evidence == .targetPIDUnavailable
                ? "foreground_target_pid_unavailable" : "foreground_pid_unconfirmed"
        default: return "foreground_restore_unconfirmed"
        }
    }

    private mutating func startConfirmation(now: TimeInterval) -> Bool {
        let deadline = now + confirmationBudget
        guard deadline.isFinite, deadline > now else { return reject(.invalidClock) }
        confirmationDeadline = deadline
        confirmationStartedAt = now
        proof = QuietForegroundConfirmation(startedAt: now, budget: confirmationBudget)
        phase = .confirming
        return true
    }

    private mutating func validate(authorized: Bool, now: TimeInterval) -> Bool {
        guard now.isFinite, now >= startedAt, now >= lastNow else { return reject(.invalidClock) }
        lastNow = now
        guard authorized else { return reject(.authorizationLost) }
        return true
    }

    private mutating func require(_ expected: Phase) -> Bool {
        guard phase != .failed else { return false }
        return phase == expected || reject(.invalidPhase)
    }

    @discardableResult private mutating func reject(_ reason: Failure) -> Bool {
        if phase != .failed { phase = .failed; failure = reason; observationInFlight = false }
        return false
    }
}
