import XCTest
@testable import NativePolicy

final class RunnerProfileMetadataTests: XCTestCase {
    private let requestID = "11111111-2222-3333-4444-555555555555"
    private var valid: [String: JSONValue] { [
        "server_running": .bool(true), "runner_profile_expiry_available": .bool(true),
        "runner_profile_expires_at": .string("2026-11-02T12:37:33Z"),
        "bundle_id": .string("com.openminis.ictrl.uitests.xctrunner"),
        "team_identifier": .string("ABCDE12345"),
    ] }
    private func parse(_ fields: [String: JSONValue]) throws -> [String: JSONValue] {
        try RunnerProfileMetadata.parse(fields, companionBundleID: "com.openminis.ictrl",
            companionTeam: "ABCDE12345", requestID: requestID,
            observedAt: Date(timeIntervalSince1970: 100))
    }
    func testFreshAuthenticatedMetadataHasExplicitProvenanceAndNarrowOutput() throws {
        var fields = valid
        fields["companion_metadata_source"] = .string("unavailable")
        fields["unrelated"] = .string("must not be forwarded")
        let report = try parse(fields)
        XCTAssertEqual(report["runner_metadata_source"], .string("authenticated_loopback_runtime_status"))
        XCTAssertEqual(report["runner_metadata_request_id"], .string(requestID))
        XCTAssertEqual(report["runner_profile_expiry_verified"], .bool(true))
        XCTAssertEqual(report["runner_profile_expires_at"], valid["runner_profile_expires_at"])
        XCTAssertNil(report["unrelated"])
        XCTAssertNil(report["companion_metadata_source"])
    }
    func testUnavailableInvalidAndWrongTypedMetadataNeverVerifies() {
        let mutations: [(String, JSONValue)] = [
            ("server_running", .bool(false)), ("server_running", .int(1)),
            ("runner_profile_expiry_available", .bool(false)), ("runner_profile_expiry_available", .string("true")),
            ("runner_profile_expires_at", .null), ("runner_profile_expires_at", .string("yesterday")),
            ("bundle_id", .string("")), ("bundle_id", .string("com.openminis.ictrl")),
            ("bundle_id", .string("bad/bundle")), ("team_identifier", .string("OTHER12345")),
            ("team_identifier", .string("bad"))
        ]
        for (key, value) in mutations {
            var fields = valid; fields[key] = value
            XCTAssertThrowsError(try parse(fields), key)
        }
        for key in valid.keys {
            var fields = valid; fields.removeValue(forKey: key)
            XCTAssertThrowsError(try parse(fields), key)
        }
    }
    func testIdentityAndObservationCannotBeInvented() {
        XCTAssertThrowsError(try RunnerProfileMetadata.parse(valid, companionBundleID: "main",
            companionTeam: nil, requestID: requestID))
        XCTAssertThrowsError(try RunnerProfileMetadata.parse(valid, companionBundleID: "main",
            companionTeam: "ABCDE12345", requestID: "old-or-missing"))
    }
    func testExpiredActualDateIsPreservedForExistingRenewalGate() throws {
        var fields = valid; fields["runner_profile_expires_at"] = .string("2020-01-01T00:00:00Z")
        XCTAssertEqual(try parse(fields)["runner_profile_expires_at"], fields["runner_profile_expires_at"])
    }
    func testRPCResponseMustMatchCurrentRequestAndProtocol() {
        XCTAssertTrue(RunnerRPCResponsePolicy.matches(["jsonrpc": "2.0", "id": requestID], requestID: requestID))
        for reply: [String: Any] in [["jsonrpc": "2.0", "id": "previous-request"],
                                    ["jsonrpc": "1.0", "id": requestID],
                                    ["jsonrpc": "2.0", "id": 1], [:]] {
            XCTAssertFalse(RunnerRPCResponsePolicy.matches(reply, requestID: requestID))
        }
    }
}
