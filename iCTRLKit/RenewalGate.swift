import Foundation

struct RenewalProfileSnapshot: Codable, Equatable {
    let companionExpiry: Date
    let runnerExpiry: Date
    let companionBundleID: String
    let runnerBundleID: String
    let companionTeam: String?
    let runnerTeam: String?
    let observedAt: Date
    let runnerVerified: Bool

    func isFresh(at now: Date) -> Bool {
        runnerVerified && !companionBundleID.isEmpty && !runnerBundleID.isEmpty
            && observedAt <= now.addingTimeInterval(60) && observedAt >= now.addingTimeInterval(-120)
    }

    func sameIdentity(as other: Self) -> Bool {
        companionBundleID == other.companionBundleID && runnerBundleID == other.runnerBundleID
            && companionTeam == other.companionTeam && runnerTeam == other.runnerTeam
    }
}

struct RenewalGateReceipt: Equatable {
    let attemptID: String
    let completedAt: Date
}

/// Phone-local cadence and durable reservation, with no UIKit, network or
/// signing APIs. AppIntents obtain real profile snapshots outside this core.
struct RenewalGateState: Codable, Equatable {
    enum Phase: String, Codable { case preparing, refreshing, verifying
        case checkingBefore = "checking_before"
        case awaitingRestore = "awaiting_restore" }
    enum Outcome: String, Codable { case skipped, failed, success }
    struct Attempt: Codable, Equatable {
        let id: String
        let startedAt: Date
        var phase: Phase = .preparing
        var refreshStartedAt: Date?
        var before: RenewalProfileSnapshot?
        var outcome: Outcome?
    }
    var schemaVersion = 1
    var lastSuccessAt: Date?
    var lastObservedProfiles: RenewalProfileSnapshot?
    var initialDueAt: Date?
    var active: Attempt?
    var lastRefreshDay: String?
    var retryAfter: Date?
    var lastFailureAt: Date?
    var lastFailureReason: String?

    static let recoveryAge: TimeInterval = 10 * 60
    static let retryDelay: TimeInterval = 12 * 60 * 60
    static let minimumNewValidity: TimeInterval = 6 * 24 * 60 * 60
    static let initialLead: TimeInterval = 2 * 24 * 60 * 60

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func nextDue(calendar: Calendar) -> Date? {
        // Calendar days keep a daily 21:00 check on day five even if the prior
        // renewal finished at 21:02. lastSuccessAt keeps the actual finish time.
        if let success = lastSuccessAt {
            return calendar.date(byAdding: .day, value: 5, to: calendar.startOfDay(for: success))
        }
        return initialDueAt
    }

    private static func errorMessage(_ reason: String) -> String {
        switch reason {
        case "clock_moved_backwards": return "手机时间早于上次验证时间，自动重签已暂停，请检查日期与时间。"
        case "fresh_profile_unavailable", "fresh_profile_or_identity_unavailable": return "无法读取同一签名应用的最新有效期，本次未记录重签成功。"
        case "profiles_not_extended": return "两份应用的有效期没有同时延长，本次未记录重签成功。"
        case "new_validity_too_short": return "重签后的有效期不足六天，本次未记录成功。"
        case "receipt_missing_or_stale": return "缺少本次重签的有效回执，本次未记录成功。"
        case "interrupted_attempt_recovered": return "上次重签流程中断，已完成恢复步骤；下次每日检查会再试。"
        case "attempt_still_active": return "重签任务仍在进行，暂未清除恢复保护。"
        default: return "重签任务状态不匹配，本次未写入成功记录。"
        }
    }

    private func report(now: Date, calendar: Calendar, ok: Bool = true, reason: String = "", nextAction: String = "idle", authorized: Bool = false, notificationKind: String? = nil, notificationMessage: String? = nil) -> [String: JSONValue] {
        let due = nextDue(calendar: calendar)
        let recovery = active.map { $0.phase == .awaitingRestore || now.timeIntervalSince($0.startedAt) >= Self.recoveryAge } ?? false
        func date(_ value: Date?) -> JSONValue { value.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null }
        return ["ok": .bool(ok), "status": .string(active?.phase.rawValue ?? "idle"),
                "next_action": .string(nextAction), "should_prepare": .bool(nextAction == "prepare"),
                "due": .bool(due.map { now >= $0 } ?? false), "pending": .bool(active != nil),
                "recovery_required": .bool(recovery), "prepare_token": .string(active?.id ?? ""),
                "attempt_id": .string(authorized ? (active?.id ?? "") : ""),
                "reason": .string(reason),
                "notification_kind": .string(notificationKind ?? (ok ? "none" : "error")),
                "notification_message": .string(notificationMessage ?? (ok ? "" : Self.errorMessage(reason))),
                "last_success_at": date(lastSuccessAt), "next_due_at": date(due),
                "last_failure_at": date(lastFailureAt), "last_failure_reason": .string(lastFailureReason ?? ""),
                "baseline_observed_at": date(lastObservedProfiles?.observedAt),
                "baseline_companion_expires_at": date(lastObservedProfiles?.companionExpiry),
                "baseline_runner_expires_at": date(lastObservedProfiles?.runnerExpiry),
                "cadence": .string("five_local_calendar_days")]
    }

    mutating func plan(now: Date, reserveIfDue: Bool, calendar: Calendar, newID: UUID = UUID()) -> [String: JSONValue] {
        if let current = active {
            let restore = current.phase == .awaitingRestore || now.timeIntervalSince(current.startedAt) >= Self.recoveryAge
            return report(now: now, calendar: calendar, reason: restore ? "restore_pending" : "attempt_in_progress", nextAction: restore ? "restore" : "idle")
        }
        if let success = lastSuccessAt, success > now.addingTimeInterval(300) {
            return report(now: now, calendar: calendar, ok: false, reason: "clock_moved_backwards")
        }
        if lastRefreshDay == Self.dayKey(now, calendar: calendar) {
            return report(now: now, calendar: calendar, reason: "already_refreshed_today")
        }
        if let retryAfter, now < retryAfter { return report(now: now, calendar: calendar, reason: "retry_cooldown") }
        let needsBaseline = lastSuccessAt == nil && initialDueAt == nil
        let due = nextDue(calendar: calendar).map { now >= $0 } ?? false
        guard reserveIfDue && (needsBaseline || due) else {
            return report(now: now, calendar: calendar, reason: needsBaseline ? "baseline_needed" : (due ? "due" : "not_due"))
        }
        active = Attempt(id: newID.uuidString, startedAt: now)
        return report(now: now, calendar: calendar, reason: needsBaseline ? "baseline_needed" : "due", nextAction: "prepare")
    }

    /// Observation-only bootstrap after a fresh authenticated local profile read.
    /// Never reserves work or changes success/refresh/cooldown history. In
    /// particular, prepare called by Begin must not race its checkingBefore claim.
    @discardableResult
    mutating func observeInitialProfiles(_ snapshot: RenewalProfileSnapshot, now: Date) -> Bool {
        guard active == nil, lastSuccessAt == nil, lastObservedProfiles == nil, initialDueAt == nil,
              now.timeIntervalSinceReferenceDate.isFinite,
              snapshot.companionExpiry.timeIntervalSinceReferenceDate.isFinite,
              snapshot.runnerExpiry.timeIntervalSinceReferenceDate.isFinite,
              snapshot.observedAt.timeIntervalSinceReferenceDate.isFinite,
              snapshot.isFresh(at: now), snapshot.companionExpiry > now, snapshot.runnerExpiry > now,
              snapshot.companionBundleID != snapshot.runnerBundleID,
              let team = snapshot.companionTeam, team == snapshot.runnerTeam,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return false }
        for bundle in [snapshot.companionBundleID, snapshot.runnerBundleID] {
            guard bundle.utf8.count <= 255,
                  bundle.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else { return false }
        }
        lastObservedProfiles = snapshot
        initialDueAt = min(snapshot.companionExpiry, snapshot.runnerExpiry).addingTimeInterval(-Self.initialLead)
        return true
    }

    mutating func claimBefore(token: String, now: Date, calendar: Calendar) -> [String: JSONValue] {
        guard let id = UUID(uuidString: token)?.uuidString, active?.id == id else { return report(now: now, calendar: calendar, ok: false, reason: "attempt_mismatch") }
        guard active?.phase == .preparing else { return report(now: now, calendar: calendar, ok: false, reason: "attempt_not_preparing") }
        active?.phase = .checkingBefore
        return report(now: now, calendar: calendar)
    }

    private mutating func fail(_ reason: String, now: Date) {
        active?.phase = .awaitingRestore
        active?.outcome = .failed
        lastFailureAt = now
        lastFailureReason = reason
        // Anchor to the ORIGINAL attempt. Recovery tomorrow must not delay a
        // legitimate next-day retry by another twelve hours.
        retryAfter = active.map { $0.startedAt.addingTimeInterval(Self.retryDelay) }
    }

    mutating func begin(token: String, snapshot: RenewalProfileSnapshot?, now: Date, calendar: Calendar) -> [String: JSONValue] {
        guard let id = UUID(uuidString: token)?.uuidString, active?.id == id, active?.phase == .checkingBefore else { return report(now: now, calendar: calendar, ok: false, reason: "attempt_mismatch") }
        guard let snapshot, snapshot.isFresh(at: now), snapshot.companionExpiry > now, snapshot.runnerExpiry > now else {
            fail("fresh_profile_unavailable", now: now)
            return report(now: now, calendar: calendar, ok: false, reason: "fresh_profile_unavailable", nextAction: "restore")
        }
        lastObservedProfiles = snapshot
        if lastSuccessAt == nil { initialDueAt = min(snapshot.companionExpiry, snapshot.runnerExpiry).addingTimeInterval(-Self.initialLead) }
        guard let due = nextDue(calendar: calendar), now >= due else {
            active?.phase = .awaitingRestore; active?.outcome = .skipped
            return report(now: now, calendar: calendar, reason: "not_due", nextAction: "restore")
        }
        guard lastRefreshDay != Self.dayKey(now, calendar: calendar) else {
            active?.phase = .awaitingRestore; active?.outcome = .skipped
            return report(now: now, calendar: calendar, reason: "already_refreshed_today", nextAction: "restore")
        }
        active?.before = snapshot
        active?.refreshStartedAt = now
        active?.phase = .refreshing
        lastRefreshDay = Self.dayKey(now, calendar: calendar)
        retryAfter = nil
        return report(now: now, calendar: calendar, authorized: true)
    }

    mutating func claimVerification(token: String, now: Date, calendar: Calendar) -> [String: JSONValue] {
        guard let id = UUID(uuidString: token)?.uuidString, active?.id == id, active?.phase == .refreshing else { return report(now: now, calendar: calendar, ok: false, reason: "attempt_mismatch") }
        active?.phase = .verifying
        return report(now: now, calendar: calendar)
    }

    mutating func finalize(token: String, snapshot: RenewalProfileSnapshot?, receipt: RenewalGateReceipt?, now: Date, calendar: Calendar) -> [String: JSONValue] {
        guard let id = UUID(uuidString: token)?.uuidString, let attempt = active,
              attempt.id == id, attempt.phase == .verifying,
              let started = attempt.refreshStartedAt, let before = attempt.before else { return report(now: now, calendar: calendar, ok: false, reason: "attempt_mismatch") }
        let failure: String?
        if let receipt, UUID(uuidString: receipt.attemptID)?.uuidString == id,
           receipt.completedAt >= started.addingTimeInterval(-1), receipt.completedAt <= now.addingTimeInterval(60),
           receipt.completedAt >= now.addingTimeInterval(-30 * 60) {
            if let snapshot, snapshot.isFresh(at: now), snapshot.sameIdentity(as: before) {
                if snapshot.companionExpiry > before.companionExpiry && snapshot.runnerExpiry > before.runnerExpiry {
                    failure = min(snapshot.companionExpiry, snapshot.runnerExpiry).timeIntervalSince(now) >= Self.minimumNewValidity ? nil : "new_validity_too_short"
                } else { failure = "profiles_not_extended" }
            } else { failure = "fresh_profile_or_identity_unavailable" }
        } else { failure = "receipt_missing_or_stale" }
        if let failure {
            fail(failure, now: now)
            return report(now: now, calendar: calendar, ok: false, reason: failure, nextAction: "restore")
        }
        lastSuccessAt = now
        lastObservedProfiles = snapshot
        initialDueAt = nil
        retryAfter = nil
        lastFailureAt = nil; lastFailureReason = nil
        active?.phase = .awaitingRestore; active?.outcome = .success
        return report(now: now, calendar: calendar, reason: "renewal_verified", nextAction: "restore")
    }

    mutating func completeRecovery(token: String, now: Date, calendar: Calendar) -> [String: JSONValue] {
        guard let id = UUID(uuidString: token)?.uuidString, let attempt = active, attempt.id == id else { return report(now: now, calendar: calendar, ok: false, reason: "attempt_mismatch") }
        guard attempt.phase == .awaitingRestore || now.timeIntervalSince(attempt.startedAt) >= Self.recoveryAge else { return report(now: now, calendar: calendar, ok: false, reason: "attempt_still_active") }
        let succeeded = attempt.phase == .awaitingRestore && attempt.outcome == .success
        let skipped = attempt.phase == .awaitingRestore && attempt.outcome == .skipped
        if attempt.phase != .awaitingRestore { fail("interrupted_attempt_recovered", now: now) }
        let failureReason = lastFailureReason ?? "interrupted_attempt_recovered"
        active = nil
        return report(now: now, calendar: calendar, reason: "restore_acknowledged",
            notificationKind: succeeded ? "success" : (skipped ? "none" : "error"),
            notificationMessage: succeeded ? "iCTRL 重签已验证，远程连接恢复步骤已完成。" : (skipped ? "" : Self.errorMessage(failureReason)))
    }

    func permitsReceipt(token: String) -> Bool {
        UUID(uuidString: token)?.uuidString == active?.id && active?.phase == .refreshing
    }
}

/// A single in-process lock covers load -> compare/mutate -> persist. All these
/// intents run in the companion app, not a second extension or app slot.
enum RenewalGateStore {
    private static let lock = NSLock()
    static let key = "iCTRLRenewalGate.v1"
    static func transact(defaults: UserDefaults = .standard, now: Date = Date(), calendar: Calendar = .current, _ change: (inout RenewalGateState) -> [String: JSONValue]) -> [String: JSONValue] {
        lock.lock(); defer { lock.unlock() }
        var state = RenewalGateState()
        if defaults.object(forKey: key) != nil {
            guard let raw = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(RenewalGateState.self, from: raw), decoded.schemaVersion == 1 else {
                return ["ok": .bool(false), "status": .string("state_corrupt"), "reason": .string("state_corrupt"), "next_action": .string("restore"), "pending": .bool(true), "recovery_required": .bool(true), "prepare_token": .string(""), "attempt_id": .string(""), "notification_kind": .string("error"), "notification_message": .string("自动重签状态损坏，已暂停新任务；请检查应用的重签状态。") ]
            }
            state = decoded
        }
        let previous = state
        let result = change(&state)
        if state != previous {
            guard let data = try? JSONEncoder().encode(state) else { return ["ok": .bool(false), "reason": .string("state_encoding_failed"), "next_action": .string("idle"), "attempt_id": .string(""), "notification_kind": .string("error"), "notification_message": .string("无法保存自动重签状态，本次未授权重签。") ] }
            defaults.set(data, forKey: key)
        }
        return result
    }

    static func plan(reserveIfDue: Bool = false, defaults: UserDefaults = .standard, now: Date = Date(), calendar: Calendar = .current) -> [String: JSONValue] {
        transact(defaults: defaults, now: now, calendar: calendar) { $0.plan(now: now, reserveIfDue: reserveIfDue, calendar: calendar) }
    }

    /// Internal local caller only; no RPC accepts profile dates for this entry.
    static func observeInitialProfiles(_ snapshot: RenewalProfileSnapshot, defaults: UserDefaults = .standard,
                                       now: Date = Date(), calendar: Calendar = .current) -> [String: JSONValue] {
        transact(defaults: defaults, now: now, calendar: calendar) { state in
            state.observeInitialProfiles(snapshot, now: now)
            return state.plan(now: now, reserveIfDue: false, calendar: calendar)
        }
    }

    static func permitsReceipt(token: String, defaults: UserDefaults = .standard) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let raw = defaults.data(forKey: key), let state = try? JSONDecoder().decode(RenewalGateState.self, from: raw), state.schemaVersion == 1 else { return false }
        return state.permitsReceipt(token: token)
    }
}
