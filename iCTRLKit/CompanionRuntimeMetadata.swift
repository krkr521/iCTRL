import Foundation

/// Non-sensitive local companion report, NOT authenticated process identity.
/// The nonce binds one handoff and prevents stale callback confusion only.
/// Runtime RPC authentication still protects its remote delivery.
enum CompanionRuntimeMetadata {
    static func parse(startURL: URL, receivedAt: Date = Date()) -> [String: JSONValue]? {
        guard startURL.scheme == "ictrl", startURL.host == "start",
              let parts = URLComponents(url: startURL, resolvingAgainstBaseURL: false) else { return nil }
        let items = parts.queryItems ?? []
        func one(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard let requestID = one("request_id"), UUID(uuidString: requestID) != nil,
              let rawCallback = one("callback"), let callback = URLComponents(string: rawCallback),
              callback.scheme == "ictrl-app", callback.host == "started",
              callback.queryItems?.filter({ $0.name == "request_id" }).count == 1,
              callback.queryItems?.first(where: { $0.name == "request_id" })?.value == requestID,
              let text = one("companion_metadata"), text.utf8.count <= 4096,
              let raw = text.data(using: .utf8),
              let fields = try? JSONDecoder().decode([String: JSONValue].self, from: raw) else { return nil }
        let allowed: Set<String> = ["companion_profile_expires_at", "companion_bundle_id", "companion_team_identifier", "renewal_receipt", "renewal_gate"]
        guard Set(fields.keys).isSubset(of: allowed) else { return nil }
        var report: [String: JSONValue] = [
            "companion_metadata_source": .string("local_companion_report"),
            "companion_metadata_verified": .bool(false),
            "companion_report_request_id": .string(requestID),
            "companion_report_received_at": .string(ISO8601DateFormatter().string(from: receivedAt)),
            "companion_profile_expires_at": .null, "renewal_receipt": .null,
        ]
        if let expiry = fields["companion_profile_expires_at"]?.stringValue,
           let date = ISO8601DateFormatter().date(from: expiry) {
            report["companion_profile_expires_at"] = .string(ISO8601DateFormatter().string(from: date))
        }
        if let id = fields["companion_bundle_id"]?.stringValue, id.utf8.count <= 255,
           id.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil { report["companion_bundle_id"] = .string(id) }
        if let team = fields["companion_team_identifier"]?.stringValue,
           team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil { report["companion_team_identifier"] = .string(team) }
        if let receipt = fields["renewal_receipt"]?.objectValue,
           Set(receipt.keys) == Set(["attempt_id", "completed_at"]),
           let id = receipt["attempt_id"]?.stringValue, UUID(uuidString: id) != nil,
           let time = receipt["completed_at"]?.stringValue, ISO8601DateFormatter().date(from: time) != nil {
            report["renewal_receipt"] = .object(receipt)
        }
        if let gate = fields["renewal_gate"]?.objectValue {
            let allowed: Set<String> = ["ok", "status", "reason", "next_action", "should_prepare", "due", "pending", "recovery_required", "prepare_token", "attempt_id", "last_success_at", "next_due_at", "last_failure_at", "last_failure_reason", "notification_kind", "notification_message", "baseline_observed_at", "baseline_companion_expires_at", "baseline_runner_expires_at", "cadence"]
            if Set(gate.keys).isSubset(of: allowed), let raw = try? JSONEncoder().encode(gate), raw.count <= 2048 {
                report["renewal_gate"] = .object(gate)
            }
        }
        return report
    }
}
