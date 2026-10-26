import Foundation

/// Only accept the narrow, non-sensitive fields from a fresh authenticated RPC.
/// The transport must authenticate and bind its response to the current request.
enum RunnerProfileMetadata {
    enum Failure: String, Error {
        case serverNotRunning = "runner_not_running"
        case expiryUnavailable = "runner_profile_expiry_unavailable"
        case invalidExpiry = "runner_profile_expiry_invalid"
        case invalidIdentity = "runner_profile_identity_invalid"
        case teamMismatch = "runner_profile_team_mismatch"
    }

    static func parse(_ fields: [String: JSONValue], companionBundleID: String?, companionTeam: String?,
                      requestID: String, observedAt: Date = Date()) throws -> [String: JSONValue] {
        guard fields["server_running"] == .bool(true) else { throw Failure.serverNotRunning }
        guard fields["runner_profile_expiry_available"] == .bool(true) else { throw Failure.expiryUnavailable }
        guard let text = fields["runner_profile_expires_at"]?.stringValue, text.utf8.count <= 64,
              let expiry = ISO8601DateFormatter().date(from: text) else { throw Failure.invalidExpiry }
        guard UUID(uuidString: requestID) != nil,
              let bundle = fields["bundle_id"]?.stringValue, !bundle.isEmpty, bundle.utf8.count <= 255,
              bundle.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil,
              bundle != companionBundleID,
              let team = fields["team_identifier"]?.stringValue,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw Failure.invalidIdentity }
        guard let companionTeam, team == companionTeam else { throw Failure.teamMismatch }
        let formatter = ISO8601DateFormatter()
        return [
            "runner_profile_expires_at": .string(formatter.string(from: expiry)),
            "runner_profile_expiry_verified": .bool(true),
            "runner_bundle_id": .string(bundle), "runner_team_identifier": .string(team),
            "runner_metadata_source": .string("authenticated_loopback_runtime_status"),
            "runner_metadata_request_id": .string(requestID),
            "runner_metadata_observed_at": .string(formatter.string(from: observedAt)),
        ]
    }
}

/// In addition to envelope MAC/nonce verification, reject mismatched JSON-RPC replies.
enum RunnerRPCResponsePolicy {
    static func matches(_ reply: [String: Any], requestID: String) -> Bool {
        reply["jsonrpc"] as? String == "2.0" && reply["id"] as? String == requestID
    }
}
