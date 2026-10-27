import XCTest
@testable import NativePolicy

final class QuietDiagnosticTests: XCTestCase {
    private let nonce = String(repeating: "a", count: 43)
    private let deadline = "2026-10-28T03:24:45Z"

    private var fields: [String: Any] {
        ["nonce": nonce, "action": "begin", "observed_focus": "iCTRL Automation", "deadline": deadline]
    }

    private func parse(_ fields: [String: Any], method: String = "POST", path: String = "/quiet-callback",
                       contentType: String? = "application/json", headers: Int = 100) throws -> QuietCallback {
        try QuietCallback.parse(method: method, path: path, contentType: contentType, headerBytes: headers,
                                body: JSONSerialization.data(withJSONObject: fields))
    }

    private func report(_ launch: QuietControl.Launch, focus: String = "iCTRL Automation") throws -> QuietCallback {
        try parse(["nonce": launch.nonce, "action": launch.action, "deadline": launch.deadline, "observed_focus": focus])
    }

    private func assertFailure(_ expected: QuietCallback.ParseFailure, _ action: () throws -> QuietCallback,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? QuietCallback.ParseFailure, expected, file: file, line: line)
        }
    }

    func testEveryParserRejectionHasOnlyAFixedReason() throws {
        assertFailure(.contract) { try parse(fields, method: "GET") }
        assertFailure(.contentType) { try parse(fields, contentType: "text/plain") }
        assertFailure(.size) { try parse(fields, headers: 4097) }
        assertFailure(.jsonShape) { try parse(["nonce": nonce]) }
        var value = fields
        value["nonce"] = "private-invalid-nonce"
        assertFailure(.nonceShape) { try parse(value) }
        value = fields; value["action"] = "private-action"
        assertFailure(.action) { try parse(value) }
        value = fields; value["observed_focus"] = "private-focus-name"
        assertFailure(.focusValue) { try parse(value) }
        value = fields; value["deadline"] = "private-invalid-date"
        assertFailure(.deadline) { try parse(value) }
        XCTAssertEqual(Set(QuietCallback.ParseFailure.allCases.map(\.rawValue)),
                       Set(["contract", "content_type", "size", "json_shape", "nonce_shape", "action", "focus_value", "deadline"]))
        for failure in QuietCallback.ParseFailure.allCases {
            XCTAssertEqual(failure.classification.rawValue, failure.rawValue + "_400")
        }
    }

    func testParserKeepsJSONStringAndContentTypeBoundaries() throws {
        for key in ["nonce", "action", "observed_focus", "deadline"] {
            var value = fields; value[key] = 123
            assertFailure(.jsonShape) { try parse(value) }
        }
        for type in [nil, "application/json;", "application/json; charset=latin1", "application/json; charset=utf-8; extra=x"] {
            assertFailure(.contentType) { try parse(fields, contentType: type) }
        }
        _ = try parse(fields, contentType: "Application/JSON; charset=\"UTF-8\"", headers: 4096)
        assertFailure(.contract) { try parse(fields, path: "/quiet-callback?private=secret") }
        assertFailure(.size) { try parse(fields, headers: -1) }
        assertFailure(.size) {
            try QuietCallback.parse(method: "POST", path: "/quiet-callback", contentType: "application/json",
                                    headerBytes: 100, body: Data(repeating: 32, count: 1025))
        }
        assertFailure(.jsonShape) {
            try QuietCallback.parse(method: "POST", path: "/quiet-callback", contentType: "application/json",
                                    headerBytes: 100, body: Data([0xff, 0, 0xfe]))
        }
    }

    func testAllPreviouslyAllowedFocusReportsAndActionsStillParse() throws {
        let expected: [(String, QuietDiagnostics.FocusResult)] = [
            ("iCTRL Automation", .dedicated), ("previous_focus_active", .previous),
            ("unavailable", .unavailable), ("off", .off), ("preserved_user_focus", .preserved),
        ]
        for action in ["begin", "end", "inspect"] {
            for (focus, classification) in expected {
                var value = fields; value["action"] = action; value["observed_focus"] = focus
                let callback = try parse(value)
                XCTAssertEqual(QuietDiagnostics.FocusResult(callback.observed_focus), classification)
            }
        }
    }

    func testDiagnosticFormattingCannotEchoUntrustedStrings() {
        let privateValue = "private-body-URL-nonce-key-focus\nhttps://private.invalid/"
        let message = QuietDiagnostics.message(.restoreFinished, action: .init(privateValue),
            classification: .focusValue, focus: QuietDiagnostics.FocusResult(privateValue), state: .failed,
            reason: QuietDiagnostics.Reason(context: privateValue))
        XCTAssertEqual(message, "Quiet event=restore_finished action=unknown classification=focus_value_400 focus_result=other_allowed state=failed reason=foreground_restore_unconfirmed")
        XCTAssertFalse(message.contains(privateValue))
        XCTAssertEqual(NativeClipboardDiagnostics.message(method: .init(privateValue), stage: .permissionPending, reason: .timeout),
                       "NativeClipboard method=unknown stage=permission_pending reason=timeout")
        for reason in QuietDiagnostics.CallbackClassification.allCases {
            XCTAssertNotNil(reason.rawValue.range(of: "^[a-z0-9_]+$", options: .regularExpression))
        }
    }

    func testFramingRecognitionIsOnlyForTheCallbackRequestLine() {
        XCTAssertTrue(QuietDiagnostics.isCallbackRequestLine("POST /quiet-callback HTTP/1.1\r\nSecret: private"))
        XCTAssertTrue(QuietDiagnostics.isCallbackRequestLine("POST /quiet-callback?private=secret HTTP/1.1\r\n"))
        XCTAssertFalse(QuietDiagnostics.isCallbackRequestLine("GET /quiet-callback HTTP/1.1\r\n"))
        XCTAssertFalse(QuietDiagnostics.isCallbackRequestLine("POST /quiet-callback-other HTTP/1.1\r\n"))
        XCTAssertFalse(QuietDiagnostics.isCallbackRequestLine("POST /other HTTP/1.1\r\nSecret: POST /quiet-callback HTTP/1.1"))
    }

    func testLeaseClassificationDoesNotConsumeOrChangeTheOriginalStateMachine() throws {
        var lease = try QuietLease(ownerTokId: "owner", id: "lease", ttl: 120, now: 100)
        try lease.prepareCallback(nonce: nonce, action: "begin", expectedDeadline: deadline, now: 100)
        XCTAssertEqual(lease.callbackClassification(nonce: "wrong", action: "begin", reportedDeadline: deadline, now: 101), .nonceMismatch)
        XCTAssertEqual(lease.callbackClassification(nonce: nonce, action: "end", reportedDeadline: deadline, now: 101), .actionMismatch)
        XCTAssertEqual(lease.callbackClassification(nonce: nonce, action: "begin", reportedDeadline: "other", now: 101), .deadlineMismatch)
        XCTAssertEqual(lease.callbackClassification(nonce: nonce, action: "begin", reportedDeadline: deadline, now: .nan), .invalidClock)
        XCTAssertEqual(lease.callbackClassification(nonce: nonce, action: "begin", reportedDeadline: deadline, now: 130), .callbackWindowElapsed)
        XCTAssertEqual(lease.callbackClassification(nonce: nonce, action: "begin", reportedDeadline: deadline, now: 101), .accepted)
        XCTAssertEqual(lease.state, .preparing)
        XCTAssertTrue(lease.hasPendingCallback)
        XCTAssertTrue(lease.callback(nonce: nonce, action: "begin", observed: "iCTRL Automation", reportedDeadline: deadline, now: 101))
        XCTAssertEqual(lease.state, .restoring)
        XCTAssertEqual(lease.callbackClassification(nonce: nonce, action: "begin", reportedDeadline: deadline, now: 102), .noPending)
        XCTAssertFalse(lease.callback(nonce: nonce, action: "begin", observed: "iCTRL Automation", reportedDeadline: deadline, now: 102))
    }

    func testLeaseClassificationPreservesAbsoluteTTLBoundary() throws {
        var lease = try QuietLease(ownerTokId: "owner", id: "lease", ttl: 10, now: 100)
        try lease.prepareCallback(nonce: nonce, action: "begin", expectedDeadline: deadline, now: 100)
        XCTAssertEqual(lease.callbackClassification(nonce: nonce, action: "begin", reportedDeadline: deadline, now: 110), .leaseExpired)
        XCTAssertFalse(lease.callback(nonce: nonce, action: "begin", observed: "iCTRL Automation", reportedDeadline: deadline, now: 110))
        XCTAssertEqual(lease.gate(tokId: "owner", session: "lease", now: 110), .denied("expired"))
    }

    func testBeginTimeoutSurvivesEndAndRemainsOwnerOnly() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        try control.register(owner: "manual", mode: "manual", now: 100)
        let begin = try control.begin(owner: "agent", ttl: 120, now: 100, date: Date())
        XCTAssertEqual(control.status(owner: "agent", requestedID: begin.leaseID, now: 130)["begin_diagnostic"], "callback_window_elapsed")
        let end = try XCTUnwrap(control.end(owner: "agent", id: begin.leaseID, now: 131))
        let callback = try report(end, focus: "off")
        XCTAssertEqual(control.classifiedCallback(callback, now: 132), .accepted)
        let restore = try XCTUnwrap(control.restorationForAcceptedCallback(callback, now: 132))
        XCTAssertTrue(control.finishRestoration(restore, succeeded: true, diagnostic: nil, now: 133))
        let own = control.status(owner: "agent", requestedID: begin.leaseID, now: 133)
        XCTAssertEqual(own["state"], "restoration_pending")
        XCTAssertEqual(own["begin_diagnostic"], "callback_window_elapsed")
        XCTAssertNil(own["context_diagnostic"])
        XCTAssertEqual(own["last_callback_action"], "end")
        XCTAssertEqual(own["last_callback_classification"], "accepted_204")
        let other = control.status(owner: "manual", requestedID: nil, now: 133)
        for key in ["begin_diagnostic", "begin_callback_classification", "begin_focus_result", "begin_context_diagnostic", "last_callback_action", "last_callback_classification"] {
            XCTAssertNil(other[key])
        }
        XCTAssertNotNil(control.gate(owner: "manual", method: "tap", session: nil, now: 133))
    }

    func testUnmatchedNonceCannotPopulateOwnerCallbackDiagnostics() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        let begin = try control.begin(owner: "agent", ttl: 120, now: 100, date: Date())
        let differentNonce = (begin.nonce.first == "a" ? "b" : "a") + String(begin.nonce.dropFirst())
        let unrelated = try parse(["nonce": differentNonce, "action": "begin", "deadline": begin.deadline, "observed_focus": "off"])
        XCTAssertEqual(control.classifiedCallback(unrelated, now: 101), .nonceMismatch)
        let status = control.status(owner: "agent", requestedID: begin.leaseID, now: 101)
        XCTAssertEqual(status["begin_diagnostic"], "awaiting_callback")
        XCTAssertNil(status["begin_callback_classification"])
        XCTAssertNil(status["last_callback_classification"])
        XCTAssertEqual(status["state"], "preparing")
    }

    func testMatchedRejectionIsClassifiedWithoutConsumingTheCallback() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        let begin = try control.begin(owner: "agent", ttl: 120, now: 100, date: Date())
        let mismatched = try parse(["nonce": begin.nonce, "action": "begin", "deadline": "2020-01-01T00:00:00Z", "observed_focus": "iCTRL Automation"])
        XCTAssertEqual(control.classifiedCallback(mismatched, now: 101), .deadlineMismatch)
        let rejected = control.status(owner: "agent", requestedID: begin.leaseID, now: 101)
        XCTAssertEqual(rejected["begin_callback_classification"], "deadline_mismatch_409")
        XCTAssertEqual(rejected["begin_diagnostic"], "callback_rejected")
        XCTAssertEqual(rejected["state"], "preparing")
        XCTAssertTrue(control.callback(try report(begin), now: 102))
        XCTAssertEqual(control.status(owner: "agent", requestedID: begin.leaseID, now: 102)["state"], "restoring")
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: begin.leaseID, now: 102))
    }

    func testNegativeFocusAndNewBeginKeepTheirOriginalGates() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        let begin = try control.begin(owner: "agent", ttl: 120, now: 100, date: Date())
        let callback = try report(begin, focus: "unavailable")
        XCTAssertTrue(control.callback(callback, now: 101))
        let restore = try XCTUnwrap(control.restorationForAcceptedCallback(callback, now: 101))
        XCTAssertTrue(control.finishRestoration(restore, succeeded: true, diagnostic: nil, now: 102))
        let failed = control.status(owner: "agent", requestedID: begin.leaseID, now: 102)
        XCTAssertEqual(failed["state"], "failed")
        XCTAssertEqual(failed["begin_diagnostic"], "focus_not_dedicated")
        XCTAssertEqual(failed["begin_focus_result"], "unavailable")
        XCTAssertNotNil(control.gate(owner: "agent", method: "tap", session: begin.leaseID, now: 102))
        let end = try XCTUnwrap(control.end(owner: "agent", id: begin.leaseID, now: 103))
        let ended = try report(end, focus: "off")
        XCTAssertTrue(control.callback(ended, now: 104))
        let endRestore = try XCTUnwrap(control.restorationForAcceptedCallback(ended, now: 104))
        XCTAssertTrue(control.finishRestoration(endRestore, succeeded: true, diagnostic: nil, now: 105))
        XCTAssertEqual(control.status(owner: "agent", requestedID: begin.leaseID, now: 105)["begin_diagnostic"], "focus_not_dedicated")
        _ = try control.begin(owner: "agent", ttl: 120, now: 106, date: Date())
        let next = control.status(owner: "agent", requestedID: nil, now: 106)
        XCTAssertEqual(next["begin_diagnostic"], "awaiting_callback")
        XCTAssertNil(next["begin_focus_result"])
        XCTAssertNil(next["last_callback_classification"])
    }

    func testRestoreTimeoutSurvivesCleanupAndSnapshotDoesNotExpire() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        let begin = try control.begin(owner: "agent", ttl: 120, now: 100, date: Date())
        let callback = try report(begin)
        XCTAssertTrue(control.callback(callback, now: 101))
        XCTAssertEqual(control.diagnosticState(leaseID: begin.leaseID), .restoring)
        XCTAssertNil(control.diagnosticState(leaseID: "other"))
        XCTAssertEqual(control.status(owner: "agent", requestedID: begin.leaseID, now: 109)["begin_diagnostic"], "foreground_restore_timeout")
        _ = try control.end(owner: "agent", id: begin.leaseID, now: 110)
        let status = control.status(owner: "agent", requestedID: begin.leaseID, now: 110)
        XCTAssertEqual(status["begin_diagnostic"], "foreground_restore_timeout")
        XCTAssertEqual(status["begin_context_diagnostic"], "foreground_restore_timeout")
        XCTAssertEqual(status["state"], "ending")
        XCTAssertNil(status["context_diagnostic"])
    }

    func testBeginRestoreReasonSurvivesEndWithoutAcceptingArbitraryContext() throws {
        let control = QuietControl(enabled: true, port: 8200)
        try control.register(owner: "agent", mode: "automation", now: 100)
        let begin = try control.begin(owner: "agent", ttl: 120, now: 100, date: Date())
        let callback = try report(begin)
        XCTAssertTrue(control.callback(callback, now: 101))
        let restore = try XCTUnwrap(control.restorationForAcceptedCallback(callback, now: 101))
        XCTAssertTrue(control.finishRestoration(restore, succeeded: false, diagnostic: "foreground_pid_unconfirmed", now: 102))
        _ = try control.end(owner: "agent", id: begin.leaseID, now: 103)
        let status = control.status(owner: "agent", requestedID: begin.leaseID, now: 103)
        XCTAssertEqual(status["begin_context_diagnostic"], "foreground_pid_unconfirmed")
        XCTAssertNil(status["context_diagnostic"])
        XCTAssertEqual(QuietDiagnostics.Reason(context: "private-context-string"), .foregroundRestoreUnconfirmed)
    }
}
