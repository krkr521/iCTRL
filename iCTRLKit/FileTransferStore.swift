import Foundation
import CryptoKit

/// Queue of explicitly transferred files only. No caller supplies a disk path.
final class FileTransferStore {
    static let maxFile = 256 * 1024 * 1024
    static let chunkSize = 192 * 1024
    static let maxMetadata = 64
    static let savedTTL: TimeInterval = 300
    private struct Item {
        let id: String, owner: String, direction: String, name: String, size: Int, url: URL
        var received = 0
        var holdsSpool = true
        var digest = SHA256()
        var hash = ""
        var state = "uploading"
        var savedName: String?
        var claimant: String?
        var lease: String?
        var leaseExpires = Date.distantPast
        var receiptSource: String?
        var savedAt: Date?
        var created = Date()
    }
    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private let directory: URL
    private let liveByteLimit: Int
    private let writeChunk: (FileHandle, Data) throws -> Void
    private let removeSpool: (URL) throws -> Void
    private let now: () -> Date
    var retainedMetadataCount: Int {
        lock.lock(); defer { lock.unlock() }; return items.count
    }
    init(directory: URL? = nil, liveByteLimit: Int = FileTransferStore.maxFile * 2,
         writeChunk: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) },
         removeSpool: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
         now: @escaping () -> Date = Date.init) {
        self.liveByteLimit = liveByteLimit
        self.writeChunk = writeChunk
        self.removeSpool = removeSpool
        self.now = now
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iCTRL/Transfers", isDirectory: true)
        // Transfers intentionally do not survive process restart: avoid exposing
        // stale queues or trusting metadata restored without authentication.
        try? FileManager.default.removeItem(at: self.directory)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var root = self.directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }
    static func safeName(_ input: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:<>\"|?*").union(.controlCharacters)
        let cleaned = input.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
        let value = String(cleaned.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return value.isEmpty ? "download" : value
    }
    private struct Failure: Error { let message: String }
    private func fail(_ message: String) throws -> Never { throw Failure(message: message) }
    /// Keep the reservation and metadata if the disk still holds spool bytes.
    @discardableResult
    private func clean(_ id: String, removeRecord: Bool = true) -> Bool {
        guard var item = items[id] else { return true }
        if item.holdsSpool {
            do { try removeSpool(item.url) }
            catch {
                let failure = error as NSError
                let missing = (failure.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)) ||
                    (failure.domain == NSPOSIXErrorDomain && failure.code == 2)
                guard missing else { item.state = "failed"; items[id] = item; return false }
            }
            item.holdsSpool = false
        }
        if removeRecord { items.removeValue(forKey: id) } else { items[id] = item }
        return true
    }
    private func sweep() {
        let now = now()
        let expired = items.values.filter {
            now.timeIntervalSince($0.created) > 1800 ||
            ($0.savedAt.map { now.timeIntervalSince($0) > Self.savedTTL } ?? false)
        }.map(\.id)
        for id in expired {
            clean(id)
        }
    }
    private func reserveMetadataSlot() throws {
        if items.count >= Self.maxMetadata {
            // Saved receipts are bounded tombstones. Prefer evicting the oldest
            // receipt; never discard an in-progress or ready file to make room.
            if let oldest = items.values.filter({ $0.state == "saved" }).min(by: { ($0.savedAt ?? $0.created) < ($1.savedAt ?? $1.created) }) {
                items.removeValue(forKey: oldest.id)
            }
        }
        guard items.count < Self.maxMetadata else { try fail("Transfer metadata queue is full") }
    }
    func call(_ method: String, params p: [String: JSONValue], owner: String) -> (result: [String: JSONValue]?, error: JSONRPCError?) {
        lock.lock(); defer { lock.unlock() }
        sweep()
        do { return (try execute(method, p, owner), nil) }
        catch let failure as Failure { return (nil, JSONRPCError(code: -32050, message: failure.message, data: nil)) }
        catch { return (nil, JSONRPCError(code: -32050, message: "File operation failed", data: nil)) }
    }
    private func execute(_ method: String, _ p: [String: JSONValue], _ owner: String) throws -> [String: JSONValue] {
        if method == "file_begin" {
            guard let direction = p["direction"]?.stringValue,
                  ["phone_to_pc", "pc_to_phone"].contains(direction),
                  let name = p["name"]?.stringValue, !name.isEmpty, name.utf8.count <= 1024,
                  let size = p["size"]?.transferInteger, size >= 0, size <= Self.maxFile else { try fail("Invalid file metadata or direction") }
            guard items.values.filter({ $0.state != "saved" }).count < 4,
                  items.values.filter(\.holdsSpool).reduce(0, { $0 + $1.size }) + size <= liveByteLimit else { try fail("Transfer queue is full") }
            try reserveMetadataSlot()
            let id = UUID().uuidString
            let url = directory.appendingPathComponent(id)
            var attributes: [FileAttributeKey: Any]? = nil
            #if os(iOS)
            attributes = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            #endif
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes) else { try fail("Cannot create transfer") }
            items[id] = Item(id: id, owner: owner, direction: direction, name: Self.safeName(name), size: size, url: url)
            // Tests may inject time; production uses wall-clock dates.
            items[id]?.created = now()
            return ["id": .string(id), "chunk_size": .int(Self.chunkSize), "max_file_size": .int(Self.maxFile)]
        }
        if method == "file_list" {
            guard let direction = p["direction"]?.stringValue, ["phone_to_pc", "pc_to_phone"].contains(direction) else { try fail("Specify transfer direction") }
            if let value = p["include_progress"], value.boolValue == nil { try fail("include_progress must be boolean") }
            let progress = p["include_progress"]?.boolValue == true
            let list = items.values.filter {
                $0.direction == direction && (progress || ($0.state == "ready" && ($0.leaseExpires < Date() || $0.claimant == owner)))
            }.sorted { $0.created < $1.created }
            return ["files": .array(list.map { item in
                var values = metadata(item)
                if progress { values["can_receive"] = .bool(item.state == "ready" && (item.leaseExpires < Date() || item.claimant == owner)) }
                return .object(values)
            })]
        }
        guard let id = p["id"]?.stringValue, var item = items[id] else { try fail("Transfer unavailable") }
        let owns = item.owner == owner
        // Every already-paired controller is user-trusted. Client purpose,
        // network address and URL scheme are not authenticated app identities.
        let consumer = item.claimant == owner && item.leaseExpires > Date() && p["lease"]?.stringValue == item.lease
        switch method {
        case "file_status": return metadata(item)
        case "file_claim":
            guard item.state == "ready", item.leaseExpires < Date() || item.claimant == owner else { try fail("Transfer is already being received") }
            if item.claimant != owner || item.leaseExpires < Date() { item.lease = UUID().uuidString }
            item.claimant = owner; item.leaseExpires = Date().addingTimeInterval(300); items[id] = item
            var result = metadata(item); result["lease"] = .string(item.lease!); result["lease_expires_in"] = .int(300)
            return result
        case "file_write":
            guard owns, item.state == "uploading", let offset = p["offset"]?.transferInteger, offset == item.received,
                  let encoded = p["data"]?.stringValue, encoded.utf8.count <= (Self.chunkSize + 2) / 3 * 4,
                  let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= Self.chunkSize,
                  data.count <= item.size - item.received else { try fail("Invalid chunk or offset") }
            let handle = try FileHandle(forWritingTo: item.url); defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(item.received))
            do {
                try writeChunk(handle, data)
            } catch {
                // A failed write may have appended a prefix. Roll back before
                // accepting a retry at the same authenticated logical offset.
                do { try handle.truncate(atOffset: UInt64(item.received)) }
                catch {
                    item.state = "failed"; items[id] = item
                    clean(id, removeRecord: false)
                }
                try fail("File chunk write failed")
            }
            item.digest.update(data: data); item.received += data.count; items[id] = item
            return ["offset": .int(item.received)]
        case "file_commit":
            guard owns, item.state == "uploading", item.received == item.size,
                  let expected = p["sha256"]?.stringValue, expected.count == 64 else { try fail("Incomplete transfer") }
            let hash = item.digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard hash == expected.lowercased() else {
                item.state = "failed"; items[id] = item
                clean(id)
                try fail("File checksum mismatch")
            }
            item.hash = hash; item.state = "ready"; items[id] = item
            return metadata(item)
        case "file_read":
            guard consumer, item.state == "ready", let offset = p["offset"]?.transferInteger, offset >= 0, offset <= item.size,
                  let length = p["length"]?.transferInteger, length > 0, length <= Self.chunkSize else { try fail("Invalid read") }
            item.leaseExpires = Date().addingTimeInterval(300); items[id] = item
            let handle = try FileHandle(forReadingFrom: item.url); defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: min(length, item.size - offset)) ?? Data()
            return ["data": .string(data.base64EncodedString()), "offset": .int(offset), "eof": .bool(offset + data.count == item.size)]
        case "file_saved":
            guard consumer, item.state == "ready", let name = p["name"]?.stringValue,
                  p["size"]?.transferInteger == item.size, p["sha256"]?.stringValue == item.hash,
                  let recipient = p["recipient"]?.stringValue, ["companion", "computer"].contains(recipient) else { try fail("Cannot acknowledge transfer") }
            // Release spool bytes before marking the transfer saved; a failed
            // unlink must retain its reservation and remain retryable.
            guard clean(id, removeRecord: false) else { try fail("Cannot remove transfer spool; retry cleanup") }
            item.holdsSpool = false
            item.state = "saved"; item.savedName = Self.safeName(name)
            item.receiptSource = recipient + "_client_report"; item.savedAt = Date(); items[id] = item
            return metadata(item)
        case "file_delete":
            guard owns || consumer else { try fail("Transfer unavailable") }
            guard clean(id) else { try fail("Cannot remove transfer spool; retry cleanup") }
            return ["deleted": .bool(true)]
        default: try fail("Unknown file method")
        }
    }
    private func metadata(_ item: Item) -> [String: JSONValue] {
        var result: [String: JSONValue] = ["id": .string(item.id), "name": .string(item.name), "size": .int(item.size), "received": .int(item.received), "direction": .string(item.direction), "state": .string(item.state), "sha256": .string(item.hash), "saved": .bool(item.state == "saved")]
        if let name = item.savedName { result["saved_name"] = .string(name) }
        if let source = item.receiptSource { result["receipt_source"] = .string(source); result["process_identity_verified"] = .bool(false) }
        return result
    }
}

private extension JSONValue {
    var transferInteger: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
}
