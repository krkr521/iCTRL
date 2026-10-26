import Foundation

struct StartupURLRequest {
    enum Operation: String { case status, prepare }
    enum ValidationError: Error { case unsupportedURL, invalidParameter, unsafeCallback }
    let operation: Operation
    let mountIfNeeded: Bool
    let keepAwake: Bool
    let callback: URL?

    init(url: URL) throws {
        guard url.scheme?.lowercased() == "ictrl-app",
              let host = url.host?.lowercased(), let operation = Operation(rawValue: host),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ValidationError.unsupportedURL
        }
        self.operation = operation
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard ["mount_if_needed", "keep_awake", "callback"].contains(item.name),
                  values[item.name] == nil, let value = item.value else { throw ValidationError.invalidParameter }
            values[item.name] = value
        }
        func boolean(_ key: String) throws -> Bool {
            guard let value = values[key] else { return true }
            if ["1", "true"].contains(value.lowercased()) { return true }
            if ["0", "false"].contains(value.lowercased()) { return false }
            throw ValidationError.invalidParameter
        }
        mountIfNeeded = try boolean("mount_if_needed")
        keepAwake = try boolean("keep_awake")
        if let raw = values["callback"] {
            guard let parsed = URL(string: raw),
                  ["minis", "shortcuts", "ictrl-app"].contains(parsed.scheme?.lowercased() ?? "") else {
                throw ValidationError.unsafeCallback
            }
            callback = parsed
        } else {
            callback = nil
        }
    }
}
