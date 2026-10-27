import Foundation

/// Call from the loopback HTTP listener after checking method/path/header byte limit.
/// This parser never logs or echoes the secret body.
public struct QuietCallback: Decodable {
    public enum ParseFailure: String, Error, CaseIterable {
        case contract, size, action, deadline
        case contentType = "content_type"
        case jsonShape = "json_shape"
        case nonceShape = "nonce_shape"
        case focusValue = "focus_value"

        var classification: QuietDiagnostics.CallbackClassification {
            switch self {
            case .contract: return .contract
            case .contentType: return .contentType
            case .size: return .size
            case .jsonShape: return .jsonShape
            case .nonceShape: return .nonceShape
            case .action: return .action
            case .focusValue: return .focusValue
            case .deadline: return .deadline
            }
        }
    }
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
        guard method == "POST", path == "/quiet-callback" else { throw ParseFailure.contract }
        guard isJSON(contentType) else { throw ParseFailure.contentType }
        guard headerBytes >= 0, headerBytes <= 4096, body.count <= 1024 else { throw ParseFailure.size }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: body) }
        catch { throw ParseFailure.jsonShape }
        guard value.nonce.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { throw ParseFailure.nonceShape }
        guard value.action == "begin" || value.action == "end" || value.action == "inspect" else { throw ParseFailure.action }
        guard ["iCTRL Automation", "previous_focus_active", "unavailable", "off", "preserved_user_focus"].contains(value.observed_focus) else { throw ParseFailure.focusValue }
        guard ISO8601DateFormatter().date(from: value.deadline) != nil else { throw ParseFailure.deadline }
        return value
    }
}
