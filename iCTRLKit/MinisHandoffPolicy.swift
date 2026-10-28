import Foundation

/// Bounded observation only. No generic alert response or new UI lease.
struct MinisHandoffPolicy {
    let deadline: TimeInterval
    private(set) var dispatched = false
    private var foregroundSamples = 0
    private var lastNow: TimeInterval?
    init(deadline: TimeInterval) { self.deadline = deadline }
    mutating func admitDispatch(authorized: Bool, now: TimeInterval) -> Bool {
        guard !dispatched, terminal(authorized: authorized, now: now) == nil else { return false }
        dispatched = true; return true
    }
    mutating func terminal(authorized: Bool, now: TimeInterval) -> String? {
        guard now.isFinite, deadline.isFinite, now < deadline else { return "timeout" }
        if let lastNow, now < lastNow { return "timeout" }
        guard authorized else { return "cancelled" }
        lastNow = now; return nil
    }
    mutating func observe(authorized: Bool, now: TimeInterval, alert: Bool, foreground: Bool) -> String? {
        if let terminal = terminal(authorized: authorized, now: now) { return terminal }
        guard dispatched else { return "unavailable" }
        if alert { return "blocked_alert" }
        foregroundSamples = foreground ? foregroundSamples + 1 : 0
        return foregroundSamples >= 2 ? "app_confirmed" : nil
    }
}
