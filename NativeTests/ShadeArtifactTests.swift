import XCTest
@testable import NativePolicy

final class ShadeArtifactTests: XCTestCase {
    private func request(offset: Int = 0, length: Int = 0) throws -> ShadeArtifactRequest {
        try XCTUnwrap(ShadeArtifactRequest(["artifact": .string("automation_ui"),
            "offset": .int(offset), "length": .int(length)]))
    }
    private func fixture(_ data: Data, body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture")
        try data.write(to: url)
        try body(url)
    }
    private let image = Data([0xcf, 0xfa, 0xed, 0xfe, 1, 2, 3, 4, 5, 6])

    func testRejectsPathSubstitutionAndInvalidRangesBeforeOpening() {
        let variants: [[String: JSONValue]] = [
            [:], ["artifact": .string("/private/file")],
            ["artifact": .string("automation_ui"), "path": .string("/private/file")],
            ["artifact": .string("automation_ui"), "offset": .int(-1)],
            ["artifact": .string("automation_ui"), "offset": .int(2 * 1024 * 1024 + 1)],
            ["artifact": .string("automation_ui"), "length": .int(48 * 1024 + 1)],
            ["artifact": .string("automation_ui"), "length": .bool(true)],
        ]
        for params in variants { XCTAssertNil(ShadeArtifactRequest(params)) }
    }

    func testMetadataDefaultDoesNotReturnBinaryPayload() throws {
        try fixture(image) { url in
            let result = ShadeArtifactReader.read(try request(), open: { try FileHandle(forReadingFrom: url) })
            XCTAssertEqual(result["status"]?.stringValue, "available")
            XCTAssertEqual(result["size"]?.intValue, image.count)
            XCTAssertNil(result["data_base64"])
        }
    }

    func testChunkAndEOFAreReadFromSameValidatedHandle() throws {
        try fixture(image) { url in
            let middle = ShadeArtifactReader.read(try request(offset: 4, length: 3), open: { try FileHandle(forReadingFrom: url) })
            XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(middle["data_base64"]?.stringValue)), Data([1, 2, 3]))
            XCTAssertEqual(middle["eof"]?.boolValue, false)
            let tail = ShadeArtifactReader.read(try request(offset: 8, length: 20), open: { try FileHandle(forReadingFrom: url) })
            XCTAssertEqual(tail["length"]?.intValue, 2)
            XCTAssertEqual(tail["eof"]?.boolValue, true)
            let invalid = ShadeArtifactReader.read(try request(offset: 11), open: { try FileHandle(forReadingFrom: url) })
            XCTAssertEqual(invalid["status"]?.stringValue, "invalid_range")
            XCTAssertNil(invalid["data_base64"])
        }
    }

    func testReadDenialReturnsOnlyFixedFailure() throws {
        let result = ShadeArtifactReader.read(try request(), open: {
            throw NSError(domain: "private-path-must-not-appear", code: 1)
        })
        XCTAssertEqual(result["status"]?.stringValue, "not_readable")
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-path-must-not-appear"))
        XCTAssertNil(result["data_base64"])
    }

    func testNonMachOAndOversizedFilesReturnNoBytes() throws {
        for (data, status) in [(Data("not a system binary".utf8), "not_macho"),
            (Data(repeating: 0, count: ShadeArtifactRequest.maximumFileBytes + 1), "size_limit")] {
            try fixture(data) { url in
                let result = ShadeArtifactReader.read(try request(length: 8), open: { try FileHandle(forReadingFrom: url) })
                XCTAssertEqual(result["status"]?.stringValue, status)
                XCTAssertNil(result["data_base64"])
            }
        }
    }

    func testDiagnosticsOnlyAvailableInDebugRegistry() {
        #if DEBUG
        XCTAssertTrue(DevelopmentRPCMethods.readOnlyNames.contains("shade_system_artifact"))
        XCTAssertFalse(QuietRPCMethodDefinitions.requiresUIGate("shade_system_artifact"))
        XCTAssertTrue(DevelopmentRPCMethods.methods.contains(where: { $0.name == "shade_system_artifact" }))
        #else
        XCTAssertFalse(DevelopmentRPCMethods.readOnlyNames.contains("shade_system_artifact"))
        XCTAssertFalse(DevelopmentRPCMethods.methods.contains(where: { $0.name == "shade_system_artifact" }))
        #endif
    }

    func testNonRegularDescriptorIsRejectedBeforeReading() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        let result = ShadeArtifactReader.read(try request(length: 8), open: { pipe.fileHandleForReading })
        XCTAssertEqual(result["status"]?.stringValue, "not_regular_file")
        XCTAssertNil(result["data_base64"])
    }
}
