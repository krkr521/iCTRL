import XCTest
@testable import NativePolicy

final class ServiceKeepAwakeTests: XCTestCase {
    typealias Source = ServiceKeepAwakePolicy.Source
    private func healthy(_ generation: UInt64 = 0) -> NativeDeviceReadiness {
        .init(interruptionGuardAvailable: true, f13Available: true, monitorRegistered: true,
              stateKnown: true, locked: false, lockGeneration: generation)
    }
    func testNoPulseBeforeReadyAndWaitingWithoutClientsRemainsAuthorized() throws {
        let service = ServiceKeepAwakeAuthorization()
        let ticket = try XCTUnwrap(service.prepareStart())
        XCTAssertNil(service.source(lockGeneration: 0))
        XCTAssertEqual(service.state(readiness: healthy()), "starting")
        XCTAssertTrue(service.ready(ticket: ticket))
        var policy = ServiceKeepAwakePolicy()
        XCTAssertTrue(policy.admit(service.source(lockGeneration: 0), now: 0))
        XCTAssertFalse(policy.admit(service.source(lockGeneration: 0), now: 9.99))
        XCTAssertTrue(policy.admit(service.source(lockGeneration: 0), now: 10))
        // No owner registration, client connection or heartbeat exists in this test.
        XCTAssertTrue(policy.admit(service.source(lockGeneration: 0), now: 1000))
        XCTAssertFalse(policy.admit(service.source(lockGeneration: 0), now: 1000))
    }
    func testTaskEndAndHeartbeatExpiryRevokeUIButServiceStillPulses() throws {
        for endExplicitly in [true, false] {
            let service = ServiceKeepAwakeAuthorization()
            XCTAssertTrue(service.ready(ticket: try XCTUnwrap(service.prepareStart())))
            let session = NativeAutomationSession()
            _ = try session.begin(owner: "owner", id: "task", ttl: 120, now: 0, date: Date())
            if endExplicitly { _ = try session.end(owner: "owner", id: "task", now: 1) }
            XCTAssertFalse(session.gate(owner: "owner", id: "task", now: 16))
            XCTAssertThrowsError(try session.heartbeat(owner: "owner", id: "task", now: 16))
            var policy = ServiceKeepAwakePolicy()
            XCTAssertTrue(policy.admit(service.source(lockGeneration: 0), now: 16))
            XCTAssertTrue(policy.admit(service.source(lockGeneration: 0), now: 26))
        }
    }
    func testManualLockPausesThenNewUnlockedHealthSourceResumesWithoutUIRevival() throws {
        let service = ServiceKeepAwakeAuthorization()
        XCTAssertTrue(service.ready(ticket: try XCTUnwrap(service.prepareStart())))
        let sessions = NativeAutomationSession()
        _ = try sessions.begin(owner: "o", id: "old", ttl: 120, now: 0, date: Date(), lockGeneration: 0)
        var policy = ServiceKeepAwakePolicy()
        let old = try XCTUnwrap(service.source(lockGeneration: 0))
        XCTAssertTrue(policy.admit(old, now: 0))
        XCTAssertFalse(policy.admit(nil, now: 5)) // actual locked/unknown readiness denies source
        sessions.revoke(beforeLockGeneration: 1)
        let recovered = try XCTUnwrap(service.source(lockGeneration: 1))
        XCTAssertFalse(policy.admit(recovered, now: 6)) // no extra pulse inside ten seconds
        XCTAssertTrue(policy.admit(recovered, now: 10))
        XCTAssertFalse(policy.admit(old, now: 20)) // stale queued source
        XCTAssertFalse(sessions.gate(owner: "o", id: "old", now: 20))
        XCTAssertThrowsError(try sessions.heartbeat(owner: "o", id: "old", now: 20))
    }
    func testStopInvalidatesQueuedSourceAndLateListenerReadyCannotRestartIt() throws {
        let service = ServiceKeepAwakeAuthorization()
        let oldTicket = try XCTUnwrap(service.prepareStart())
        XCTAssertTrue(service.ready(ticket: oldTicket))
        let queued = try XCTUnwrap(service.source(lockGeneration: 0))
        XCTAssertTrue(service.stop())
        XCTAssertNil(service.source(lockGeneration: 0))
        XCTAssertFalse(service.ready(ticket: oldTicket))
        XCTAssertEqual(service.state(readiness: healthy()), "stopped")
        let newTicket = try XCTUnwrap(service.prepareStart())
        XCTAssertTrue(service.ready(ticket: newTicket))
        XCTAssertNotEqual(service.source(lockGeneration: 0), queued)
        XCTAssertFalse(service.stop(ticket: oldTicket)) // stale cancelled/failed listener callback
        XCTAssertNotNil(service.source(lockGeneration: 0))
    }
    func testFailureLatchesOnlyItsSourceAndRecoveryRequiresNewSource() throws {
        let service = ServiceKeepAwakeAuthorization()
        XCTAssertTrue(service.ready(ticket: try XCTUnwrap(service.prepareStart())))
        let source = try XCTUnwrap(service.source(lockGeneration: 0))
        service.failed(source)
        XCTAssertNil(service.source(lockGeneration: 0))
        XCTAssertEqual(service.state(readiness: healthy()), "event_failed")
        let newer = try XCTUnwrap(service.source(lockGeneration: 1))
        XCTAssertEqual(service.state(readiness: healthy(1)), "ready")
        service.failed(newer)
        service.failed(source) // late failure from an older health source must not clear newer latch
        XCTAssertNil(service.source(lockGeneration: 1))
        XCTAssertNotNil(service.source(lockGeneration: 2))
        var policy = ServiceKeepAwakePolicy()
        XCTAssertTrue(policy.admit(source, now: 0))
        policy.fail()
        XCTAssertFalse(policy.admit(source, now: 10))
        XCTAssertTrue(policy.admit(service.source(lockGeneration: 2), now: 10))
    }
    func testUnknownStateAndLockedReasonsRemainDistinctFromServiceStop() throws {
        let service = ServiceKeepAwakeAuthorization()
        XCTAssertTrue(service.ready(ticket: try XCTUnwrap(service.prepareStart())))
        let unknown = NativeDeviceReadiness(interruptionGuardAvailable: true, f13Available: true,
            monitorRegistered: true, stateKnown: false, locked: true, lockGeneration: 1)
        XCTAssertEqual(service.state(readiness: unknown), "paused_native_lock_state_unknown")
        let locked = NativeDeviceReadiness(interruptionGuardAvailable: true, f13Available: true,
            monitorRegistered: true, stateKnown: true, locked: true, lockGeneration: 2)
        XCTAssertEqual(service.state(readiness: locked), "paused_native_device_locked")
        XCTAssertTrue(service.isRunning)
    }
    func testInvalidClockFailsClosedWithoutCatchUpBursts() {
        var policy = ServiceKeepAwakePolicy()
        let source = Source(serviceEpoch: 1, lockGeneration: 0)
        XCTAssertTrue(policy.admit(source, now: 10))
        XCTAssertFalse(policy.admit(source, now: 9))
        XCTAssertFalse(policy.admit(source, now: 20))
        XCTAssertFalse(policy.admit(nil, now: .nan))
        XCTAssertTrue(policy.admit(Source(serviceEpoch: 2, lockGeneration: 0), now: 30))
        XCTAssertTrue(policy.admit(Source(serviceEpoch: 2, lockGeneration: 0), now: 100))
        XCTAssertFalse(policy.admit(Source(serviceEpoch: 2, lockGeneration: 0), now: 100))
    }
}
