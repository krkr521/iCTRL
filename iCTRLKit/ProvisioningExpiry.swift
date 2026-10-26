import Foundation

/// Read only this process's embedded profile; export only expiry and team ID.
/// Certificates, entitlements, identities and provisioned device IDs never leave
/// this helper. The OS verifies the installed app signature; this is metadata
/// extraction, not a replacement for CMS signature verification.
enum ProvisioningExpiry {
    static let maximumProfileBytes = 2 * 1024 * 1024

    private static func values(in raw: Data) -> [String: Any]? {
        guard raw.count <= maximumProfileBytes,
              let start = raw.range(of: Data("<plist".utf8)),
              let end = raw.range(of: Data("</plist>".utf8), in: start.lowerBound..<raw.endIndex) else { return nil }
        let xml = raw.subdata(in: start.lowerBound..<end.upperBound)
        return (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any]
    }

    static func date(in raw: Data) -> Date? { values(in: raw)?["ExpirationDate"] as? Date }

    static func teamIdentifier(in raw: Data) -> String? {
        guard let team = (values(in: raw)?["TeamIdentifier"] as? [String])?.first,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return team
    }

    private static func currentData(bundle: Bundle) -> Data? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumProfileBytes,
              let raw = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return raw
    }

    static func currentDate(bundle: Bundle = .main) -> Date? {
        guard let raw = currentData(bundle: bundle) else { return nil }
        return date(in: raw)
    }

    static func currentTeamIdentifier(bundle: Bundle = .main) -> String? {
        guard let raw = currentData(bundle: bundle) else { return nil }
        return teamIdentifier(in: raw)
    }

    static func currentISO8601(bundle: Bundle = .main) -> String? {
        guard let expiry = currentDate(bundle: bundle) else { return nil }
        return ISO8601DateFormatter().string(from: expiry)
    }
}
