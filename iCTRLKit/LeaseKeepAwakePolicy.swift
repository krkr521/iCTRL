import Foundation

/// Monotonic, fail-closed admission for one pulse at a time. No device APIs.
struct LeaseKeepAwakePolicy {
    struct Lease: Equatable {
        let id: String
        let deadline: TimeInterval
    }
    static let interval: TimeInterval = 10
    private var current: String?
    private var blocked = Set<String>()
    private var nextPulse: TimeInterval = 0
    private var lastNow: TimeInterval?

    /// Only the server may supply a lease, after owner, session, and heartbeat checks.
    /// Revocation latches the old ID so a stale snapshot cannot restart it.
    mutating func admit(_ lease: Lease?, locked: Bool, now: TimeInterval) -> Bool {
        guard now.isFinite else { stop(); return false }
        if let previous = lastNow, now < previous { stop(); return false }
        lastNow = now
        guard let lease, !lease.id.isEmpty, lease.deadline.isFinite, now < lease.deadline else {
            stop(); return false
        }
        if let current, current != lease.id { blocked.insert(current) }
        if current != lease.id { current = lease.id; nextPulse = now }
        if locked { blocked.insert(lease.id) }
        guard !blocked.contains(lease.id), now >= nextPulse else { return false }
        // Schedule from actual admission; never replay a backlog after a long UI action.
        nextPulse = now + Self.interval
        return true
    }

    mutating func fail() { if let current { blocked.insert(current) } }
    mutating func stop() {
        if let current { blocked.insert(current) }
        current = nil
    }
}
