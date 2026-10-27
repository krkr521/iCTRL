import Foundation

/// Pure lease transition model. Integrator provides cryptographically random IDs/nonces and monotonic `now`.
public struct QuietLease {
    public enum State: String {
        case preparing = "preparing"
        case quietVerified = "quiet_verified"
        case failed = "failed"
        case ending = "ending"
        case ended = "ended"
        case expired = "expired"
        case suspended = "suspended"
        case restorationPending = "restoration_pending"
        case restoring = "restoring"
    }
    public enum Decision: Equatable { case allowed, denied(String) }
    public let ownerTokId: String
    public let id: String
    public let deadline: TimeInterval
    public private(set) var state: State = .preparing
    private var pending: (nonce: String, action: String, expectedDeadline: String, expiry: TimeInterval)?
    private var usedNonces = Set<String>()
    private var beginUncertain = false
    private var endAttempted = false
    private var restoring: (nonce: String, action: String, observed: String)?

    public init(ownerTokId: String, id: String, ttl: TimeInterval, now: TimeInterval) throws {
        guard !ownerTokId.isEmpty, !id.isEmpty, ttl.isFinite, now.isFinite, ttl > 0, ttl <= 300 else { throw LeaseError.invalid }
        self.ownerTokId = ownerTokId; self.id = id; self.deadline = now + ttl
    }

    public mutating func prepareCallback(nonce: String, action: String, expectedDeadline: String, now: TimeInterval) throws {
        guard nonce.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              !expectedDeadline.isEmpty, now.isFinite,
              action == "begin" || action == "end" || action == "inspect" else { throw LeaseError.invalid }
        guard (action == "begin" && state == .preparing) || (action == "end" && state == .ending) ||
              (action == "inspect" && state == .restorationPending && now >= deadline + 300) else { throw LeaseError.invalid }
        guard pending == nil, !usedNonces.contains(nonce) else { throw LeaseError.invalid }
        if action == "begin" && now >= deadline { throw LeaseError.invalid }
        if action == "end" && now > deadline + 300 { throw LeaseError.invalid }
        pending = (nonce, action, expectedDeadline, now + 30)
        usedNonces.insert(nonce)
    }

    @discardableResult public mutating func callback(nonce: String, action: String, observed: String, reportedDeadline: String, now: TimeInterval) -> Bool {
        guard let p = pending, p.nonce == nonce, p.action == action, p.expectedDeadline == reportedDeadline,
              now.isFinite, now < p.expiry, (action != "begin" || now < deadline) else { return false }
        pending = nil // one use, including negative report
        if action == "begin" {
            guard state == .preparing else { return false }
            state = .restoring
        } else if action == "end" {
            guard state == .ending else { return false }
            state = .restoring
        } else {
            guard state == .restorationPending else { return false }
            state = .restoring
        }
        restoring = (nonce, action, observed)
        return true
    }

    /// Read-only explanation of the existing callback guards. The mutating
    /// callback above remains the sole authority for transitions/consumption.
    func callbackClassification(nonce: String, action: String, reportedDeadline: String,
                                now: TimeInterval) -> QuietDiagnostics.CallbackClassification {
        guard let p = pending else { return .noPending }
        guard p.nonce == nonce else { return .nonceMismatch }
        guard p.action == action else { return .actionMismatch }
        guard p.expectedDeadline == reportedDeadline else { return .deadlineMismatch }
        guard now.isFinite else { return .invalidClock }
        guard now < p.expiry else { return .callbackWindowElapsed }
        guard action != "begin" || now < deadline else { return .leaseExpired }
        guard (action == "begin" && state == .preparing) ||
              (action == "end" && state == .ending) ||
              (action == "inspect" && state == .restorationPending) else { return .stateMismatch }
        return .accepted
    }

    func matchesCallbackNonce(_ nonce: String) -> Bool {
        pending?.nonce == nonce || restoring?.nonce == nonce
    }

    var restoringAction: String? { restoring?.action }

    public func mayRestore(nonce: String, now: TimeInterval) -> Bool {
        guard let value = restoring, state == .restoring, value.nonce == nonce, now.isFinite else { return false }
        return value.action != "begin" || now < deadline
    }

    @discardableResult public mutating func finishRestoration(nonce: String, succeeded: Bool, now: TimeInterval) -> Bool {
        guard mayRestore(nonce: nonce, now: now), let value = restoring else { return false }
        restoring = nil
        if !succeeded { state = .restorationPending }
        else if value.action == "begin" { state = value.observed == "iCTRL Automation" ? .quietVerified : .failed }
        else if value.action == "end" {
            state = !beginUncertain && (value.observed == "off" || value.observed == "preserved_user_focus") ? .ended : .restorationPending
        } else { state = (value.observed == "off" || value.observed == "preserved_user_focus") ? .ended : .restorationPending }
        return true
    }

    public mutating func gate(tokId: String, session: String?, now: TimeInterval) -> Decision {
        guard now.isFinite else { return .denied("invalid_clock") }
        let endRestoring = state == .restoring && restoring?.action != "begin"
        if now >= deadline && state != .ended && state != .ending && state != .restorationPending && !endRestoring {
            if state == .restoring && restoring?.action == "begin" { beginUncertain = true }
            state = .expired; pending = nil
            restoring = nil
        }
        guard let session else { return .denied("manual_route_required") }
        guard tokId == ownerTokId, session == id else { return .denied("wrong_session") }
        return state == .quietVerified ? .allowed : .denied(state.rawValue)
    }

    public mutating func end(tokId: String, session: String, now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        guard tokId == ownerTokId, session == id else { return false }
        if state == .ended || state == .ending || endAttempted { return false } // idempotent, no second End Shortcut
        if now > deadline + 300 { state = .restorationPending; pending = nil; return false }
        let interruptedBegin = state == .restoring && restoring?.action == "begin"
        let unresolvedBegin = state == .restorationPending
        guard state == .quietVerified || state == .preparing || state == .failed || state == .expired || state == .suspended || interruptedBegin || unresolvedBegin else { return false }
        if state == .preparing || interruptedBegin || unresolvedBegin { beginUncertain = true }
        endAttempted = true
        state = .ending; pending = nil; restoring = nil; return true
    }

    public mutating func suspend() { state = .suspended; pending = nil; restoring = nil }
    public mutating func noteBeginUncertain() { beginUncertain = true }
    public mutating func markRestorationPending() { state = .restorationPending; pending = nil; restoring = nil }
    public mutating func endWithoutLaunchingBegin() {
        guard state == .preparing || state == .failed || state == .expired else { return }
        state = .ended; pending = nil; restoring = nil
    }
    public var hasPendingCallback: Bool { pending != nil }
    public func hasPendingCallback(nonce: String, now: TimeInterval) -> Bool {
        guard let pending, pending.nonce == nonce, now.isFinite, now < pending.expiry else { return false }
        return pending.action != "begin" || now < deadline
    }
    public mutating func failPending(now: TimeInterval) {
        if state == .ending { state = .restorationPending }
        else if now >= deadline { state = .expired }
        else if state == .preparing { state = .failed }
        pending = nil
        restoring = nil
    }
}

public enum LeaseError: Error { case invalid }

/// Pure confirmation policy for Quiet restoration. PID identity must come from
/// the target bundle, never from a learned frontmost-PID/name mapping.
struct QuietForegroundConfirmation {
    enum Outcome: Equatable { case waiting, confirmed, expired }
    private let startedAt: TimeInterval
    private let deadline: TimeInterval
    private let valid: Bool
    private var lastTargetPID: Int32 = 0
    private var lastFrontmostPID: Int32 = 0
    private var matches = 0

    init(startedAt: TimeInterval, budget: TimeInterval) {
        self.startedAt = startedAt
        self.deadline = startedAt + budget
        self.valid = startedAt.isFinite && budget.isFinite && budget > 0 && deadline.isFinite
    }

    func permitsAction(now: TimeInterval) -> Bool {
        valid && now.isFinite && now >= startedAt && now < deadline
    }

    mutating func observe(targetPID: Int32, frontmostPID: Int32, now: TimeInterval) -> Outcome {
        guard permitsAction(now: now) else { return .expired }
        if targetPID != lastTargetPID || frontmostPID != lastFrontmostPID { matches = 0 }
        lastTargetPID = targetPID
        lastFrontmostPID = frontmostPID
        matches = targetPID > 0 && frontmostPID == targetPID ? matches + 1 : 0
        return matches >= 2 ? .confirmed : .waiting
    }
}
