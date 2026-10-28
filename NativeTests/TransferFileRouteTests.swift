import XCTest
@testable import NativePolicy

final class TransferFileRouteTests: XCTestCase {
    private let id = "3F0BFF1D-183F-444C-B435-A372B3C1D052"
    func testOpaqueIDRoundTripsWithoutPathsOrNames() throws {
        let url = try XCTUnwrap(TransferFileRoute.url(id: id))
        XCTAssertEqual(TransferFileRoute.parse(url), id)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count, 1)
        XCTAssertNil(TransferFileRoute.url(id: "../../private/file"))
    }
    func testUntrustedRouteShapesAreRejected() {
        for value in ["ictrl-app://files?id=bad", "ictrl-app://files/path?id=\(id)",
                      "ictrl-app://files?id=\(id)&path=/etc/passwd", "ictrl-app://files?id=\(id)&id=\(id)",
                      "https://files?id=\(id)", "ictrl-app://files?id=\(id)#extra", "ictrl-app://user@files?id=\(id)"] {
            XCTAssertNil(TransferFileRoute.parse(URL(string: value)!))
        }
    }
    func testOnlyBodyOrViewActionRoutesToSelectedFile() {
        for action in [TransferFileRoute.openAction, "DEFAULT"] {
            XCTAssertEqual(TransferFileRoute.selectedID(category: TransferFileRoute.category, action: action,
                defaultAction: "DEFAULT", payloadID: id), id)
        }
        for action in ["DISMISS", "UNKNOWN", ""] {
            XCTAssertNil(TransferFileRoute.selectedID(category: TransferFileRoute.category, action: action,
                defaultAction: "DEFAULT", payloadID: id))
        }
        XCTAssertNil(TransferFileRoute.selectedID(category: "other", action: "DEFAULT", defaultAction: "DEFAULT", payloadID: id))
        XCTAssertNil(TransferFileRoute.selectedID(category: TransferFileRoute.category, action: "DEFAULT", defaultAction: "DEFAULT", payloadID: nil))
    }
    func testSavedRecordSurvivesColdLaunchEncoding() throws {
        let record = SavedTransferDocument(id: id, name: "安装包 (1).ipa", size: 42, sha256: String(repeating: "a", count: 64))
        let restored = try JSONDecoder().decode(SavedTransferDocument.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, record)
        XCTAssertTrue(restored.isValid)
    }
    func testMissingMetadataNeverBecomesFileNameGuess() {
        for name in ["../secret", "/tmp/secret", "..", "folder/file", "folder\\file", ""] {
            XCTAssertFalse(SavedTransferDocument(id: id, name: name, size: 1, sha256: String(repeating: "a", count: 64)).isValid)
        }
        XCTAssertFalse(SavedTransferDocument(id: id, name: "file", size: -1, sha256: String(repeating: "a", count: 64)).isValid)
        XCTAssertFalse(SavedTransferDocument(id: id, name: "file", size: 1, sha256: "not-a-hash").isValid)
    }
    func testDocumentURLStaysInDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = SavedTransferDocument(id: id, name: "file.ipa", size: 1, sha256: String(repeating: "a", count: 64))
        XCTAssertEqual(record.documentURL(in: root), root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("file.ipa"))
        XCTAssertNil(record.documentURL(in: URL(string: "https://example.com")!))
    }
    func testSymlinkCannotEscapeDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file.ipa"), withDestinationURL: outside)
        let record = SavedTransferDocument(id: id, name: "file.ipa", size: 1, sha256: String(repeating: "a", count: 64))
        XCTAssertNil(record.documentURL(in: root))
    }
    func testNewSelectionDuringAwaitIsRetriedWithoutServerPoll() throws {
        var selection = TransferFileSelection()
        selection.request("A")
        let a = try XCTUnwrap(selection.begin())
        // A is paused at its file verification/copy await. B's immediate resolver
        // cannot run yet; A's completion must arrange B locally, even offline.
        selection.request("B")
        XCTAssertNil(selection.begin())
        XCTAssertFalse(selection.isCurrent(a))
        selection.complete(a)
        XCTAssertEqual(selection.id, "B")
        XCTAssertTrue(selection.finish(a))
        let b = try XCTUnwrap(selection.begin())
        XCTAssertEqual(b.id, "B")
        XCTAssertTrue(selection.isCurrent(b))
        selection.complete(b)
        XCTAssertFalse(selection.finish(b))
        XCTAssertNil(selection.id)
    }
    func testClosingDuringAwaitDoesNotReopenOrReplay() throws {
        var selection = TransferFileSelection()
        selection.request("A")
        let ticket = try XCTUnwrap(selection.begin())
        selection.clear()
        XCTAssertFalse(selection.isCurrent(ticket))
        XCTAssertFalse(selection.finish(ticket))
        XCTAssertNil(selection.begin())
    }

}
