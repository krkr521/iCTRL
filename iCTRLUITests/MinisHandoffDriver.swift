import Foundation
import XCTest

/// Uses the existing URL backends, asynchronously and at most once. The main
/// event loop stays free; a missing callback cannot retain the service forever.
final class MinisHandoffDriver {
    private let queue: DispatchQueue
    private let reservation: NativeFinishReservation
    private let authorize: () -> Bool
    private let completion: (MinisHandoffOutcome) -> Void
    private var policy: MinisHandoffPolicy
    // Minis owns the fixed minis:// route used by this protocol. Its installed
    // bundle identity is confirmed by device page_source evidence. Installation
    // enumeration is unavailable on some iOS versions and is not URL admission.
    private let targetBundleID = "com.openminis.app"
    private var observationInFlight = false
    private var deliveryAccepted = false
    private var timer: DispatchSourceTimer?
    private let lifecycleLock = NSLock()
    private var finished = false
    private var sent = false

    init(queue: DispatchQueue, reservation: NativeFinishReservation, authorize: @escaping () -> Bool,
         completion: @escaping (MinisHandoffOutcome) -> Void) {
        self.queue = queue; self.reservation = reservation; self.authorize = authorize; self.completion = completion
        policy = MinisHandoffPolicy(deadline: reservation.deadline ?? 0)
    }
    func start() {
        guard let route = reservation.request.returnURL,
              policy.admitDispatch(authorized: authorize(), now: ProcessInfo.processInfo.systemUptime) else {
            finish("cancelled"); return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.15, repeating: 0.15, leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPending(), self.authorize() else { return }
            var blocked = true
            let exception = ObjCException.catching {
                blocked = ActionHandler.springboardHasAlert()
            }
            if exception != nil {
                iCTRLUITests.logBuffer.append("Minis handoff initial_probe_exception")
                self.queue.async { self.finish("unavailable") }; return
            }
            if blocked { self.queue.async { self.finish("blocked_alert") }; return }
            guard self.isPending(), self.authorize() else { return }
            self.lifecycleLock.lock(); self.sent = true; self.lifecycleLock.unlock()
            ForegroundApp.openURLOnce(route, authorize: { [weak self] in
                guard let self else { return false }; return self.isPending() && self.authorize()
            }, completion: { [weak self] accepted in
                self?.queue.async {
                    guard let self, self.isPending() else { return }
                    if accepted { self.deliveryAccepted = true }
                    else {
                        iCTRLUITests.logBuffer.append("Minis handoff url_backend_refused")
                        self.finish("unavailable")
                    }
                }
            })
        }
    }
    private func isPending() -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return !finished
    }
    private func tick() {
        guard isPending() else { return }
        if let terminal = policy.terminal(authorized: authorize(), now: ProcessInfo.processInfo.systemUptime) {
            finish(terminal); return
        }
        guard !observationInFlight else { return }
        observationInFlight = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPending() else { return }
            guard self.authorize() else { self.queue.async { self.finish("cancelled") }; return }
            var alert = true; var foreground = false
            let exception = ObjCException.catching {
                alert = ActionHandler.springboardHasAlert()
                let named = ForegroundApp.processID(forBundleID: self.targetBundleID)
                foreground = named > 0 && ForegroundApp.frontmostPID() == named
            }
            self.queue.async {
                self.observationInFlight = false
                guard self.isPending() else { return }
                if exception != nil {
                    iCTRLUITests.logBuffer.append("Minis handoff foreground_probe_exception")
                    self.finish("unavailable"); return
                }
                if let terminal = self.policy.observe(authorized: self.authorize(), now: ProcessInfo.processInfo.systemUptime,
                                                       alert: alert, foreground: self.deliveryAccepted && foreground) { self.finish(terminal) }
            }
        }
    }
    private func finish(_ state: String) {
        lifecycleLock.lock()
        guard !finished else { lifecycleLock.unlock(); return }
        finished = true; let sent = self.sent; lifecycleLock.unlock()
        timer?.cancel(); timer = nil
        iCTRLUITests.logBuffer.append("Minis handoff terminal=\(state) dispatched=\(sent)")
        completion(.init(state, dispatched: sent, foregroundConfirmed: state == "app_confirmed"))
    }
    deinit { timer?.cancel() }
}
