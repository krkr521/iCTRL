import Foundation
import Security

/// Process-local coordination. Every method is locked because the authenticated
/// HTTP queue and the Runner UI queue both consult the same gate.
final class QuietControl {
    struct Launch { let url: URL; let leaseID: String; let deadline: String; let nonce: String; let action: String }
    struct Restore { let leaseID: String; let nonce: String; let action: String }
    enum Failure: Error { case disabled, invalid, busy, forbidden, unavailable }
    private let lock = NSLock()
    private var modes: [String: String] = [:]
    private let store: QuietModeStore?
    private var storageFailed = false
    private var lease: QuietLease?
    private var wallDeadline: String?
    private var pendingUntil: TimeInterval?
    private var pendingAction: String?
    private var contextDiagnostic: String?
    private var restoringUntil: TimeInterval?
    private var launchAttempted = false
    private var beginLaunchNonce: String?
    private var beginDiagnostic: QuietDiagnostics.BeginDiagnostic?
    private var beginCallbackClassification: QuietDiagnostics.CallbackClassification?
    private var beginFocusResult: QuietDiagnostics.FocusResult?
    private var beginContextDiagnostic: QuietDiagnostics.Reason?
    private var lastCallbackClassification: QuietDiagnostics.CallbackClassification?
    private var lastCallbackAction: QuietDiagnostics.Action?
    private(set) var enabled: Bool
    let port: UInt16

    init(enabled: Bool, port: UInt16, store: QuietModeStore? = nil) {
        self.enabled = enabled; self.port = port; self.store = store
        if let store {
            do {
                let saved = try store.load()
                self.enabled = saved.enabled; self.modes = saved.modes
            } catch { self.storageFailed = true; self.enabled = false }
        }
    }

    static func persistent(port: UInt16) -> QuietControl {
        do { return QuietControl(enabled: false, port: port, store: try QuietModeStore.deviceStore()) }
        catch {
            let control = QuietControl(enabled: false, port: port)
            control.storageFailed = true
            return control
        }
    }

    private func save(enabled nextEnabled: Bool, modes nextModes: [String: String]) throws {
        guard !storageFailed else { throw Failure.unavailable }
        if let store {
            do { try store.save(.init(enabled: nextEnabled, modes: nextModes)) }
            catch { storageFailed = true; enabled = false; throw error }
        }
        enabled = nextEnabled; modes = nextModes
    }

    func configure(enabled requested: Bool, now: TimeInterval) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        expire(now)
        guard lease == nil || lease?.state == .ended else { throw Failure.busy }
        try save(enabled: requested, modes: modes)
        return enabled
    }

    var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return !storageFailed && enabled
    }

    var storageState: String {
        lock.lock(); defer { lock.unlock() }
        return storageFailed ? "storage_failed" : "ready"
    }

    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.unavailable }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func expire(_ now: TimeInterval) {
        guard var value = lease else { return }
        if let until = pendingUntil, now >= until {
            if pendingAction == "begin" {
                value.noteBeginUncertain()
                beginDiagnostic = .callbackWindowElapsed
            }
            value.failPending(now: now)
            pendingUntil = nil
            pendingAction = nil
        }
        if let until = restoringUntil, now >= until, value.state == .restoring {
            if value.restoringAction == "begin" {
                beginDiagnostic = .restoreTimeout
                beginContextDiagnostic = .foregroundRestoreTimeout
            }
            value.markRestorationPending()
            restoringUntil = nil
            contextDiagnostic = "foreground_restore_timeout"
        }
        // Any expired lease must stop authorizing UI; gate() also performs this.
        if now >= value.deadline {
            if value.state == .preparing || (value.state == .restoring && value.restoringAction == "begin") {
                beginDiagnostic = .leaseExpired
            }
            if pendingAction == "begin" { value.noteBeginUncertain() }
            _ = value.gate(tokId: value.ownerTokId, session: value.id, now: now)
        }
        lease = value
    }

    func register(owner: String, mode: String, now: TimeInterval) throws -> String {
        lock.lock(); defer { lock.unlock() }
        expire(now)
        guard !storageFailed else { throw Failure.unavailable }
        guard mode == "automation" || mode == "manual" else { throw Failure.invalid }
        // Automation identity is sticky for this paired token. To retire it,
        // revoke the token through the existing authenticated admin flow.
        if modes[owner] == "automation" && mode == "manual" { throw Failure.forbidden }
        if let active = lease, active.state != .ended {
            // Mode cannot be changed around an active or uncertain lease.
            if active.ownerTokId == owner && modes[owner] == mode { return mode }
            if mode != "manual" || active.ownerTokId == owner { throw Failure.busy }
        }
        var updated = modes
        updated[owner] = mode
        try save(enabled: enabled, modes: updated)
        return mode
    }

    func mode(owner: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return storageFailed ? "unavailable" : (modes[owner] ?? "manual_legacy")
    }

    func takeoverState(now: TimeInterval) -> String {
        lock.lock(); defer { lock.unlock() }
        expire(now)
        guard !storageFailed else { return "storage_failed" }
        guard let value = lease, value.state != .ended else { return "manual_ready" }
        return value.state.rawValue
    }

    func takeoverDiagnostic(now: TimeInterval) -> String? {
        lock.lock(); defer { lock.unlock() }
        expire(now)
        return lease?.state == .ended ? nil : contextDiagnostic
    }

    private func shortcutURL(name: String, action: String, nonce: String, deadline: String) throws -> URL {
        var input = ["action": action, "nonce": nonce, "deadline": deadline,
                     "callback": "http://127.0.0.1:\(port)/quiet-callback"]
        if action == "inspect" { input["inspect_only"] = "1" }
        let data = try JSONSerialization.data(withJSONObject: input)
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "input", value: "text"),
                                 URLQueryItem(name: "text", value: String(decoding: data, as: UTF8.self))]
        guard let url = components.url else { throw Failure.unavailable }
        return url
    }

    func begin(owner: String, ttl: Int, now: TimeInterval, date: Date) throws -> Launch {
        lock.lock(); defer { lock.unlock() }
        expire(now)
        guard !storageFailed else { throw Failure.unavailable }
        guard enabled, modes[owner] == "automation" else { throw Failure.disabled }
        guard (1...300).contains(ttl), now.isFinite else { throw Failure.invalid }
        guard lease == nil || lease?.state == .ended else { throw Failure.busy }
        let id = try Self.random(), nonce = try Self.random()
        let deadline = ISO8601DateFormatter().string(from: date.addingTimeInterval(TimeInterval(ttl)))
        var value = try QuietLease(ownerTokId: owner, id: id, ttl: TimeInterval(ttl), now: now)
        try value.prepareCallback(nonce: nonce, action: "begin", expectedDeadline: deadline, now: now)
        let url = try shortcutURL(name: "iCTRL Quiet Begin", action: "begin", nonce: nonce, deadline: deadline)
        lease = value; wallDeadline = deadline; pendingUntil = now + 30; pendingAction = "begin"; restoringUntil = nil; contextDiagnostic = nil; launchAttempted = false; beginLaunchNonce = nonce
        beginDiagnostic = .awaitingCallback; beginCallbackClassification = nil; beginFocusResult = nil
        beginContextDiagnostic = nil
        lastCallbackClassification = nil; lastCallbackAction = nil
        return Launch(url: url, leaseID: id, deadline: deadline, nonce: nonce, action: "begin")
    }

    func status(owner: String, requestedID: String?, now: TimeInterval) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        expire(now)
        if storageFailed { return ["mode": "unavailable", "state": "storage_failed"] }
        var out = ["mode": modes[owner] ?? "manual_legacy"]
        if let value = lease, value.ownerTokId == owner, requestedID == nil || requestedID == value.id {
            out["lease_id"] = value.id; out["state"] = value.state.rawValue; out["deadline"] = wallDeadline
            if let contextDiagnostic { out["context_diagnostic"] = contextDiagnostic }
            if let beginDiagnostic { out["begin_diagnostic"] = beginDiagnostic.rawValue }
            if let beginCallbackClassification { out["begin_callback_classification"] = beginCallbackClassification.rawValue }
            if let beginFocusResult { out["begin_focus_result"] = beginFocusResult.rawValue }
            if let beginContextDiagnostic { out["begin_context_diagnostic"] = beginContextDiagnostic.rawValue }
            if let lastCallbackClassification { out["last_callback_classification"] = lastCallbackClassification.rawValue }
            if let lastCallbackAction { out["last_callback_action"] = lastCallbackAction.rawValue }
        }
        return out
    }

    func gate(owner: String, method: String, session: String?, now: TimeInterval) -> String? {
        lock.lock(); defer { lock.unlock() }
        expire(now)
        if storageFailed { return "quiet mode store unavailable" }
        let automation = modes[owner] == "automation"
        if let session {
            guard automation, var value = lease, value.ownerTokId == owner, value.id == session else { return "invalid automation_session" }
            let allowed = value.gate(tokId: owner, session: session, now: now) == .allowed
            lease = value
            return allowed ? nil : "quiet session is not verified or has expired"
        }
        if automation { return "automation_session required for registered automation token" }
        if let value = lease, value.state != .ended { return "automation owns UI; explicit takeover required" }
        return nil
    }

    func end(owner: String, id: String, now: TimeInterval) throws -> Launch? {
        lock.lock(); defer { lock.unlock() }
        expire(now)
        guard var value = lease, value.ownerTokId == owner, value.id == id else { throw Failure.forbidden }
        guard value.end(tokId: owner, session: id, now: now) else { lease = value; return nil }
        if beginDiagnostic == .awaitingCallback || beginDiagnostic == .callbackAccepted {
            beginDiagnostic = .interrupted
        }
        let nonce = try Self.random()
        let deadline = wallDeadline ?? ""
        try value.prepareCallback(nonce: nonce, action: "end", expectedDeadline: deadline, now: now)
        let url = try shortcutURL(name: "iCTRL Quiet Inspect End", action: "end", nonce: nonce, deadline: deadline)
        lease = value; pendingUntil = now + 30; pendingAction = "end"; restoringUntil = nil; contextDiagnostic = nil
        return Launch(url: url, leaseID: id, deadline: deadline, nonce: nonce, action: "end")
    }

    func takeover(now: TimeInterval) throws -> Launch? {
        lock.lock()
        expire(now)
        let current = lease
        lock.unlock()
        guard let current, current.state != .ended else { return nil }
        return try end(owner: current.ownerTokId, id: current.id, now: now)
    }

    func inspectForManual(owner: String, now: TimeInterval) throws -> Launch {
        lock.lock(); defer { lock.unlock() }
        expire(now)
        guard modes[owner] == "manual", !storageFailed else { throw Failure.forbidden }
        guard var value = lease, value.state == .restorationPending,
              now.isFinite, now >= value.deadline + 300, !value.hasPendingCallback else { throw Failure.busy }
        let nonce = try Self.random()
        let deadline = wallDeadline ?? ""
        try value.prepareCallback(nonce: nonce, action: "inspect", expectedDeadline: deadline, now: now)
        let url = try shortcutURL(name: "iCTRL Quiet Inspect End", action: "inspect", nonce: nonce, deadline: deadline)
        lease = value; pendingUntil = now + 30; pendingAction = "inspect"; restoringUntil = nil; contextDiagnostic = nil
        return Launch(url: url, leaseID: value.id, deadline: deadline, nonce: nonce, action: "inspect")
    }

    @discardableResult func callback(_ report: QuietCallback, now: TimeInterval) -> Bool {
        classifiedCallback(report, now: now) == .accepted
    }

    func classifiedCallback(_ report: QuietCallback, now: TimeInterval) -> QuietDiagnostics.CallbackClassification {
        lock.lock(); defer { lock.unlock() }
        // Classify before expire consumes the pending window. This read does not
        // admit a callback; the original expire + callback sequence still does.
        let prior = lease?.callbackClassification(nonce: report.nonce, action: report.action,
                                                 reportedDeadline: report.deadline, now: now) ?? .noLease
        let associated = lease?.matchesCallbackNonce(report.nonce) == true || beginLaunchNonce == report.nonce
        expire(now)
        guard var value = lease else { return .noLease }
        let accepted = value.callback(nonce: report.nonce, action: report.action, observed: report.observed_focus,
                                      reportedDeadline: report.deadline, now: now)
        let classification: QuietDiagnostics.CallbackClassification = accepted ? .accepted : (prior == .accepted ? .stateMismatch : prior)
        if associated {
            lastCallbackClassification = classification
            lastCallbackAction = QuietDiagnostics.Action(report.action)
            if report.action == "begin", beginLaunchNonce == report.nonce {
                beginCallbackClassification = classification
                if accepted {
                    beginDiagnostic = .callbackAccepted
                    beginFocusResult = QuietDiagnostics.FocusResult(report.observed_focus)
                } else if beginDiagnostic == .awaitingCallback {
                    beginDiagnostic = .callbackRejected
                }
            }
        }
        if accepted {
            pendingUntil = nil
            pendingAction = nil
            restoringUntil = now + 8
        }
        lease = value
        return classification
    }

    /// Logging snapshot only: no expiry, payload, identity, or owner visibility.
    func diagnosticState(leaseID: String? = nil) -> QuietLease.State? {
        lock.lock(); defer { lock.unlock() }
        guard let lease, leaseID == nil || lease.id == leaseID else { return nil }
        return lease.state
    }

    func restorationForAcceptedCallback(_ report: QuietCallback, now: TimeInterval) -> Restore? {
        lock.lock(); defer { lock.unlock() }
        guard let value = lease, value.mayRestore(nonce: report.nonce, now: now) else { return nil }
        return Restore(leaseID: value.id, nonce: report.nonce, action: report.action)
    }

    func mayRestore(_ request: Restore, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        expire(now)
        return lease?.id == request.leaseID && lease?.mayRestore(nonce: request.nonce, now: now) == true
    }

    @discardableResult func finishRestoration(_ request: Restore, succeeded: Bool, diagnostic: String?, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        expire(now)
        guard var value = lease, value.id == request.leaseID,
              value.finishRestoration(nonce: request.nonce, succeeded: succeeded, now: now) else { return false }
        lease = value
        restoringUntil = nil
        contextDiagnostic = succeeded ? nil : (diagnostic ?? "foreground_restore_unconfirmed")
        if request.action == "begin" {
            beginDiagnostic = !succeeded ? .restoreUnconfirmed : (value.state == .quietVerified ? .verified : .focusNotDedicated)
            beginContextDiagnostic = succeeded ? nil : QuietDiagnostics.Reason(context: diagnostic)
        }
        return true
    }

    func failLaunch(_ launch: Launch, diagnostic: String, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard var value = lease, value.id == launch.leaseID,
              value.hasPendingCallback(nonce: launch.nonce, now: now) else { return }
        value.markRestorationPending()
        lease = value; pendingAction = nil; pendingUntil = nil; restoringUntil = nil
        contextDiagnostic = diagnostic
        if launch.action == "begin" {
            beginDiagnostic = .helperLaunchFailed
            beginContextDiagnostic = QuietDiagnostics.Reason(context: diagnostic)
        }
    }

    /// Only a Begin proved never sent to Shortcuts can release manual UI here.
    /// An End/Inspect may follow an earlier Begin, so it must stay blocked.
    @discardableResult func abortBeforeLaunch(_ launch: Launch, diagnostic: String, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard now.isFinite, launch.action == "begin", !launchAttempted, beginLaunchNonce == launch.nonce,
              var value = lease, value.id == launch.leaseID,
              value.state == .preparing || value.state == .failed || value.state == .expired else { return false }
        value.endWithoutLaunchingBegin()
        lease = value; pendingAction = nil; pendingUntil = nil; restoringUntil = nil
        contextDiagnostic = diagnostic
        beginDiagnostic = .helperNotLaunched
        beginContextDiagnostic = QuietDiagnostics.Reason(context: diagnostic)
        return true
    }

    @discardableResult func markLaunchAttempted(_ launch: Launch, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard lease?.id == launch.leaseID,
              lease?.hasPendingCallback(nonce: launch.nonce, now: now) == true else { return false }
        launchAttempted = true
        return true
    }

    func mayLaunch(_ launch: Launch, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return lease?.id == launch.leaseID && lease?.hasPendingCallback(nonce: launch.nonce, now: now) == true
    }
}
