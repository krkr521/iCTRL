import Foundation

/// Local, process-only ownership. No Focus, Shortcuts, Auto-Lock, or shared device settings.
final class NativeAutomationSession {
    struct Lease { let owner: String; let id: String; let deadline: TimeInterval; let wallDeadline: String; var heartbeat: TimeInterval; var state = "active" }
    private let lock = NSLock()
    private var lease: Lease?
    private func expire(_ now: TimeInterval) {
        guard var value = lease, value.state == "active" else { return }
        if !now.isFinite || now >= value.deadline || now >= value.heartbeat {
            value.state = "expired"; lease = value
        }
    }
    func begin(owner: String, id: String, ttl: Int, now: TimeInterval, date: Date) throws -> [String: JSONValue] {
        lock.lock(); defer { lock.unlock() }; expire(now)
        guard now.isFinite, !owner.isEmpty, !id.isEmpty, (1...300).contains(ttl) else { throw Failure.invalid }
        guard lease?.state != "active" else { throw Failure.busy }
        lease = Lease(owner: owner, id: id, deadline: now + Double(ttl),
                      wallDeadline: ISO8601DateFormatter().string(from: date.addingTimeInterval(Double(ttl))), heartbeat: now + 15)
        return values(lease!)
    }
    func status(owner: String, id: String? = nil, now: TimeInterval) -> [String: JSONValue]? {
        lock.lock(); defer { lock.unlock() }; expire(now)
        guard let value = lease, value.owner == owner, id == nil || id == value.id else { return nil }
        return values(value)
    }
    func heartbeat(owner: String, id: String, now: TimeInterval) throws -> [String: JSONValue] {
        lock.lock(); defer { lock.unlock() }; expire(now)
        guard var value = lease, value.owner == owner, value.id == id, value.state == "active" else { throw Failure.invalid }
        value.heartbeat = min(value.deadline, now + 15); lease = value; return values(value)
    }
    func end(owner: String, id: String, now: TimeInterval) throws -> [String: JSONValue] {
        lock.lock(); defer { lock.unlock() }; expire(now)
        guard var value = lease, value.owner == owner, value.id == id else { throw Failure.invalid }
        value.state = "ended"; lease = value; return values(value)
    }
    func revoke() { lock.lock(); defer { lock.unlock() }; if lease != nil { lease!.state = "ended" } }
    func active(now: TimeInterval) -> Lease? {
        lock.lock(); defer { lock.unlock() }; expire(now)
        return lease?.state == "active" ? lease : nil
    }
    func gate(owner: String, id: String?, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }; expire(now)
        return lease?.owner == owner && lease?.id == id && lease?.state == "active"
    }
    private func values(_ value: Lease) -> [String: JSONValue] {
        ["mode": .string("automation"), "backend": .string("native"), "lease_id": .string(value.id),
         "state": .string(value.state), "deadline": .string(value.wallDeadline),
         "heartbeat_interval_seconds": .int(5), "notification_suppression": .bool(false)]
    }
    enum Failure: Error { case invalid, busy }
}
