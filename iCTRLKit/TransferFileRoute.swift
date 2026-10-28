import Foundation

/// Notification routing contains only an opaque transfer ID, never a filename/path.
enum TransferFileRoute {
    static let category = "ICTRL_FILE_TRANSFER"
    static let openAction = "ICTRL_OPEN_RECEIVED_FILES"
    static let idKey = "file_transfer_id"

    static func validID(_ id: String) -> Bool { UUID(uuidString: id) != nil }
    static func url(id: String) -> URL? {
        guard validID(id) else { return nil }
        var parts = URLComponents()
        parts.scheme = "ictrl-app"; parts.host = "files"
        parts.queryItems = [URLQueryItem(name: "id", value: id)]
        return parts.url
    }
    static func parse(_ url: URL) -> String? {
        guard url.scheme == "ictrl-app", url.host == "files", url.path.isEmpty,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              query.count == 1, query[0].name == "id", let id = query[0].value, validID(id) else { return nil }
        return id
    }
    static func selectedID(category: String, action: String, defaultAction: String,
                           payloadID: String?) -> String? {
        guard category == Self.category, action == openAction || action == defaultAction,
              let id = payloadID, validID(id) else { return nil }
        return id
    }
}

/// Locally written after content verification; never populated from notification payload.
struct SavedTransferDocument: Codable, Equatable {
    let id: String
    let name: String
    let size: Int
    let sha256: String

    var isValid: Bool {
        TransferFileRoute.validID(id) && TransferDestinationName.validComponent(name)
            && size >= 0 && size <= FileTransferStore.maxFile
            && sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
    func documentURL(in documents: URL) -> URL? {
        guard isValid, documents.isFileURL else { return nil }
        let root = documents.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(name).standardizedFileURL
        guard candidate.deletingLastPathComponent() == root,
              candidate.resolvingSymlinksInPath().deletingLastPathComponent() == root else { return nil }
        return candidate
    }
}
