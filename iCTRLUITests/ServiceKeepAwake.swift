import Foundation

/// One scheduler for the user-started runner service. It grants no UI control.
final class ServiceKeepAwake {
    typealias Source = ServiceKeepAwakePolicy.Source
    private let queue: DispatchQueue
    private let snapshot: () -> Source?
    private let pulse: (Source) -> String?
    private let log: (String) -> Void
    private var timer: DispatchSourceTimer?
    private var policy = ServiceKeepAwakePolicy()
    private var observed: Source?
    private var reportedPulse = false
    private let lifecycleLock = NSLock()
    private var generation: UInt64 = 0

    init(queue: DispatchQueue, snapshot: @escaping () -> Source?,
         pulse: @escaping (Source) -> String?, log: @escaping (String) -> Void = { _ in }) {
        self.queue = queue; self.snapshot = snapshot; self.pulse = pulse; self.log = log
    }
    func start() {
        lifecycleLock.lock(); generation &+= 1; let ticket = generation; lifecycleLock.unlock()
        queue.async { [weak self] in
            guard let self, self.isCurrent(ticket) else { return }
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick(ticket) }
            self.timer = timer; timer.resume()
        }
    }
    func stop() {
        lifecycleLock.lock(); generation &+= 1; let ticket = generation; lifecycleLock.unlock()
        queue.async { [weak self] in
            guard let self, self.isCurrent(ticket) else { return }
            self.timer?.cancel(); self.timer = nil; self.policy.stop()
            if self.observed != nil { self.log("F13 service keep-awake stopped") }
            self.observed = nil
        }
    }
    private func isCurrent(_ ticket: UInt64) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return generation == ticket
    }
    private func tick(_ ticket: UInt64) {
        guard isCurrent(ticket) else { return }
        let source = snapshot()
        if observed != source {
            if observed != nil { log("F13 service source paused or replaced") }
            observed = source; reportedPulse = false
        }
        guard policy.admit(source, now: ProcessInfo.processInfo.systemUptime), let source else { return }
        var failure: String?
        var performed = false
        // Same serial UI queue and main thread as actions; no concurrent gesture lane.
        DispatchQueue.main.sync {
            guard self.isCurrent(ticket), self.snapshot() == source else { return }
            performed = true
            failure = self.pulse(source) // rechecks service + fresh lock immediately before event
        }
        if failure != nil {
            policy.fail(); log("F13 service source stopped after an event/admission failure")
        } else if performed, !reportedPulse {
            reportedPulse = true; log("F13 service first event accepted (device effect requires verification)")
        }
    }
    deinit { timer?.cancel() }
}
