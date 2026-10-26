import Foundation

// MARK: - Auth Types

struct AuthRequest: Codable {
    let clientName: String

    enum CodingKeys: String, CodingKey {
        case clientName = "client_name"
    }
}

struct AuthResponse: Encodable {
    let token: String
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case token
        case expiresIn = "expires_in"
    }
}

/// One paired client. `id` is the token id (first 4 bytes of SHA256(K), hex) —
/// it is what the wire sends as `tok` and is a lookup handle only, never a
/// secret. `keyHex` is the actual 32-byte key K used to derive the per-request
/// MAC/encryption keys; it never leaves the device after pairing.
///
/// Expiry is idle-based: a session dies only after `inactivityWindow` of no use.
/// Every authenticated request slides `lastActiveAt` forward, so a token in
/// regular use never expires.
struct AuthSession: Identifiable, Codable {
    let id: String
    let keyHex: String
    let clientName: String
    let grantedAt: Date
    var lastActiveAt: Date
    /// Where the last authenticated request came from: the peer address
    /// (no port) and how it arrived — see `PeerSource`. Nil for sessions not
    /// used since this was recorded.
    var lastAddress: String?
    var lastVia: String?

    /// The 32-byte key, or nil if the stored record is corrupt.
    var key: Data? { Data(hexString: keyHex) }

    /// "Expiry if never used again" — informational, recomputed from last use.
    var expiresAt: Date { lastActiveAt.addingTimeInterval(AuthManager.inactivityWindow) }

    var isExpired: Bool { Date() >= expiresAt }

    enum CodingKeys: String, CodingKey {
        case id
        case keyHex = "key"
        case clientName = "client_name"
        case grantedAt = "granted_at"
        case lastActiveAt = "last_active_at"
        case lastAddress = "last_address"
        case lastVia = "last_via"
    }
}

/// How a request reached the server, judged by the interface it arrived on.
enum PeerSource: String {
    /// Loopback: an app on this device, or a computer over USB (usbmuxd
    /// forwards to the device's loopback, so the two look the same).
    case local
    /// Wi-Fi, Ethernet or the Personal Hotspot bridge.
    case lan
    /// Apple peer-to-peer Wi-Fi (AWDL): nearby discovery.
    case nearby
    /// A VPN or proxy tunnel (utun, ipsec, ppp).
    case vpn
    case cellular
    case other
}
