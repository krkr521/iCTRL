import Foundation

/// Non-secret token-ID mode mapping and explicit feature switch. A corrupt or
/// unreadable existing file fails closed; registration writes atomically.
struct QuietModeStore {
    struct State: Codable { var enabled = false; var modes: [String: String] = [:] }
    let url: URL
    private var markerURL: URL { url.appendingPathExtension("registered") }

    static func deviceStore() throws -> QuietModeStore {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = base.appendingPathComponent("iCTRL", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return QuietModeStore(url: folder.appendingPathComponent("quiet_control.json"))
    }

    func load() throws -> State {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if FileManager.default.fileExists(atPath: markerURL.path) { throw CocoaError(.fileReadCorruptFile) }
            return State()
        }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
    }

    func save(_ state: State) throws {
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try Data("v1".utf8).write(to: markerURL, options: .atomic)
        var target = url
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try? target.setResourceValues(attributes)
    }
}
