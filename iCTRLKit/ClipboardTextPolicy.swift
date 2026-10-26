import Foundation

enum NativeClipboardValidationError: Error {
    case invalidParams, textTooLarge, nulNotSupported

    var reason: String {
        switch self {
        case .textTooLarge: return "text_too_large"
        case .invalidParams, .nulNotSupported: return "invalid_params"
        }
    }
}

/// Shared, testable validation. No clipboard data is logged or persisted.
enum ClipboardTextPolicy {
    static let maximumUTF8Bytes = 65_536

    static func validate(_ text: String) throws {
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw NativeClipboardValidationError.nulNotSupported
        }
        guard text.utf8.count <= maximumUTF8Bytes else {
            throw NativeClipboardValidationError.textTooLarge
        }
    }
}

struct NativeClipboardRequest {
    static let methods: Set<String> = ["clipboard_get", "clipboard_set", "clipboard_clear"]
    let method: String
    let text: String?
    let foreground: Bool
    let restoreApp: Bool

    init(method: String, params: [String: JSONValue]?) throws {
        guard Self.methods.contains(method) else { throw NativeClipboardValidationError.invalidParams }
        let values = params ?? [:]
        let permitted: Set<String> = method == "clipboard_set"
            ? ["text", "foreground", "restore_app"] : ["foreground", "restore_app"]
        guard Set(values.keys).isSubset(of: permitted) else { throw NativeClipboardValidationError.invalidParams }
        func boolean(_ key: String) throws -> Bool {
            guard let value = values[key] else { return true }
            guard case .bool(let result) = value else { throw NativeClipboardValidationError.invalidParams }
            return result
        }
        foreground = try boolean("foreground")
        restoreApp = try boolean("restore_app")
        self.method = method
        if method == "clipboard_set" {
            guard case .string(let value)? = values["text"] else { throw NativeClipboardValidationError.invalidParams }
            try ClipboardTextPolicy.validate(value)
            text = value
        } else {
            text = nil
        }
    }
}
