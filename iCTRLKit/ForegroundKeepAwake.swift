import Foundation
import UIKit

/// UIKit's idle-timer assertion is scoped to the foreground app. It is NOT a
/// system Auto-Lock setting and cannot keep other foreground apps awake.
final class ForegroundKeepAwake {
    static let shared = ForegroundKeepAwake()
    private let lock = NSLock()
    private var serviceRunning = false
    private var configured = UserDefaults.standard.object(forKey: "keepAwakeWhileServing") as? Bool ?? true
    private var foreground = false
    private var activeAssertion = false
    private var installed = false
    private var previousIdleTimerDisabled: Bool?

    func setServiceRunning(_ running: Bool) {
        DispatchQueue.main.async { self.serviceRunning = running; self.apply() }
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock(); configured = enabled; lock.unlock()
        UserDefaults.standard.set(enabled, forKey: "keepAwakeWhileServing")
        DispatchQueue.main.async { self.apply() }
    }

    func install() {
        DispatchQueue.main.async {
            guard !self.installed else { return }
            self.installed = true
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in self.apply() }
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in self.apply(foregroundOverride: false) }
            self.apply()
        }
    }

    private func apply(foregroundOverride: Bool? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let inFront = foregroundOverride ?? (UIApplication.shared.applicationState == .active)
        lock.lock()
        let desired = configured && serviceRunning && inFront
        foreground = inFront
        activeAssertion = desired
        lock.unlock()
        if desired {
            if previousIdleTimerDisabled == nil { previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled }
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let previous = previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previous
            previousIdleTimerDisabled = nil
        }
    }

    func snapshot() -> [String: JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return ["keep_awake_enabled": .bool(configured), "keep_awake_scope": .string("foreground_app_only"),
                "runner_foreground": .bool(foreground), "idle_timer_assertion_active": .bool(activeAssertion),
                "cross_app_auto_lock_prevention": .bool(false)]
    }
}
