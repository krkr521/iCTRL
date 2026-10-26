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
    }
    public enum Decision: Equatable { case allowed, denied(String) }
    public let ownerTokId: String
    public let id: String
    public let deadline: TimeInterval
    public private(set) var state: State = .preparing
    private var pending: (nonce: String, action: String, expectedDeadline: String, expiry: TimeInterval)?
    private var usedNonces = Set<String>()
    private var beginUncertain = false

    public init(ownerTokId: String, id: String, ttl: TimeInterval, now: TimeInterval) throws {
        guard !ownerTokId.isEmpty, !id.isEmpty, ttl.isFinite, now.isFinite, ttl > 0, ttl <= 300 else { throw LeaseError.invalid }
        self.ownerTokId = ownerTokId; self.id = id; self.deadline = now + ttl
    }

    public mutating func prepareCallback(nonce: String, action: String, expectedDeadline: String, now: TimeInterval) throws {
        guard nonce.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              !expectedDeadline.isEmpty, now.isFinite,
              action == "begin" || action == "end" else { throw LeaseError.invalid }
        guard (action == "begin" && state == .preparing) || (action == "end" && state == .ending) else { throw LeaseError.invalid }
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
            state = observed == "iCTRL Automation" ? .quietVerified : .failed
        } else {
            guard state == .ending else { return false }
            state = !beginUncertain && (observed == "off" || observed == "preserved_user_focus") ? .ended : .restorationPending
        }
        return true
    }

    public mutating func gate(tokId: String, session: String?, now: TimeInterval) -> Decision {
        guard now.isFinite else { return .denied("invalid_clock") }
        if now >= deadline && state != .ended && state != .ending && state != .restorationPending {
            state = .expired; pending = nil
        }
        guard let session else { return .denied("manual_route_required") }
        guard tokId == ownerTokId, session == id else { return .denied("wrong_session") }
        return state == .quietVerified ? .allowed : .denied(state.rawValue)
    }

    public mutating func end(tokId: String, session: String, now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        guard tokId == ownerTokId, session == id else { return false }
        if state == .ended || state == .ending || state == .restorationPending { return false } // idempotent, no second Shortcut
        if now > deadline + 300 { state = .restorationPending; pending = nil; return false }
        guard state == .quietVerified || state == .preparing || state == .failed || state == .expired || state == .suspended else { return false }
        if state == .preparing { beginUncertain = true }
        state = .ending; pending = nil; return true
    }

    public mutating func suspend() { state = .suspended; pending = nil }
    public mutating func markRestorationPending() { state = .restorationPending; pending = nil }
    public mutating func failPending(now: TimeInterval) {
        if state == .ending { state = .restorationPending }
        else if now >= deadline { state = .expired }
        else if state == .preparing { state = .failed }
        pending = nil
    }
}

public enum LeaseError: Error { case invalid }
