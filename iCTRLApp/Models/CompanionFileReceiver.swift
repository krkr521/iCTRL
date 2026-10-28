import Foundation
import CryptoKit
import Combine

/// Saves authenticated queued transfers into this app's Documents only.
@MainActor
final class CompanionFileReceiver: ObservableObject {
    @Published private(set) var status = "等待电脑传入文件"
    @Published private(set) var transfers: [FileTransferProgress] = []
    @Published private(set) var failedIDs: Set<String> = []
    @Published var showTransfers = false
    @Published private(set) var openedDocument: URL?
    @Published private(set) var openMessage: String?
    private var selection = TransferFileSelection()
    @Published private var savedDocuments: [String: SavedTransferDocument] = [:]
    private var savedOrder: [String] = []
    var localSavedFiles: [SavedTransferDocument] {
        savedOrder.reversed().compactMap { savedDocuments[$0] }
    }
    private static var receiveDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TransferReceive", isDirectory: true)
    }
    private static var previewDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TransferPreviews", isDirectory: true)
    }
    init() {
        // Receipts are our own verified save records. Legacy string-only receipts
        // remain available for save retry, but are never enough to open a file.
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.receiveDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files.sorted(by: {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }).suffix(FileTransferStore.maxMetadata) {
            guard url.pathExtension == "json", TransferFileRoute.validID(url.deletingPathExtension().lastPathComponent),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(SavedTransferDocument.self, from: data), record.isValid,
                  record.id == url.deletingPathExtension().lastPathComponent else { continue }
            savedDocuments[record.id] = record; savedOrder.append(record.id)
        }
        try? FileManager.default.removeItem(at: Self.previewDirectory)
    }

    func requestOpen(id: String) {
        guard TransferFileRoute.validID(id) else { return }
        showTransfers = true; openedDocument = nil; selection.request(id)
        openMessage = "正在定位所选文件…"
        Task { await resolveRequestedFile() }
    }
    func closeDocument() {
        selection.clear(); openedDocument = nil; openMessage = nil
        try? FileManager.default.removeItem(at: Self.previewDirectory)
    }
    private func resolveRequestedFile(finalizeUnknown: Bool = false) async {
        guard let ticket = selection.begin() else { return }
        let id = ticket.id
        defer {
            if selection.finish(ticket) { Task { await resolveRequestedFile() } }
        }
        guard let record = savedDocuments[id] else {
            if let row = transfers.first(where: { $0.id == id }) {
                if row.stage == .failed || row.stage == .savedElsewhere || row.stage == .saved {
                    openMessage = "此文件未在本机完成保存。请查看传输状态或重新传入。"
                    selection.complete(ticket)
                } else { openMessage = "正在完成所选文件的接收和保存，请保持 iCTRL 在前台。" }
            } else if finalizeUnknown {
                openMessage = "找不到所选文件的保存记录。文件可能已过期、被删除，或尚未传入本机。"
                selection.complete(ticket)
            }
            return
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let source = record.documentURL(in: documents) else {
            openMessage = "所选文件不可用，未打开其他文件。"; selection.complete(ticket); return
        }
        let snapshot = Self.previewDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            guard try await verifiedDocument(record.name, size: record.size, hash: record.sha256, documents: documents) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard selection.isCurrent(ticket) else { return }
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            let target = snapshot.appendingPathComponent(record.name)
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: source, to: target)
            }.value
            guard try await verifiedDocument(record.name, size: record.size, hash: record.sha256, documents: snapshot) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard selection.isCurrent(ticket) else {
                try? FileManager.default.removeItem(at: snapshot); return
            }
            // Preview/share an immutable private copy verified after copying.
            openedDocument = target; openMessage = nil; selection.complete(ticket)
        } catch {
            try? FileManager.default.removeItem(at: snapshot)
            guard selection.isCurrent(ticket) else { return }
            openMessage = "所选文件已删除、被修改或暂时无法读取。未打开其他文件，请重新传入或检查「文件」。"
            selection.complete(ticket)
        }
    }
    private func recordSaved(id: String, name: String, size: Int, hash: String, receipt: URL) async throws {
        let record = SavedTransferDocument(id: id, name: name, size: size, sha256: hash)
        guard record.isValid else { throw CocoaError(.fileReadCorruptFile) }
        try JSONEncoder().encode(record).write(to: receipt, options: .atomic)
        if savedDocuments[id] == nil { savedOrder.append(id) }
        savedDocuments[id] = record
        while savedOrder.count > FileTransferStore.maxMetadata {
            let old = savedOrder.removeFirst(); savedDocuments.removeValue(forKey: old)
            // Prune only our completed receipt, never the user's document.
            try? FileManager.default.removeItem(at: Self.receiveDirectory.appendingPathComponent(old + ".json"))
        }
        TransferNotificationDelegate.postSaved(id: id)
        await resolveRequestedFile()
    }

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
                    if let id = selection.id, savedDocuments[id] == nil {
                        openMessage = "所选文件尚无本机保存记录，且尚未连接服务。连接后可继续接收；未打开其他文件。"
                    }
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
                // A lost file_saved reply may leave the old name-only retry
                // receipt although the server already accepted it. Recover only
                // from authenticated metadata plus a fresh local content check.
                for item in items where item["state"] as? String == "saved" {
                    try await recoverSavedReceipt(item)
                }
                await resolveRequestedFile(finalizeUnknown: true)
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
                } else {
                    status = "暂时无法连接 iCTRL 服务"
                    if let id = selection.id, savedDocuments[id] == nil {
                        openMessage = "暂时无法连接服务以完成保存。请保持 iCTRL 在前台后重试。"
                    }
                }
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

    private func recoverSavedReceipt(_ item: [String: Any]) async throws {
        guard let id = item["id"] as? String, TransferFileRoute.validID(id), savedDocuments[id] == nil,
              item["receipt_source"] as? String == "companion_client_report",
              let name = item["saved_name"] as? String,
              let size = item["size"] as? Int, let hash = item["sha256"] as? String else { return }
        let record = SavedTransferDocument(id: id, name: name, size: size, sha256: hash)
        guard record.isValid else { return }
        let receipt = Self.receiveDirectory.appendingPathComponent(id + ".json")
        guard let data = try? Data(contentsOf: receipt),
              (try? JSONDecoder().decode(String.self, from: data)) == name else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard try await verifiedDocument(name, size: size, hash: hash, documents: documents) else { return }
        try await recordSaved(id: id, name: name, size: size, hash: hash, receipt: receipt)
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
        let cached = (try? Data(contentsOf: receipt)).flatMap { data in
            (try? JSONDecoder().decode(String.self, from: data))
                ?? (try? JSONDecoder().decode(SavedTransferDocument.self, from: data))?.name
        }
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
            try await recordSaved(id: id, name: name, size: size, hash: expected, receipt: receipt)
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
        try await recordSaved(id: id, name: saved.lastPathComponent, size: size, hash: expected, receipt: receipt)
    }
}
