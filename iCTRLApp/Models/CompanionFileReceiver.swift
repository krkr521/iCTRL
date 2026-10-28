import Foundation
import CryptoKit
import Combine

/// Saves authenticated queued transfers into this app's Documents only.
@MainActor
final class CompanionFileReceiver: ObservableObject {
    @Published private(set) var status = "等待电脑传入文件"
    @Published private(set) var transfers: [FileTransferProgress] = []
    @Published private(set) var failedIDs: Set<String> = []
    private var client = RunnerClient(port: 8200)
    private var running = false
    private var writtenNames: [String: String] = [:]
    func retryFailed() { failedIDs.removeAll(); status = "正在重新接收文件" }

    func run() async {
        // A new foreground task waits for the cancelled old task to unwind.
        while running {
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        }
        guard !Task.isCancelled else { return }
        running = true; defer { running = false }
        while !Task.isCancelled {
            var savingID: String?
            do {
                if !client.isPaired { client = RunnerClient(port: 8200) }
                guard client.isPaired else {
                    status = "请先在已授权客户端中连接 iCTRL 服务"
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                let reply = try await client.call("file_list", ["direction": "pc_to_phone", "include_progress": true])
                try Task.checkCancellation()
                let items = reply["files"] as? [[String: Any]] ?? []
                let previous = Dictionary(uniqueKeysWithValues: transfers.map { ($0.id, $0) })
                transfers = items.compactMap { item in
                    guard let data = try? JSONSerialization.data(withJSONObject: item),
                          let metadata = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
                    guard var row = FileTransferProgress(metadata: metadata) else { return nil }
                    if row.stage == .waiting, let old = previous[row.id], old.stage == .awaitingReceipt {
                        row.stage = .awaitingReceipt; row.name = old.name
                    }
                    if failedIDs.contains(row.id) { row.stage = .failed }
                    return row
                }
                let live = Set(transfers.map(\.id))
                failedIDs.formIntersection(live)
                writtenNames = writtenNames.filter { live.contains($0.key) }
                status = transfers.isEmpty ? "等待电脑传入文件" : "文件接收"
                for item in items where item["state"] as? String == "ready" && (item["can_receive"] as? Bool ?? true) {
                    if let id = item["id"] as? String, failedIDs.contains(id) { continue }
                    try Task.checkCancellation()
                    savingID = item["id"] as? String
                    try await save(item)
                    savingID = nil
                }
            } catch is CancellationError { return }
            catch {
                if let id = savingID {
                    if writtenNames[id] != nil {
                        update(id, stage: .awaitingReceipt)
                        status = "文件已写入，保存确认尚未完成"
                    } else {
                        update(id, stage: .failed)
                        if let failure = error as? CocoaError {
                            failedIDs.insert(id)
                            switch failure.code {
                            case .fileWriteOutOfSpace: status = "存储空间不足，请清理后点重试"
                            case .fileWriteNoPermission, .fileReadNoPermission: status = "无法访问文件，请解锁手机后点重试"
                            case .fileReadCorruptFile: status = "文件校验失败，请点重试重新接收"
                            default: status = "文件保存失败，请点重试"
                            }
                        } else if (error as NSError).domain == NSPOSIXErrorDomain {
                            failedIDs.insert(id)
                            status = "文件写入失败，请检查存储空间或访问权限"
                        } else { status = "文件接收失败，请检查服务连接" }
                    }
                } else { status = "暂时无法连接 iCTRL 服务" }
            }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
        }
    }

    private func update(_ id: String, stage: FileTransferProgress.Stage, completed: Int? = nil, name: String? = nil) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        var row = transfers[index]
        row.stage = stage
        if let completed { row.completed = completed }
        if let name { row.name = name }
        transfers[index] = row
    }

    private func verifiedDocument(_ name: String, size: Int, hash: String, documents: URL) async throws -> Bool {
        guard TransferDestinationName.validComponent(name) else { return false }
        let url = documents.appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == size,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var digest = SHA256(), count = 0
        while let data = try handle.read(upToCount: FileTransferStore.chunkSize), !data.isEmpty {
            try Task.checkCancellation()
            count += data.count
            guard count <= size else { return false }
            digest.update(data: data)
            await Task.yield()
        }
        return count == size && digest.finalize().map { String(format: "%02x", $0) }.joined() == hash
    }

    private func save(_ item: [String: Any]) async throws {
        guard let id = item["id"] as? String, UUID(uuidString: id) != nil,
              let rawName = item["name"] as? String,
              let size = item["size"] as? Int, size >= 0, size <= FileTransferStore.maxFile,
              let expected = item["sha256"] as? String, expected.count == 64 else { throw CocoaError(.fileReadCorruptFile) }
        let claim = try await client.call("file_claim", ["id": id])
        guard let lease = claim["lease"] as? String else { throw CocoaError(.fileReadCorruptFile) }
        let acknowledgement: (String) -> [String: Any] = { name in
            ["id": id, "lease": lease, "name": name, "size": size, "sha256": expected, "recipient": "companion"]
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TransferReceive", isDirectory: true)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let receipt = support.appendingPathComponent(id + ".json")
        let cached = (try? Data(contentsOf: receipt)).flatMap { try? JSONDecoder().decode(String.self, from: $0) }
        if let name = writtenNames[id] ?? cached,
           try await verifiedDocument(name, size: size, hash: expected, documents: documents) {
            writtenNames[id] = name
            update(id, stage: .awaitingReceipt, completed: size, name: name)
            try JSONEncoder().encode(name).write(to: receipt, options: .atomic)
            let response = try await client.call("file_saved", acknowledgement(name))
            guard response["saved"] as? Bool == true, response["state"] as? String == "saved" else { throw CocoaError(.fileReadCorruptFile) }
            writtenNames.removeValue(forKey: id)
            update(id, stage: .saved, completed: size, name: name)
            status = "已保存到「文件 → 我的 iPhone → iCTRL」"
            return
        }
        writtenNames.removeValue(forKey: id)
        let temporary = support.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var offset = 0; var digest = SHA256()
        update(id, stage: .saving, completed: 0)
        while offset < size {
            try Task.checkCancellation()
            let reply = try await client.call("file_read", ["id": id, "lease": lease, "offset": offset, "length": FileTransferStore.chunkSize])
            try Task.checkCancellation()
            guard let encoded = reply["data"] as? String,
                  let data = Data(base64Encoded: encoded), !data.isEmpty,
                  data.count <= min(FileTransferStore.chunkSize, size - offset) else { throw CocoaError(.fileReadCorruptFile) }
            try handle.write(contentsOf: data)
            digest.update(data: data); offset += data.count
            update(id, stage: .saving, completed: offset)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == expected else { throw CocoaError(.fileReadCorruptFile) }
        try handle.synchronize(); try handle.close()
        try Task.checkCancellation()
        var saved: URL?
        for index in 0..<10000 {
            if index % 32 == 0 { try Task.checkCancellation(); await Task.yield() }
            let target = documents.appendingPathComponent(TransferDestinationName.make(rawName, collision: index))
            do { try FileManager.default.linkItem(at: temporary, to: target); saved = target; break }
            catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
        }
        guard let saved else { throw CocoaError(.fileWriteFileExists) }
        writtenNames[id] = saved.lastPathComponent
        update(id, stage: .awaitingReceipt, completed: size, name: saved.lastPathComponent)
        try JSONEncoder().encode(saved.lastPathComponent).write(to: receipt, options: .atomic)
        let response = try await client.call("file_saved", acknowledgement(saved.lastPathComponent))
        guard response["saved"] as? Bool == true, response["state"] as? String == "saved" else { throw CocoaError(.fileReadCorruptFile) }
        writtenNames.removeValue(forKey: id)
        update(id, stage: .saved, completed: size)
        status = "已保存到「文件 → 我的 iPhone → iCTRL」"
    }
}
