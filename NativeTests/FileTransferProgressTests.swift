import XCTest
import CryptoKit
@testable import NativePolicy

final class FileTransferProgressTests: XCTestCase {
    private let id = "42AB0769-0463-4420-BDBF-1ABFCBDFBE98"
    private func firstFile(_ result: [String: JSONValue]?) throws -> [String: JSONValue] {
        guard case let .array(values)? = result?["files"] else { throw CocoaError(.fileReadCorruptFile) }
        return try XCTUnwrap(values.first?.objectValue)
    }
    private func metadata(state: String = "uploading", size: Int = 10, received: Int = 5) -> [String: JSONValue] {
        ["id": .string(id), "name": .string("private-file-name.txt"), "size": .int(size),
         "received": .int(received), "state": .string(state), "direction": .string("pc_to_phone")]
    }
    func testFullUploadAndCommitDoNotClaimSaved() throws {
        let uploading = try XCTUnwrap(FileTransferProgress(metadata: metadata(received: 10)))
        XCTAssertEqual(uploading.fraction, 1)
        XCTAssertEqual(uploading.stage, .verifying)
        let ready = try XCTUnwrap(FileTransferProgress(metadata: metadata(state: "ready", received: 10)))
        XCTAssertEqual(ready.stage, .waiting)
        XCTAssertTrue(ready.isActive)
    }
    func testEmptyFileDoesNotDivideOrClaimSaved() throws {
        let empty = try XCTUnwrap(FileTransferProgress(metadata: metadata(state: "ready", size: 0, received: 0)))
        XCTAssertEqual(empty.fraction, 0)
        XCTAssertEqual(empty.stage, .waiting)
        XCTAssertTrue(empty.fraction.isFinite)
    }
    func testInvalidProgressIsRejected() {
        XCTAssertNil(FileTransferProgress(metadata: metadata(size: 1, received: 2)))
        XCTAssertNil(FileTransferProgress(metadata: metadata(size: -1, received: 0)))
        XCTAssertNil(FileTransferProgress(metadata: metadata(state: "ready", received: 5)))
        XCTAssertNil(FileTransferProgress(metadata: metadata(state: "saved", received: 10)))
        var invalid = metadata(); invalid["received"] = .double(1e100)
        XCTAssertNil(FileTransferProgress(metadata: invalid))
    }
    func testComputerReportIsNotDisplayedAsPhoneSave() throws {
        var value = metadata(state: "saved", received: 10)
        value["saved"] = .bool(true); value["receipt_source"] = .string("computer_client_report")
        XCTAssertEqual(try XCTUnwrap(FileTransferProgress(metadata: value)).stage, .savedElsewhere)
        value["receipt_source"] = .string("companion_client_report")
        XCTAssertEqual(try XCTUnwrap(FileTransferProgress(metadata: value)).stage, .saved)
    }
    func testNotificationsContainNoFileMetadataAndNoChunkEvents() throws {
        let begin = try XCTUnwrap(FileTransferNotice.event(method: "file_begin", params: ["direction": .string("pc_to_phone")], result: ["id": .string(id)]))
        XCTAssertFalse((begin.title + begin.body).contains("private-file-name"))
        XCTAssertNil(FileTransferNotice.event(method: "file_write", params: [:], result: metadata()))
        var ready = metadata(state: "ready", received: 10)
        XCTAssertEqual(FileTransferNotice.event(method: "file_commit", params: [:], result: ready)?.stage, .ready)
        XCTAssertNil(FileTransferNotice.event(method: "file_saved", params: [:], result: ready))
        ready["state"] = .string("saved"); ready["saved"] = .bool(true)
        ready["receipt_source"] = .string("computer_client_report")
        XCTAssertNil(FileTransferNotice.event(method: "file_saved", params: [:], result: ready))
        ready["receipt_source"] = .string("companion_client_report")
        XCTAssertEqual(FileTransferNotice.event(method: "file_saved", params: [:], result: ready)?.stage, .saved)
        ready["direction"] = .string("phone_to_pc")
        XCTAssertNil(FileTransferNotice.event(method: "file_commit", params: [:], result: ready))
    }

    func testProgressSnapshotKeepsDefaultReadyListAndClaimBoundary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileTransferStore(directory: directory)
        let begin = store.call("file_begin", params: ["direction": .string("pc_to_phone"), "name": .string("a"), "size": .int(3)], owner: "sender")
        let id = try XCTUnwrap(begin.result?["id"]?.stringValue)
        let base: [String: JSONValue] = ["direction": .string("pc_to_phone")]
        let progress: [String: JSONValue] = ["direction": .string("pc_to_phone"), "include_progress": .bool(true)]
        XCTAssertEqual(store.call("file_list", params: base, owner: "viewer").result?["files"], .array([]))
        let uploading = try firstFile(store.call("file_list", params: progress, owner: "viewer").result)
        XCTAssertEqual(uploading["received"], .int(0))
        XCTAssertEqual(uploading["can_receive"], .bool(false))
        XCTAssertNil(uploading["owner"]); XCTAssertNil(uploading["lease"])
        _ = store.call("file_write", params: ["id": .string(id), "offset": .int(0), "data": .string("YWJj")], owner: "sender")
        let hash = SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        _ = store.call("file_commit", params: ["id": .string(id), "sha256": .string(hash)], owner: "sender")
        _ = store.call("file_claim", params: ["id": .string(id)], owner: "receiver")
        XCTAssertEqual(store.call("file_list", params: base, owner: "viewer").result?["files"], .array([]))
        let leased = try firstFile(store.call("file_list", params: progress, owner: "viewer").result)
        XCTAssertEqual(leased["can_receive"], .bool(false))
        XCTAssertNil(leased["lease"]); XCTAssertNil(leased["claimant"])
        XCTAssertNotNil(store.call("file_list", params: ["direction": .string("pc_to_phone"), "include_progress": .string("true")], owner: "viewer").error)
    }

    func testCollisionNamesPreserveSuffixAndRoundTripSafely() {
        for original in [String(repeating: "a", count: 116) + ".ipa", String(repeating: "😀", count: 100) + ".zip", "a." + String(repeating: "x", count: 118), "e" + String(repeating: "\u{0301}", count: 200) + ".txt", String(repeating: "😀", count: 59) + "    aaaaaaaaaa"] {
            let first = TransferDestinationName.make(original, collision: 0)
            let other = TransferDestinationName.make(original, collision: 1)
            XCTAssertNotEqual(first, other)
            for index in [0, 1, 9999] {
                let name = TransferDestinationName.make(original, collision: index)
                XCTAssertLessThanOrEqual(name.count, 120)
                XCTAssertLessThanOrEqual(name.unicodeScalars.count, 120)
                XCTAssertLessThanOrEqual(name.utf8.count, 240)
                XCTAssertEqual(FileTransferStore.safeName(name), name)
                XCTAssertTrue(TransferDestinationName.validComponent(name))
            }
        }
        XCTAssertFalse(TransferDestinationName.validComponent("../outside"))
        XCTAssertFalse(TransferDestinationName.validComponent(".."))
    }
    func testTransferBannersRespectAutomationAndDoNotAlertForEveryChunk() {
        for stage in [FileTransferNotice.Stage.receiving, .ready, .saved] {
            XCTAssertFalse(FileTransferNotice.permitsBanner(stage: stage, automationActive: true))
        }
        XCTAssertFalse(FileTransferNotice.permitsBanner(stage: .receiving, automationActive: false))
        XCTAssertTrue(FileTransferNotice.permitsBanner(stage: .ready, automationActive: false))
        XCTAssertTrue(FileTransferNotice.permitsBanner(stage: .saved, automationActive: false))
    }
}
