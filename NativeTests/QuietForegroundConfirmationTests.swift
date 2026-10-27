import XCTest
@testable import NativePolicy

final class QuietForegroundConfirmationTests: XCTestCase {
    func testDelayedTargetPIDRequiresTwoConsecutiveMatches() {
        var proof = QuietForegroundConfirmation(startedAt: 10, budget: 2)
        XCTAssertEqual(proof.observe(targetPID: 0, frontmostPID: 42, now: 10.1), .waiting)
        XCTAssertEqual(proof.observe(targetPID: 42, frontmostPID: 42, now: 10.2), .waiting)
        XCTAssertEqual(proof.observe(targetPID: 42, frontmostPID: 42, now: 10.3), .confirmed)
    }

    func testAnyPIDChangeResetsConsecutiveMatches() {
        var proof = QuietForegroundConfirmation(startedAt: 10, budget: 2)
        XCTAssertEqual(proof.observe(targetPID: 42, frontmostPID: 42, now: 10.1), .waiting)
        XCTAssertEqual(proof.observe(targetPID: 43, frontmostPID: 43, now: 10.2), .waiting)
        XCTAssertEqual(proof.observe(targetPID: 43, frontmostPID: 7, now: 10.3), .waiting)
        XCTAssertEqual(proof.observe(targetPID: 43, frontmostPID: 43, now: 10.4), .waiting)
        XCTAssertEqual(proof.observe(targetPID: 43, frontmostPID: 43, now: 10.5), .confirmed)
    }

    func testQueuedActionAndLateMatchExpireAtDeadline() {
        var proof = QuietForegroundConfirmation(startedAt: 10, budget: 2)
        XCTAssertTrue(proof.permitsAction(now: 11.99))
        XCTAssertFalse(proof.permitsAction(now: 12))
        XCTAssertEqual(proof.observe(targetPID: 42, frontmostPID: 42, now: 11.95), .waiting)
        XCTAssertEqual(proof.observe(targetPID: 42, frontmostPID: 42, now: 12), .expired)
    }

    func testInvalidBudgetAndClockFailClosed() {
        let invalid = QuietForegroundConfirmation(startedAt: 10, budget: .nan)
        XCTAssertFalse(invalid.permitsAction(now: 10.1))
        let zero = QuietForegroundConfirmation(startedAt: 10, budget: 0)
        XCTAssertFalse(zero.permitsAction(now: 10))
        var proof = QuietForegroundConfirmation(startedAt: 10, budget: 2)
        XCTAssertEqual(proof.observe(targetPID: 42, frontmostPID: 42, now: .nan), .expired)
        XCTAssertFalse(proof.permitsAction(now: 9))
    }
}
