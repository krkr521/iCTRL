import Foundation

/// Owned by the runner. Snapshot reads must be thread-safe and side-effect free.
/// The snapshot is authority, never this timer: return nil after stop, disconnect,
/// heartbeat loss, expiry, revocation, or abnormal task termination.
final class LeaseKeepAwake {
    typealias Lease = LeaseKeepAwakePolicy.Lease
    private let queue: DispatchQueue
    private let snapshot: () -> Lease?
    private let isLocked: () -> Bool
    private let pulse: () -> String?
    private let log: (String) -> Void
    private var timer: DispatchSourceTimer?
    private var policy = LeaseKeepAwakePolicy()
    private var observedLease: String?
    private var reportedPulse = false
    private var reportedStop = false
    private let lifecycleLock = NSLock()
    private var generation: UInt64 = 0

    init(queue: DispatchQueue, snapshot: @escaping () -> Lease?,
         isLocked: @escaping () -> Bool, pulse: @escaping () -> String?,
         log: @escaping (String) -> Void = { _ in }) {
        self.queue = queue; self.snapshot = snapshot; self.isLocked = isLocked
        self.pulse = pulse; self.log = log
    }

    /// Use the existing serial UI RPC queue, never a concurrent dispatch lane.
    func start() {
        lifecycleLock.lock(); generation &+= 1; let ticket = generation; lifecycleLock.unlock()
        queue.async { [weak self] in
            guard let self, self.isCurrent(ticket) else { return }
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            // One polling event maximum is pending; blocked UI work does not accumulate pulses.
            timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick(ticket) }
            self.timer = timer; timer.resume()
        }
    }

    /// Synchronously invalidates queued work; cleanup itself runs on the UI queue.
    func stop() {
        lifecycleLock.lock(); generation &+= 1; lifecycleLock.unlock()
        queue.async { [weak self] in
            self?.timer?.cancel(); self?.timer = nil; self?.policy.stop()
        }
    }

    private func isCurrent(_ ticket: UInt64) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return generation == ticket
    }

    private func tick(_ ticket: UInt64) {
        guard isCurrent(ticket) else { return }
        let lease = snapshot()
        if observedLease != lease?.id {
            if observedLease != nil { log("F13 keep-awake lease no longer authorized") }
            observedLease = lease?.id; reportedPulse = false; reportedStop = false
        }
        let locked = isLocked()
        if locked, lease != nil, !reportedStop {
            reportedStop = true; log("F13 keep-awake stopped for this lease (locked or unknown lock state)")
        }
        guard policy.admit(lease, locked: locked, now: ProcessInfo.processInfo.systemUptime) else { return }
        var failure: String?
        var performed = false
        // Same main-thread lane as UI actions. Recheck after waiting for main.
        DispatchQueue.main.sync {
            guard self.isCurrent(ticket), let lease, self.snapshot() == lease,
                  ProcessInfo.processInfo.systemUptime < lease.deadline else { return }
            guard !self.isLocked() else { failure = "locked"; return }
            performed = true
            failure = self.pulse()
        }
        if failure != nil {
            policy.fail()
            // Never include a device exception, token, app name, or lease ID.
            reportedStop = true
            log("F13 keep-awake stopped for this lease (locked or pulse unavailable)")
        } else if performed, !reportedPulse {
            reportedPulse = true; log("F13 keep-awake first event accepted (device effect unverified)")
        }
    }

    deinit { timer?.cancel() }
}
