import Foundation

/// No owner identities, tokens, file paths or UI text appear in admission diagnostics.
struct NativeDeviceReadiness {
    enum Reason: String {
        case interruptionGuardUnavailable = "native_interruption_guard_unavailable"
        case f13Unavailable = "native_f13_abi_unavailable"
        case monitorUnregistered = "native_lock_monitor_unregistered"
        case stateUnknown = "native_lock_state_unknown"
        case deviceLocked = "native_device_locked"
    }
    let interruptionGuardAvailable: Bool
    let f13Available: Bool
    let monitorRegistered: Bool
    let stateKnown: Bool
    let locked: Bool
    let lockGeneration: UInt64
    var reason: Reason? {
        if !interruptionGuardAvailable { return .interruptionGuardUnavailable }
        if !f13Available { return .f13Unavailable }
        if !monitorRegistered { return .monitorUnregistered }
        if !stateKnown { return .stateUnknown }
        if locked { return .deviceLocked }
        return nil
    }
    var ready: Bool { reason == nil }
    var diagnostics: [String: JSONValue] {
        ["interruption_guard_available": .bool(interruptionGuardAvailable), "f13_abi_available": .bool(f13Available),
         "lock_monitor_registered": .bool(monitorRegistered), "lock_state_known": .bool(stateKnown),
         "locked": .bool(locked), "device_ready": .bool(ready),
         "admission_reason": reason.map { .string($0.rawValue) } ?? .string("ready")]
    }
    static let unavailable = NativeDeviceReadiness(interruptionGuardAvailable: false, f13Available: false,
        monitorRegistered: false, stateKnown: false, locked: true, lockGeneration: 0)
}

/// Wrong-owner/session requests are rejected before any mode/health side effects.
/// The runtime server and Foundation tests use this same admission policy.
enum NativeControlAdmission {
    static func error(sessions: NativeAutomationSession, owner: String, id: String?, now: TimeInterval,
                      readiness: () -> NativeDeviceReadiness, mode: (String) -> String,
                      legacyReady: () -> Bool, serviceReady: (UInt64) -> Bool,
                      recheckNow: (() -> TimeInterval)? = nil) -> String? {
        guard let active = sessions.authorizedLease(owner: owner, id: id, now: now) else {
            return "native_session_owned_or_expired"
        }
        let health = readiness()
        func revoke(_ reason: String) -> String { sessions.revoke(id: active.id); return reason }
        if let reason = health.reason { return revoke(reason.rawValue) }
        guard serviceReady(health.lockGeneration) else { return revoke("native_service_keep_awake_unavailable") }
        guard active.lockGeneration == health.lockGeneration else { return revoke("native_lock_generation_changed") }
        guard mode(active.owner) == "automation" else { return revoke("native_automation_owner_required") }
        guard legacyReady() else { return revoke("native_legacy_recovery_required") }
        // End, callback revocation, replacement or expiry may occur inside the
        // readiness closures. Recheck identity/time without revoking a newer lease.
        guard sessions.gate(owner: owner, id: active.id, now: recheckNow?() ?? now) else {
            return "native_session_owned_or_expired"
        }
        return nil
    }
}
