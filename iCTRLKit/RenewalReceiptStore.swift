import Foundation

/// Records only progress of a local Shortcut. This does not prove any profile
/// was renewed; callers must independently verify increased expiry dates.
enum RenewalReceiptStore {
    static func record(attemptID: String, now: Date = Date(), defaults: UserDefaults = .standard) -> [String: JSONValue]? {
        guard let id = UUID(uuidString: attemptID) else { return nil }
        let timestamp = ISO8601DateFormatter().string(from: now)
        defaults.set(["attempt_id": id.uuidString, "completed_at": timestamp], forKey: "localRenewalReceipt")
        return ["attempt_id": .string(id.uuidString), "completed_at": .string(timestamp)]
    }

    static func currentJSON(defaults: UserDefaults = .standard) -> JSONValue {
        guard let value = defaults.dictionary(forKey: "localRenewalReceipt"),
              let id = value["attempt_id"] as? String, UUID(uuidString: id) != nil,
              let time = value["completed_at"] as? String, ISO8601DateFormatter().date(from: time) != nil else { return .null }
        return .object(["attempt_id": .string(id), "completed_at": .string(time)])
    }
}
