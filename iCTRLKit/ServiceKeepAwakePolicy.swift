import Foundation

/// Service authorization is independent of UI ownership, TTL and network heartbeats.
final class ServiceKeepAwakeAuthorization {
    typealias Source = ServiceKeepAwakePolicy.Source
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var starting = false
    private var running = false
    private var failedSource: Source?

    func prepareStart() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard epoch < .max else { return nil }
        epoch += 1; starting = true; running = false; failedSource = nil
        return epoch
    }
    @discardableResult func ready(ticket: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ticket == epoch, starting || running else { return false }
        starting = false; running = true; return true
    }
    /// Invalidates a queued listener callback or pulse synchronously.
    @discardableResult func stop(ticket: UInt64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let ticket, ticket != epoch { return false }
        if epoch < .max { epoch += 1 }
        starting = false; running = false; failedSource = nil; return true
    }
    func source(lockGeneration: UInt64) -> Source? {
        lock.lock(); defer { lock.unlock() }
        guard running else { return nil }
        let source = Source(serviceEpoch: epoch, lockGeneration: lockGeneration)
        return failedSource == source ? nil : source
    }
    func failed(_ source: Source) {
        lock.lock(); defer { lock.unlock() }
        if running, epoch == source.serviceEpoch {
            if let failedSource, source < failedSource { return }
            failedSource = source
        }
    }
    func state(readiness: NativeDeviceReadiness) -> String {
        lock.lock(); defer { lock.unlock() }
        if starting { return "starting" }
        guard running else { return "stopped" }
        if let reason = readiness.reason { return "paused_" + reason.rawValue }
        let current = Source(serviceEpoch: epoch, lockGeneration: readiness.lockGeneration)
        return failedSource == current ? "event_failed" : "ready"
    }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
}

/// No catch-up bursts. Source changes permit recovery, but never revive a stale source.
struct ServiceKeepAwakePolicy {
    struct Source: Equatable, Comparable {
        let serviceEpoch: UInt64
        let lockGeneration: UInt64
        static func < (a: Source, b: Source) -> Bool {
            a.serviceEpoch == b.serviceEpoch ? a.lockGeneration < b.lockGeneration : a.serviceEpoch < b.serviceEpoch
        }
    }
    static let interval: TimeInterval = 10
    private var current: Source?
    private var blocked = false
    private var nextPulse = -TimeInterval.infinity
    private var lastNow: TimeInterval?

    mutating func admit(_ source: Source?, now: TimeInterval) -> Bool {
        guard now.isFinite else { stop(); return false }
        if let lastNow, now < lastNow { stop(); return false }
        lastNow = now
        guard let source else { stop(); return false }
        if let current, source < current { return false }
        if current != source { current = source; blocked = false }
        guard !blocked, now >= nextPulse else { return false }
        nextPulse = now + Self.interval
        return true
    }
    mutating func fail() { blocked = true }
    mutating func stop() { blocked = true }
}
