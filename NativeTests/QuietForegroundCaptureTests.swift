import XCTest
@testable import NativePolicy

final class QuietForegroundCaptureTests: XCTestCase {
    private func sample(_ bundle: String = "test.actual", pid: Int32 = 42) -> QuietForegroundCapture.Sample {
        .init(bundleID: bundle, targetPID: pid, frontmostBefore: pid, frontmostAfter: pid)
    }

    func testStaleCandidateIsSkippedAndCandidatesAreDeduplicated() {
        var queried: [String] = []
        let result = QuietForegroundCapture.readSample(candidates: ["", "test.stale", "test.stale", "test.actual"],
            frontmostBefore: 42, namedPID: { bundle in
                queried.append(bundle)
                return bundle == "test.actual" ? 42 : 7
            }, frontmostPID: { 42 }, mayRead: { true })
        XCTAssertEqual(queried, ["test.stale", "test.actual"])
        XCTAssertEqual(result, sample())
    }

    func testUnmappedOrUnavailablePIDCannotBecomeAName() {
        for named: Int32 in [0, -1, 7] {
            XCTAssertNil(QuietForegroundCapture.readSample(candidates: ["test.actual"], frontmostBefore: 42,
                namedPID: { _ in named }, frontmostPID: { 42 }, mayRead: { true }))
        }
        var reads = 0
        XCTAssertNil(QuietForegroundCapture.readSample(candidates: ["test.actual"], frontmostBefore: 0,
            namedPID: { _ in reads += 1; return 42 }, frontmostPID: { 42 }, mayRead: { true }))
        XCTAssertEqual(reads, 0)
    }

    func testForegroundChangeRejectsWholeSampleWithoutTryingAnotherName() {
        var queried: [String] = []
        XCTAssertNil(QuietForegroundCapture.readSample(candidates: ["test.actual", "test.other"], frontmostBefore: 42,
            namedPID: { bundle in queried.append(bundle); return 42 },
            frontmostPID: { 43 }, mayRead: { true }))
        XCTAssertEqual(queried, ["test.actual"])
    }

    func testGateIsCheckedBeforeAndAfterEachFreshRead() {
        // A read already in progress cannot be cancelled. Losing the gate
        // during it forbids the next read and cannot produce a proven sample.
        for revokeDuringPIDRead in [false, true] {
            var allowed = true
            var namedReads = 0
            var frontReads = 0
            let result = QuietForegroundCapture.readSample(candidates: ["test.actual", "test.other"],
                frontmostBefore: 42, namedPID: { _ in
                    namedReads += 1
                    if revokeDuringPIDRead { allowed = false }
                    return 42
                }, frontmostPID: {
                    frontReads += 1
                    allowed = false
                    return 42
                }, mayRead: { allowed })
            XCTAssertNil(result)
            XCTAssertEqual(namedReads, 1)
            XCTAssertEqual(frontReads, revokeDuringPIDRead ? 0 : 1)
        }
        var reads = 0
        XCTAssertNil(QuietForegroundCapture.readSample(candidates: ["test.actual"], frontmostBefore: 42,
            namedPID: { _ in reads += 1; return 42 }, frontmostPID: { 42 }, mayRead: { false }))
        XCTAssertEqual(reads, 0)
    }

    func testNilTransientNeedsTwoNewSeparatedStableSamples() {
        var proof = QuietForegroundCapture(startedAt: 0, budget: 2)
        XCTAssertEqual(proof.observe(sample(), now: 0), .waiting)
        XCTAssertEqual(proof.observe(nil, now: 0.2), .waiting)
        XCTAssertEqual(proof.observe(sample(), now: 0.4), .waiting)
        XCTAssertEqual(proof.observe(sample(), now: 0.51), .confirmed(sample()))
    }

    func testPIDOrBundleChangeResetsStabilityAndFastSamplesDoNotConfirm() {
        var proof = QuietForegroundCapture(startedAt: 0, budget: 2)
        XCTAssertEqual(proof.observe(sample(), now: 0), .waiting)
        XCTAssertEqual(proof.observe(sample(), now: 0.05), .waiting)
        XCTAssertEqual(proof.observe(sample("test.other"), now: 0.2), .waiting)
        XCTAssertEqual(proof.observe(sample("test.other", pid: 43), now: 0.4), .waiting)
        XCTAssertEqual(proof.observe(sample("test.other", pid: 43), now: 0.51), .confirmed(sample("test.other", pid: 43)))
    }

    func testInvalidSampleResetsAndDeadlineOrInvalidClockCannotConfirm() {
        var proof = QuietForegroundCapture(startedAt: 0, budget: 2)
        XCTAssertEqual(proof.observe(sample(), now: 0), .waiting)
        let mismatched = QuietForegroundCapture.Sample(bundleID: "test.actual", targetPID: 42,
                                                       frontmostBefore: 42, frontmostAfter: 43)
        XCTAssertEqual(proof.observe(mismatched, now: 0.2), .waiting)
        XCTAssertEqual(proof.observe(sample(), now: 1.9), .waiting)
        XCTAssertEqual(proof.observe(sample(), now: 2), .expired)
        XCTAssertEqual(proof.observe(sample(), now: .nan), .expired)
        XCTAssertFalse(proof.permitsRead(now: -1))
        for budget in [0, -1, .nan, .infinity] as [TimeInterval] {
            XCTAssertFalse(QuietForegroundCapture(startedAt: 0, budget: budget).permitsRead(now: 0))
        }
        var backwards = QuietForegroundCapture(startedAt: 0, budget: 2)
        XCTAssertEqual(backwards.observe(sample(), now: 0.5), .waiting)
        XCTAssertEqual(backwards.observe(sample(), now: 0.4), .expired)
    }

    func testStableCaptureCannotReviveSupersededBeginAndMarkedFailureStaysBlocked() throws {
        let control = QuietControl(enabled: true, port: 8200)
        _ = try control.register(owner: "test.owner", mode: "automation", now: 100)
        let begin = try control.begin(owner: "test.owner", ttl: 240, now: 100, date: Date(timeIntervalSince1970: 100))
        var proof = QuietForegroundCapture(startedAt: 100, budget: 2)
        XCTAssertEqual(proof.observe(sample(), now: 100), .waiting)
        XCTAssertEqual(proof.observe(sample(), now: 100.11), .confirmed(sample()))
        XCTAssertNotNil(try control.end(owner: "test.owner", id: begin.leaseID, now: 100.12))
        XCTAssertFalse(control.mayLaunch(begin, now: 100.13))
        XCTAssertFalse(control.markLaunchAttempted(begin, now: 100.13))

        let other = QuietControl(enabled: true, port: 8200)
        _ = try other.register(owner: "test.owner", mode: "automation", now: 100)
        let attempted = try other.begin(owner: "test.owner", ttl: 240, now: 100, date: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(other.markLaunchAttempted(attempted, now: 101))
        other.failLaunch(attempted, diagnostic: "helper_not_launched_before_deadline", now: 101.1)
        XCTAssertFalse(other.abortBeforeLaunch(attempted, diagnostic: "helper_not_launched_before_deadline", now: 101.2))
        XCTAssertEqual(other.status(owner: "test.owner", requestedID: attempted.leaseID, now: 101.2)["state"], "restoration_pending")
        XCTAssertNotNil(other.gate(owner: "test.manual", method: "tap", session: nil, now: 101.2))
    }
}
