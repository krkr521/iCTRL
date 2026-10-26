import XCTest
import CryptoKit
@testable import NativePolicy

final class FileTransferTests: XCTestCase {
    private func store() -> FileTransferStore {
        FileTransferStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    private func begin(_ store: FileTransferStore, local: Bool = false, size: Int = 3) throws -> String {
        let response = store.call("file_begin", params: ["direction": .string(local ? "phone_to_pc" : "pc_to_phone"), "name": .string("../秘密.txt"), "size": .int(size)], owner: "sender")
        XCTAssertNil(response.error)
        return try XCTUnwrap(response.result?["id"]?.stringValue)
    }
    func testCommitReadAndRealSavedAcknowledgement() throws {
        let s = store(); let id = try begin(s)
        XCTAssertNotNil(s.call("file_read", params: ["id": .string(id), "offset": .int(0), "length": .int(3)], owner: "consumer").error)
        XCTAssertNil(s.call("file_write", params: ["id": .string(id), "offset": .int(0), "data": .string(Data("abc".utf8).base64EncodedString())], owner: "sender").error)
        let hash = SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        let committed = s.call("file_commit", params: ["id": .string(id), "sha256": .string(hash)], owner: "sender")
        XCTAssertEqual(committed.result?["saved"], .bool(false))
        XCTAssertEqual(committed.result?["state"], .string("ready"))
        let lease = try XCTUnwrap(s.call("file_claim", params: ["id": .string(id)], owner: "consumer").result?["lease"]?.stringValue)
        let read = s.call("file_read", params: ["id": .string(id), "lease": .string(lease), "offset": .int(0), "length": .int(3)], owner: "consumer")
        XCTAssertEqual(read.result?["data"], .string("YWJj"))
        XCTAssertNotNil(s.call("file_claim", params: ["id": .string(id)], owner: "other").error)
        XCTAssertNotNil(s.call("file_read", params: ["id": .string(id), "lease": .string(lease), "offset": .int(0), "length": .int(3)], owner: "other").error)
        XCTAssertNotNil(s.call("file_saved", params: ["id": .string(id), "lease": .string(lease), "name": .string("a"), "size": .int(2), "sha256": .string(hash), "recipient": .string("companion")], owner: "consumer").error)
        XCTAssertNotNil(s.call("file_saved", params: ["id": .string(id), "name": .string("a")], owner: "sender").error)
        XCTAssertEqual(s.call("file_saved", params: ["id": .string(id), "lease": .string(lease), "name": .string("秘密.txt"), "size": .int(3), "sha256": .string(hash), "recipient": .string("companion")], owner: "consumer").result?["saved"], .bool(true))
    }
    func testOwnershipOffsetAndQuota() throws {
        let s = store(); let id = try begin(s)
        let params: [String: JSONValue] = ["id": .string(id), "offset": .int(0), "data": .string("YWJj")]
        XCTAssertNotNil(s.call("file_write", params: params, owner: "stranger").error)
        XCTAssertNil(s.call("file_write", params: params, owner: "sender").error)
        XCTAssertNotNil(s.call("file_write", params: params, owner: "sender").error)
        XCTAssertNotNil(s.call("file_begin", params: ["direction": .string("pc_to_phone"), "name": .string("a"), "size": .int(FileTransferStore.maxFile + 1)], owner: "sender").error)
    }
    func testExplicitQueuesOnlyAndEmptyFile() throws {
        let s = store(); let id = try begin(s, size: 0)
        let hash = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        XCTAssertNil(s.call("file_commit", params: ["id": .string(id), "sha256": .string(hash)], owner: "sender").error)
        XCTAssertEqual(s.call("file_list", params: ["direction": .string("phone_to_pc")], owner: "remote").result?["files"], .array([]))
        XCTAssertFalse(FileTransferStore.safeName("../a:b\\c").contains("/"))
        XCTAssertEqual(FileTransferStore.safeName(".."), "download")
    }
    private func complete(_ store: FileTransferStore, bytes: Data) throws -> String {
        let id = try begin(store, size: bytes.count)
        if !bytes.isEmpty {
            XCTAssertNil(store.call("file_write", params: ["id": .string(id), "offset": .int(0), "data": .string(bytes.base64EncodedString())], owner: "sender").error)
        }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertNil(store.call("file_commit", params: ["id": .string(id), "sha256": .string(hash)], owner: "sender").error)
        let lease = try XCTUnwrap(store.call("file_claim", params: ["id": .string(id)], owner: "receiver").result?["lease"]?.stringValue)
        XCTAssertNil(store.call("file_saved", params: ["id": .string(id), "lease": .string(lease), "name": .string("saved"), "size": .int(bytes.count), "sha256": .string(hash), "recipient": .string("companion")], owner: "receiver").error)
        return id
    }
    func testSuccessfulSavesReleaseLiveByteQuota() throws {
        let s = FileTransferStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), liveByteLimit: 3)
        _ = try complete(s, bytes: Data("abc".utf8))
        _ = try complete(s, bytes: Data("def".utf8))
        _ = try complete(s, bytes: Data("ghi".utf8))
    }
    func testEmptySavedReceiptsRemainBoundedWithoutEvictingLiveTransfers() throws {
        let s = store(); let live = try begin(s, size: 1)
        var oldest = ""; var newest = ""
        for index in 0..<(FileTransferStore.maxMetadata + 20) {
            newest = try complete(s, bytes: Data())
            if index == 0 { oldest = newest }
            XCTAssertLessThanOrEqual(s.retainedMetadataCount, FileTransferStore.maxMetadata)
        }
        XCTAssertNotNil(s.call("file_status", params: ["id": .string(oldest)], owner: "sender").error)
        XCTAssertNil(s.call("file_status", params: ["id": .string(newest)], owner: "sender").error)
        XCTAssertNil(s.call("file_status", params: ["id": .string(live)], owner: "sender").error)
    }
    func testPartiallyFailedWriteRollsBackBeforeRetry() throws {
        var first = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let s = FileTransferStore(directory: directory, writeChunk: { handle, data in
            if first {
                first = false
                try handle.write(contentsOf: Data(data.prefix(1)))
                throw CocoaError(.fileWriteUnknown)
            }
            try handle.write(contentsOf: data)
        })
        let id = try begin(s)
        let params: [String: JSONValue] = ["id": .string(id), "offset": .int(0), "data": .string("YWJj")]
        XCTAssertNotNil(s.call("file_write", params: params, owner: "sender").error)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(id)), Data())
        XCTAssertEqual(s.call("file_status", params: ["id": .string(id)], owner: "sender").result?["received"], .int(0))
        XCTAssertNil(s.call("file_write", params: params, owner: "sender").error)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(id)), Data("abc".utf8))
    }

    func testDeleteChecksumAndSweepFailuresRetainQuotaUntilCleanupSucceeds() throws {
        for path in ["delete", "checksum", "sweep"] {
            var failRemoval = true
            var clock = Date()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let s = FileTransferStore(directory: directory, liveByteLimit: 3, removeSpool: { url in
                if failRemoval { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            }, now: { clock })
            let id = try begin(s)
            switch path {
            case "delete":
                XCTAssertNotNil(s.call("file_delete", params: ["id": .string(id)], owner: "sender").error)
            case "checksum":
                XCTAssertNil(s.call("file_write", params: ["id": .string(id), "offset": .int(0), "data": .string("YWJj")], owner: "sender").error)
                XCTAssertNotNil(s.call("file_commit", params: ["id": .string(id), "sha256": .string(String(repeating: "0", count: 64))], owner: "sender").error)
            default:
                clock = clock.addingTimeInterval(1801)
                _ = s.call("file_list", params: ["direction": .string("pc_to_phone")], owner: "sender")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id).path))
            XCTAssertEqual(s.retainedMetadataCount, 1)
            XCTAssertNotNil(s.call("file_begin", params: ["direction": .string("pc_to_phone"), "name": .string("blocked"), "size": .int(1)], owner: "sender").error)
            failRemoval = false
            // Sweep may already have removed an expired item before delete.
            _ = s.call("file_delete", params: ["id": .string(id)], owner: "sender")
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id).path))
            XCTAssertEqual(s.retainedMetadataCount, 0)
            _ = try begin(s)
        }
    }

}
