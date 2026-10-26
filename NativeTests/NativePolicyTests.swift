import XCTest
@testable import NativePolicy

final class NativePolicyTests: XCTestCase {
    func testUnicodeAndMultilineRoundTrip() throws {
        let text = "中文😀\n第二行\tend"
        let request = try NativeClipboardRequest(method: "clipboard_set", params: ["text": .string(text)])
        XCTAssertEqual(request.text, text)
        XCTAssertTrue(request.foreground)
        XCTAssertTrue(request.restoreApp)
        let encoded = try JSONEncoder().encode(["text": JSONValue.string(text)])
        XCTAssertEqual(try JSONDecoder().decode([String: JSONValue].self, from: encoded)["text"], .string(text))
    }

    func testUTF8LimitIsBytesNotCharacters() throws {
        try ClipboardTextPolicy.validate(String(repeating: "中", count: 21_845) + "x")
        XCTAssertThrowsError(try ClipboardTextPolicy.validate(String(repeating: "中", count: 21_846)))
        try ClipboardTextPolicy.validate(String(repeating: "a", count: 65_536))
        XCTAssertThrowsError(try ClipboardTextPolicy.validate(String(repeating: "a", count: 65_537)))
        XCTAssertThrowsError(try ClipboardTextPolicy.validate("a\0b"))
    }

    func testClipboardRejectsWrongTypeUnknownKeysAndMissingText() {
        for params: [String: JSONValue] in [["foreground": .int(1)], ["restore_app": .string("true")], ["typo": .bool(true)]] {
            XCTAssertThrowsError(try NativeClipboardRequest(method: "clipboard_get", params: params))
        }
        XCTAssertThrowsError(try NativeClipboardRequest(method: "clipboard_set", params: [:]))
        XCTAssertThrowsError(try NativeClipboardRequest(method: "clipboard_clear", params: ["text": .string("x")]))
        XCTAssertThrowsError(try NativeClipboardRequest(method: "other", params: [:]))
        XCTAssertFalse(try! NativeClipboardRequest(method: "clipboard_get", params: ["foreground": .bool(false)]).foreground)
    }

    func testProfileExportsOnlyValidExpiryAndTeam() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let xml = try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": expiry, "TeamIdentifier": ["ABCDE12345"], "ProvisionedDevices": ["must-not-export"]], format: .xml, options: 0)
        let cms = Data([0, 255, 1]) + xml + Data([255, 0])
        XCTAssertEqual(ProvisioningExpiry.date(in: cms), expiry)
        XCTAssertEqual(ProvisioningExpiry.teamIdentifier(in: cms), "ABCDE12345")
        XCTAssertNil(ProvisioningExpiry.date(in: Data("<plist>bad</plist>".utf8)))
        XCTAssertNil(ProvisioningExpiry.date(in: Data(repeating: 0, count: ProvisioningExpiry.maximumProfileBytes + 1)))
        let bad = try PropertyListSerialization.data(fromPropertyList: ["TeamIdentifier": ["wrong"]], format: .xml, options: 0)
        XCTAssertNil(ProvisioningExpiry.teamIdentifier(in: bad))
    }

    func testStartupRejectsUnsafeCallbacksAndAmbiguousParameters() throws {
        let valid = try StartupURLRequest(url: URL(string: "ictrl-app://prepare?mount_if_needed=0&keep_awake=1&callback=shortcuts%3A%2F%2F")!)
        XCTAssertEqual(valid.operation, .prepare)
        XCTAssertFalse(valid.mountIfNeeded)
        XCTAssertTrue(valid.keepAwake)
        for raw in ["ictrl-app://prepare?callback=https%3A%2F%2Fexample.com", "ictrl-app://prepare?keep_awake=1&keep_awake=0", "ictrl-app://prepare?keep_awake=yes", "ictrl-app://prepare?unknown=1", "https://prepare"] {
            XCTAssertThrowsError(try StartupURLRequest(url: URL(string: raw)!))
        }
    }

    func testReceiptIsProgressOnlyAndRequiresUUID() throws {
        let name = "native-policy-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(RenewalReceiptStore.currentJSON(defaults: defaults), .null)
        XCTAssertNil(RenewalReceiptStore.record(attemptID: "not-a-UUID", defaults: defaults))
        let id = UUID().uuidString
        let receipt = RenewalReceiptStore.record(attemptID: id, now: Date(timeIntervalSince1970: 1_800_000_000), defaults: defaults)
        XCTAssertEqual(receipt?["attempt_id"], .string(id))
        XCTAssertEqual(RenewalReceiptStore.currentJSON(defaults: defaults), JSONValue.object(receipt!))
    }

    func testCompanionReportIsBoundedNonceMatchedAndUnverified() throws {
        let nonce = UUID().uuidString
        var callback = URLComponents(string: "ictrl-app://started")!
        callback.queryItems = [URLQueryItem(name: "request_id", value: nonce)]
        let fields: [String: JSONValue] = ["companion_profile_expires_at": .string("2027-01-15T08:00:00Z"), "companion_bundle_id": .string("com.openminis.ictrl")]
        var url = URLComponents(string: "ictrl://start")!
        url.queryItems = [URLQueryItem(name: "request_id", value: nonce), URLQueryItem(name: "callback", value: callback.url!.absoluteString), URLQueryItem(name: "companion_metadata", value: String(decoding: try JSONEncoder().encode(fields), as: UTF8.self))]
        let report = CompanionRuntimeMetadata.parse(startURL: url.url!)
        XCTAssertEqual(report?["companion_profile_expires_at"], fields["companion_profile_expires_at"])
        XCTAssertEqual(report?["companion_metadata_verified"], .bool(false))
        XCTAssertEqual(report?["companion_report_request_id"], .string(nonce))
        url.queryItems?.append(URLQueryItem(name: "request_id", value: nonce))
        XCTAssertNil(CompanionRuntimeMetadata.parse(startURL: url.url!))
        url.queryItems = [URLQueryItem(name: "request_id", value: nonce), URLQueryItem(name: "callback", value: "ictrl-app://started?request_id=wrong"), URLQueryItem(name: "companion_metadata", value: "{}")]
        XCTAssertNil(CompanionRuntimeMetadata.parse(startURL: url.url!))
    }

    func testCapabilitiesAndSchemaStayInSync() {
        for cap in ["native_clipboard_v1", "runtime_status_v1", "foreground_keep_awake_v1"] { XCTAssertTrue(RPCMethodRegistry.capabilityTags.contains(cap)) }
        let names = RPCMethodRegistry.methods.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        for method in ["clipboard_get", "clipboard_set", "clipboard_clear", "runtime_status"] { XCTAssertTrue(names.contains(method)) }
        let set = RPCMethodRegistry.methods.first { $0.name == "clipboard_set" }!
        XCTAssertEqual(set.params.filter(\.required).map(\.name), ["text"])
        XCTAssertEqual(RPCMethodRegistry.protocolVersion, 1)
    }
}
