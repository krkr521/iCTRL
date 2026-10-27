import Foundation

/// Diagnostics accept finite enums only. Never interpolate callback/clipboard
/// payloads, identifiers, URLs, app names, or exception descriptions here.
enum QuietDiagnostics {
    enum Action: String, CaseIterable {
        case begin, end, inspect, unknown
        init(_ raw: String) { self = Self(rawValue: raw) ?? .unknown }
    }
    enum FocusResult: String, CaseIterable {
        case dedicated, previous, unavailable, off, preserved
        case otherAllowed = "other_allowed"
        init(_ raw: String) {
            switch raw {
            case "iCTRL Automation": self = .dedicated
            case "previous_focus_active": self = .previous
            case "unavailable": self = .unavailable
            case "off": self = .off
            case "preserved_user_focus": self = .preserved
            default: self = .otherAllowed
            }
        }
    }
    enum EndSource: String, CaseIterable {
        case owner = "owner_end"
        case ttl = "ttl_expiry"
        case takeover = "manual_takeover"
    }
    enum Event: String, CaseIterable {
        case callback = "callback"
        case endRequested = "end_requested"
        case helperLaunchSkipped = "helper_launch_skipped"
        case helperLaunchFailed = "helper_launch_failed"
        case helperLaunchAccepted = "helper_launch_accepted"
        case restoreFinished = "restore_finished"
    }
    enum CallbackClassification: String, CaseIterable {
        case accepted = "accepted_204"
        case framing = "framing_413"
        case origin = "origin_query_403"
        case contract = "contract_400"
        case contentType = "content_type_400"
        case size = "size_400"
        case jsonShape = "json_shape_400"
        case nonceShape = "nonce_shape_400"
        case action = "action_400"
        case focusValue = "focus_value_400"
        case deadline = "deadline_400"
        case noLease = "lease_missing_409"
        case noPending = "no_pending_409"
        case nonceMismatch = "nonce_mismatch_409"
        case actionMismatch = "action_mismatch_409"
        case deadlineMismatch = "deadline_mismatch_409"
        case invalidClock = "invalid_clock_409"
        case callbackWindowElapsed = "callback_window_elapsed_409"
        case leaseExpired = "lease_expired_409"
        case stateMismatch = "state_mismatch_409"
    }
    enum BeginDiagnostic: String, CaseIterable {
        case awaitingCallback = "awaiting_callback"
        case callbackAccepted = "callback_accepted_awaiting_restore"
        case callbackRejected = "callback_rejected"
        case callbackWindowElapsed = "callback_window_elapsed"
        case leaseExpired = "lease_expired_before_verification"
        case interrupted = "end_before_begin_verified"
        case restoreTimeout = "foreground_restore_timeout"
        case restoreUnconfirmed = "foreground_restore_unconfirmed"
        case helperNotLaunched = "helper_not_launched"
        case helperLaunchFailed = "helper_launch_failed"
        case focusNotDedicated = "focus_not_dedicated"
        case verified = "quiet_verified"
    }
    enum Reason: String, CaseIterable {
        case helperDeadline = "helper_not_launched_before_deadline"
        case foregroundBeforeHelperUnknown = "foreground_before_helper_unknown"
        case shortcutLaunchFailed = "shortcut_launch_failed"
        case foregroundContextMissing = "foreground_context_missing"
        case foregroundChangedDuringHelper = "foreground_changed_during_helper"
        case foregroundChangedBeforeRestore = "foreground_changed_before_restore"
        case foregroundRestoreBudgetExpired = "foreground_restore_budget_expired"
        case foregroundActivationRejected = "foreground_activation_rejected"
        case foregroundTargetPIDUnavailable = "foreground_target_pid_unavailable"
        case foregroundPIDUnconfirmed = "foreground_pid_unconfirmed"
        case foregroundRestoreUnconfirmed = "foreground_restore_unconfirmed"
        case foregroundRestoreTimeout = "foreground_restore_timeout"

        init(context: String?) {
            self = context.flatMap { Self(rawValue: $0) } ?? .foregroundRestoreUnconfirmed
        }
    }

    static func message(_ event: Event, action: Action = .unknown,
                        source: EndSource? = nil, classification: CallbackClassification? = nil,
                        focus: FocusResult? = nil, state: QuietLease.State? = nil,
                        reason: Reason? = nil) -> String {
        var fields = ["Quiet", "event=\(event.rawValue)", "action=\(action.rawValue)"]
        if let source { fields.append("source=\(source.rawValue)") }
        if let classification { fields.append("classification=\(classification.rawValue)") }
        if let focus { fields.append("focus_result=\(focus.rawValue)") }
        if let state { fields.append("state=\(state.rawValue)") }
        if let reason { fields.append("reason=\(reason.rawValue)") }
        return fields.joined(separator: " ")
    }

    /// Recognition for logging only; this must never change HTTP admission.
    static func isCallbackRequestLine(_ header: String) -> Bool {
        let line = header.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, parts[0] == "POST" else { return false }
        return parts[1].split(separator: "?", maxSplits: 1).first == "/quiet-callback"
    }
}

/// Stages describe the last entered API, not proof that a paste prompt exists.
enum NativeClipboardDiagnostics {
    enum Method: String, CaseIterable {
        case get = "clipboard_get", set = "clipboard_set", clear = "clipboard_clear", unknown
        init(_ raw: String) { self = Self(rawValue: raw) ?? .unknown }
    }
    enum Stage: String, CaseIterable {
        case queued, prepare
        case foregroundLookup = "foreground_lookup"
        case foregroundActivation = "foreground_activation"
        case foregroundWait = "foreground_wait"
        case access
        case permissionPending = "permission_pending"
        case restore, finished
    }
    enum Reason: String, CaseIterable {
        case entered, completed, failed, timeout, busy
        case invalidParameters = "invalid_parameters"
    }
    static func message(method: Method, stage: Stage, reason: Reason) -> String {
        "NativeClipboard method=\(method.rawValue) stage=\(stage.rawValue) reason=\(reason.rawValue)"
    }
}
