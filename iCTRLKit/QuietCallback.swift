import Foundation

/// Call from the loopback HTTP listener after checking method/path/header byte limit.
/// This parser never logs or echoes the secret body.
public struct QuietCallback: Decodable {
    public let nonce: String
    public let action: String
    public let observed_focus: String
    public let deadline: String

    private static func isJSON(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard parts.first == "application/json", parts.count <= 2 else { return false }
        if parts.count == 2 {
            let parameter = parts[1].replacingOccurrences(of: "\"", with: "")
            guard parameter == "charset=utf-8" else { return false }
        }
        return true
    }

    public static func parse(method: String, path: String, contentType: String?, headerBytes: Int, body: Data) throws -> Self {
        guard method == "POST", path == "/quiet-callback", isJSON(contentType),
              headerBytes >= 0, headerBytes <= 4096, body.count <= 1024 else { throw LeaseError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: body)
        guard value.nonce.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              value.action == "begin" || value.action == "end" || value.action == "inspect",
              ["iCTRL Automation", "previous_focus_active", "unavailable", "off", "preserved_user_focus"].contains(value.observed_focus),
              ISO8601DateFormatter().date(from: value.deadline) != nil else { throw LeaseError.invalid }
        return value
    }
}
