import Foundation

/// Local, process-only ownership. No Focus, Shortcuts, Auto-Lock, or shared device settings.
final class NativeAutomationSession {
    struct Lease { let owner: String; let id: String; let deadline: TimeInterval; let wallDeadline: String; let lockGeneration: UInt64; var heartbeat: TimeInterval; var state = "active" }
    private let lock = NSLock()
    private var lease: Lease?
    private var finishRequest: NativeFinishRequest?
    private var finishReservation: NativeFinishReservation?
    private var finishCompleted = false
    func reserveFinish(owner: String, request: NativeFinishRequest, now: TimeInterval) throws -> (NativeFinishReservation, Bool) {
        lock.lock(); defer { lock.unlock() }; expire(now)
        guard !finishInvalidatedByManualTakeover, let value = lease, value.owner == owner, value.id == request.leaseID else { throw Failure.invalid }
        if let previous = finishRequest {
            guard previous == request, let reservation = finishReservation else { throw Failure.invalid }
            return (reservation, false)
        }
        let deadline = request.policy == "return_chat" && value.state == "active" ? min(min(value.deadline, value.heartbeat), now + 8) : nil
        let reservation = NativeFinishReservation(id: UUID().uuidString, owner: owner, request: request, deadline: deadline)
        finishRequest = request; finishReservation = reservation
        return (reservation, true)
    }
    func mayHandoff(_ reservation: NativeFinishReservation, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }; expire(now)
        guard finishReservation == reservation, !finishCompleted, !finishInvalidatedByManualTakeover,
              lease?.state == "active", let deadline = reservation.deadline, now < deadline else { return false }
        return true
    }
    func reservationCurrent(_ reservation: NativeFinishReservation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return finishReservation == reservation && !finishInvalidatedByManualTakeover
    }
    func completeFinish(_ reservation: NativeFinishReservation, now: TimeInterval) throws -> [String: JSONValue] {
        lock.lock(); defer { lock.unlock() }; expire(now)
        guard finishReservation == reservation, !finishInvalidatedByManualTakeover,
              var value = lease, value.owner == reservation.owner, value.id == reservation.request.leaseID else { throw Failure.invalid }
        value.state = "ended"; lease = value; finishCompleted = true; return values(value)
    }
    /// Explicit manual takeover supersedes the old task's authority to stop the service.
    /// Expiry and lock/health revocation deliberately do not set this tombstone.
    private var finishInvalidatedByManualTakeover = false
    var hasPendingFinish: Bool { lock.lock(); defer { lock.unlock() }; return finishReservation != nil && !finishCompleted && !finishInvalidatedByManualTakeover }
    var isFinishing: Bool { lock.lock(); defer { lock.unlock() }; return finishRequest != nil }
    /// A finishing server never admits another lease, even after End/expiry.
    func finish(owner: String, request: NativeFinishRequest, now: TimeInterval) throws -> (values: [String: JSONValue], first: Bool) {
        lock.lock(); defer { lock.unlock() }; expire(now)
        guard !finishInvalidatedByManualTakeover, var value = lease, value.owner == owner, value.id == request.leaseID else { throw Failure.invalid }
        if let previous = finishRequest {
            guard previous == request else { throw Failure.invalid }
            if finishCompleted { return (values(value), false) }
        }
        value.state = "ended"; lease = value; finishRequest = request; finishCompleted = true
        return (values(value), true)
    }
    private func expire(_ now: TimeInterval) {
        guard var value = lease, value.state == "active" else { return }
        if !now.isFinite || now >= value.deadline || now >= value.heartbeat {
            value.state = "expired"; lease = value
        }
    }
    func begin(owner: String, id: String, ttl: Int, now: TimeInterval, date: Date, lockGeneration: UInt64 = 0) throws -> [String: JSONValue] {
        lock.lock(); defer { lock.unlock() }; expire(now)
        guard now.isFinite, !owner.isEmpty, !id.isEmpty, (1...300).contains(ttl) else { throw Failure.invalid }
        guard finishRequest == nil, lease?.state != "active" else { throw Failure.busy }
        finishInvalidatedByManualTakeover = false
        lease = Lease(owner: owner, id: id, deadline: now + Double(ttl),
                      wallDeadline: ISO8601DateFormatter().string(from: date.addingTimeInterval(Double(ttl))), lockGeneration: lockGeneration, heartbeat: now + 15)
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
    func revokeForManualTakeover() {
        lock.lock(); defer { lock.unlock() }
        guard lease != nil else { return }
        lease?.state = "ended"
        finishInvalidatedByManualTakeover = true
        finishRequest = nil; finishReservation = nil; finishCompleted = false
    }
    func revoke() { lock.lock(); defer { lock.unlock() }; if lease != nil { lease!.state = "ended" } }
    func revoke(id: String) {
        lock.lock(); defer { lock.unlock() }
        if lease?.id == id { lease?.state = "ended" }
    }
    /// A delayed invalidation must not revoke a newer Begin from a recovered epoch.
    func revoke(beforeLockGeneration generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if let value = lease, value.lockGeneration < generation { lease?.state = "ended" }
    }
    func active(now: TimeInterval) -> Lease? {
        lock.lock(); defer { lock.unlock() }; expire(now)
        return lease?.state == "active" ? lease : nil
    }
    func authorizedLease(owner: String, id: String?, now: TimeInterval) -> Lease? {
        lock.lock(); defer { lock.unlock() }; expire(now)
        guard let value = lease, value.owner == owner, value.id == id, value.state == "active" else { return nil }
        return value
    }
    func gate(owner: String, id: String?, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }; expire(now)
        return finishRequest == nil && lease?.owner == owner && lease?.id == id && lease?.state == "active"
    }
    private func values(_ value: Lease) -> [String: JSONValue] {
        ["mode": .string("automation"), "backend": .string("native"), "lease_id": .string(value.id),
         "state": .string(value.state), "deadline": .string(value.wallDeadline),
         "heartbeat_interval_seconds": .int(5), "notification_suppression": .bool(false)]
    }
    enum Failure: Error { case invalid, busy }
}

/// Only this fixed local route is admitted for an explicit owner cleanup.
struct NativeFinishRequest: Equatable {
    let leaseID: String
    let policy: String
    let originSessionID: String?
    init?(params: [String: JSONValue]) {
        guard Set(params.keys).isSubset(of: ["lease_id", "completion_policy", "origin_session_id", "stop_service"]),
              let id = params["lease_id"]?.stringValue, !id.isEmpty,
              params["stop_service"]?.boolValue == true,
              let policy = params["completion_policy"]?.stringValue,
              ["return_chat", "stay", "skip_unknown"].contains(policy) else { return nil }
        if policy == "return_chat" {
            guard let origin = params["origin_session_id"]?.stringValue,
                  origin.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { return nil }
            originSessionID = origin
        } else {
            guard params["origin_session_id"] == nil else { return nil }
            originSessionID = nil
        }
        leaseID = id; self.policy = policy
    }
    var returnURL: URL? {
        guard let originSessionID else { return nil }
        var components = URLComponents(); components.scheme = "minis"; components.host = "sessions"
        components.path = "/" + originSessionID; return components.url
    }
}

struct NativeFinishReservation: Equatable {
    let id: String
    let owner: String
    let request: NativeFinishRequest
    let deadline: TimeInterval?
}

struct MinisHandoffOutcome {
    let state: String
    let dispatched: Bool
    let foregroundConfirmed: Bool
    init(_ state: String, dispatched: Bool = false, foregroundConfirmed: Bool = false) {
        self.state = state; self.dispatched = dispatched; self.foregroundConfirmed = foregroundConfirmed
    }
}
