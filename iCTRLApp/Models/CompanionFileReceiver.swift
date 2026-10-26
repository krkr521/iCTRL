import Foundation
import CryptoKit

/// Saves only authenticated queued transfers into this process's Documents.
/// Used by Companion, never points at another application's container.
@MainActor
final class CompanionFileReceiver: ObservableObject {
    @Published var status = "Files: waiting for incoming transfers"
    private var client = RunnerClient(port: 8200)
    private var running = false
    func run() async {
        guard !running else { return }
        running = true; defer { running = false }
        while !Task.isCancelled {
            do {
                if !client.isPaired { client = RunnerClient(port: 8200) }
                guard client.isPaired else { status = "Files: connect iCTRL App to Runner in Clients first"; try await Task.sleep(nanoseconds: 2_000_000_000); continue }
                let reply = try await client.call("file_list", ["direction": "pc_to_phone"])
                for item in reply["files"] as? [[String: Any]] ?? [] {
                    try Task.checkCancellation()
                    try await save(item)
                }
            } catch is CancellationError { return }
            catch { status = "Files: pending — Runner unavailable or transfer interrupted" }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
        }
    }
    private func save(_ item: [String: Any]) async throws {
        guard let id = item["id"] as? String, UUID(uuidString: id) != nil, let rawName = item["name"] as? String,
              let size = item["size"] as? Int, size >= 0, size <= FileTransferStore.maxFile,
              let expected = item["sha256"] as? String else { throw CocoaError(.fileReadCorruptFile) }
        let claim = try await client.call("file_claim", ["id": id])
        guard let lease = claim["lease"] as? String else { throw CocoaError(.fileReadCorruptFile) }
        let acknowledgement: (String) -> [String: Any] = { name in
            ["id": id, "lease": lease, "name": name, "size": size, "sha256": expected, "recipient": "companion"]
        }
        // Partial bytes live in Library, not the user-visible Files directory.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TransferReceive", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let receipt = support.appendingPathComponent(id + ".json")
        if let data = try? Data(contentsOf: receipt),
           let name = try? JSONDecoder().decode(String.self, from: data) {
            _ = try await client.call("file_saved", acknowledgement(name))
            status = "Files: saved \(name)"
            return
        }
        let temporary = support.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var offset = 0; var digest = SHA256()
        while offset < size {
            try Task.checkCancellation()
            let reply = try await client.call("file_read", ["id": id, "lease": lease, "offset": offset, "length": FileTransferStore.chunkSize])
            guard let encoded = reply["data"] as? String,
                  let data = Data(base64Encoded: encoded), !data.isEmpty,
                  data.count <= min(FileTransferStore.chunkSize, size - offset) else { throw CocoaError(.fileReadCorruptFile) }
            try handle.write(contentsOf: data); digest.update(data: data); offset += data.count
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == expected else { throw CocoaError(.fileReadCorruptFile) }
        try handle.synchronize(); try handle.close()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let name = FileTransferStore.safeName(rawName)
        let stem = (name as NSString).deletingPathExtension; let ext = (name as NSString).pathExtension
        var saved: URL?
        for index in 0..<10000 {
            let suffix = ext.isEmpty ? "" : "." + ext
            let target = documents.appendingPathComponent(index == 0 ? name : "\(stem) (\(index))\(suffix)")
            do {
                // Hard link is exclusive: existing files are never replaced.
                try FileManager.default.linkItem(at: temporary, to: target); saved = target; break
            } catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
        }
        guard let saved else { throw CocoaError(.fileWriteFileExists) }
        try JSONEncoder().encode(saved.lastPathComponent).write(to: receipt, options: .atomic)
        _ = try await client.call("file_saved", acknowledgement(saved.lastPathComponent))
        status = "Files: saved \(saved.lastPathComponent)"
    }
}
