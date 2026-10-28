import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Debug-only RPC input. No path is accepted from a client.
struct ShadeArtifactRequest {
    static let maximumFileBytes = 2 * 1024 * 1024
    static let maximumChunkBytes = 48 * 1024
    let artifact: String
    let offset: Int
    let length: Int

    init?(_ params: [String: JSONValue]) {
        guard params.keys.allSatisfy({ ["artifact", "offset", "length"].contains($0) }),
              let artifact = params["artifact"]?.stringValue,
              ["automation_ui", "event_synthesis"].contains(artifact) else { return nil }
        var offset = 0, length = 0
        if let value = params["offset"] {
            guard case let .int(number) = value else { return nil }
            offset = number
        }
        if let value = params["length"] {
            guard case let .int(number) = value else { return nil }
            length = number
        }
        guard offset >= 0, offset <= Self.maximumFileBytes,
              length >= 0, length <= Self.maximumChunkBytes else { return nil }
        self.artifact = artifact; self.offset = offset; self.length = length
    }
}

enum ShadeArtifactReader {
    private static let systemPath = "/System/Library/PrivateFrameworks/AutomationMode.framework/AutomationModeUI.app/AutomationModeUI"

    static func read(_ request: ShadeArtifactRequest) -> [String: JSONValue] {
        read(request, open: { try FileHandle(forReadingFrom: URL(fileURLWithPath: systemPath)) })
    }

    /// The injected opener is only for local fixture tests, never an RPC input.
    static func read(_ request: ShadeArtifactRequest, open: () throws -> FileHandle) -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "artifact": .string(request.artifact),
            "system_version_description": .string(ProcessInfo.processInfo.operatingSystemVersionString),
        ]
        // Retain the request name for compatibility, but do not inspect the
        // Objective-C runtime or open an image for this disabled diagnostic.
        guard request.artifact == "automation_ui" else {
            result["status"] = .string("unavailable")
            result["reason"] = .string("diagnostic_disabled")
            return result
        }
        func failure(_ status: String) -> [String: JSONValue] {
            var failed = result; failed["status"] = .string(status); return failed
        }
        let handle: FileHandle
        do { handle = try open() } catch { return failure("not_readable") }
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(handle.fileDescriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            return failure("not_regular_file")
        }
        let size = Int64(attributes.st_size)
        guard size >= 4, size <= Int64(ShadeArtifactRequest.maximumFileBytes) else { return failure("size_limit") }
        guard Int64(request.offset) <= size else { return failure("invalid_range") }
        do {
            let magic = try handle.read(upToCount: 4) ?? Data()
            let allowed: [[UInt8]] = [
                [0xcf, 0xfa, 0xed, 0xfe], [0xce, 0xfa, 0xed, 0xfe],
                [0xfe, 0xed, 0xfa, 0xcf], [0xfe, 0xed, 0xfa, 0xce],
                [0xca, 0xfe, 0xba, 0xbe], [0xca, 0xfe, 0xba, 0xbf],
                [0xbe, 0xba, 0xfe, 0xca], [0xbf, 0xba, 0xfe, 0xca],
            ]
            guard allowed.contains(Array(magic)) else { return failure("not_macho") }
            result["status"] = .string("available")
            result["size"] = .int(Int(size))
            result["offset"] = .int(request.offset)
            if request.length == 0 { return result }
            let count = min(request.length, Int(size) - request.offset)
            try handle.seek(toOffset: UInt64(request.offset))
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { return failure("read_incomplete") }
            result["length"] = .int(data.count)
            result["data_base64"] = .string(data.base64EncodedString())
            result["eof"] = .bool(request.offset + data.count == Int(size))
            return result
        } catch {
            // Error descriptions can contain paths; return a finite status only.
            return failure("read_failed")
        }
    }
}
