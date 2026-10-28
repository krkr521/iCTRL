import XCTest
import NativeLockHealth
@testable import NativePolicy

final class NativeLockHealthTests: XCTestCase {
    func testTransientReadFailureRecoversOnlyOnExistingValidRegistration() {
        var health = ICLockHealthMake(true)
        ICLockHealthObserve(&health, true, true, false)
        XCTAssertTrue(ICLockHealthReady(health))
        let old = health.generation
        ICLockHealthObserve(&health, true, false, false)
        XCTAssertTrue(health.registered)
        XCTAssertFalse(health.stateKnown)
        XCTAssertTrue(health.locked)
        XCTAssertGreaterThan(health.generation, old)
        ICLockHealthObserve(&health, true, true, false)
        XCTAssertTrue(ICLockHealthReady(health))
        XCTAssertNotEqual(health.generation, old)
    }
    func testInvalidTokenAndFailedRegistrationCannotRecoverByReading() {
        for initiallyRegistered in [false, true] {
            var health = ICLockHealthMake(initiallyRegistered)
            ICLockHealthObserve(&health, false, false, false)
            ICLockHealthObserve(&health, true, true, false)
            XCTAssertFalse(health.registered)
            XCTAssertFalse(ICLockHealthReady(health))
        }
    }
    func testLockedStateAlwaysDeniesAndHealthyReadsDoNotAdvanceEpoch() {
        var health = ICLockHealthMake(true)
        ICLockHealthObserve(&health, true, true, false)
        let unlocked = health.generation
        ICLockHealthObserve(&health, true, true, false)
        XCTAssertEqual(health.generation, unlocked)
        ICLockHealthObserve(&health, true, true, true)
        XCTAssertTrue(health.stateKnown)
        XCTAssertFalse(ICLockHealthReady(health))
        XCTAssertGreaterThan(health.generation, unlocked)
    }
    func testRecoveryCannotReviveLeaseAndDelayedCallbackPreservesNewBegin() throws {
        var health = ICLockHealthMake(true)
        ICLockHealthObserve(&health, true, true, false)
        let sessions = NativeAutomationSession()
        _ = try sessions.begin(owner: "owner", id: "old", ttl: 120, now: 1, date: Date(), lockGeneration: health.generation)
        let oldEpoch = health.generation
        ICLockHealthObserve(&health, true, false, false)
        let invalidation = health.generation
        sessions.revoke(beforeLockGeneration: invalidation)
        ICLockHealthObserve(&health, true, true, false)
        XCTAssertTrue(ICLockHealthReady(health))
        XCTAssertFalse(sessions.gate(owner: "owner", id: "old", now: 2))
        XCTAssertThrowsError(try sessions.heartbeat(owner: "owner", id: "old", now: 2))
        XCTAssertGreaterThan(health.generation, oldEpoch)
        _ = try sessions.begin(owner: "owner", id: "new", ttl: 120, now: 3, date: Date(), lockGeneration: health.generation)
        sessions.revoke(beforeLockGeneration: invalidation) // delayed old callback
        sessions.revoke(id: "old") // delayed old UI/pulse completion
        XCTAssertTrue(sessions.gate(owner: "owner", id: "new", now: 4))
        XCTAssertEqual(sessions.active(now: 4)?.lockGeneration, health.generation)
    }
    func testQueuedOldPulseCannotMatchRecoveredEpoch() {
        var health = ICLockHealthMake(true)
        ICLockHealthObserve(&health, true, true, false)
        let old = health.generation
        ICLockHealthObserve(&health, true, true, true)
        ICLockHealthObserve(&health, true, true, false)
        XCTAssertTrue(ICLockHealthReady(health))
        XCTAssertNotEqual(old, health.generation)
    }
    func testReadinessReasonsAndDiagnosticsReflectCurrentHealth() {
        func readiness(guardOK: Bool = true, f13: Bool = true, registered: Bool = true,
                       known: Bool = true, locked: Bool = false) -> NativeDeviceReadiness {
            .init(interruptionGuardAvailable: guardOK, f13Available: f13, monitorRegistered: registered,
                  stateKnown: known, locked: locked, lockGeneration: 3)
        }
        XCTAssertEqual(readiness(guardOK: false).reason, .interruptionGuardUnavailable)
        XCTAssertEqual(readiness(f13: false).reason, .f13Unavailable)
        XCTAssertEqual(readiness(registered: false).reason, .monitorUnregistered)
        XCTAssertEqual(readiness(known: false).reason, .stateUnknown)
        XCTAssertEqual(readiness(locked: true).reason, .deviceLocked)
        XCTAssertFalse(readiness(known: false).ready)
        XCTAssertEqual(readiness(known: false).diagnostics["admission_reason"], .string("native_lock_state_unknown"))
        XCTAssertTrue(readiness().ready)
        XCTAssertEqual(readiness().diagnostics["admission_reason"], .string("ready"))
    }
    func testManualOrWrongSessionCannotRevokeOrInspectOwnerLease() throws {
        let sessions = NativeAutomationSession()
        _ = try sessions.begin(owner: "agent", id: "lease", ttl: 120, now: 1, date: Date(), lockGeneration: 4)
        for request in [("manual", "lease"), ("agent", "wrong"), ("manual", "wrong")] {
            let error = NativeControlAdmission.error(sessions: sessions, owner: request.0, id: request.1, now: 2,
                readiness: { XCTFail("wrong requester must not trigger health refresh"); return .unavailable },
                mode: { _ in XCTFail("wrong requester must not inspect mode"); return "manual" },
                legacyReady: { XCTFail("wrong requester must not inspect legacy state"); return false },
                serviceReady: { _ in XCTFail("wrong requester must not inspect service"); return false })
            XCTAssertEqual(error, "native_session_owned_or_expired")
            XCTAssertTrue(sessions.gate(owner: "agent", id: "lease", now: 2))
        }
    }
    func testAuthorizedAdmissionChecksStoredOwnerModeAndRevokesOnlyItsOwnLease() throws {
        let sessions = NativeAutomationSession()
        _ = try sessions.begin(owner: "agent", id: "lease", ttl: 120, now: 1, date: Date(), lockGeneration: 4)
        let ready = NativeDeviceReadiness(interruptionGuardAvailable: true, f13Available: true,
            monitorRegistered: true, stateKnown: true, locked: false, lockGeneration: 4)
        XCTAssertNil(NativeControlAdmission.error(sessions: sessions, owner: "agent", id: "lease", now: 2,
            readiness: { ready }, mode: { owner in XCTAssertEqual(owner, "agent"); return "automation" },
            legacyReady: { true }, serviceReady: { $0 == 4 }))
        XCTAssertEqual(NativeControlAdmission.error(sessions: sessions, owner: "agent", id: "lease", now: 2,
            readiness: { ready }, mode: { _ in "automation" }, legacyReady: { false }, serviceReady: { _ in true }),
            "native_legacy_recovery_required")
        XCTAssertFalse(sessions.gate(owner: "agent", id: "lease", now: 2))
    }

    func testEndOrReplacementDuringReadinessCannotGrantOldRequestOrRevokeNewLease() throws {
        let sessions = NativeAutomationSession()
        _ = try sessions.begin(owner: "agent", id: "old", ttl: 120, now: 1, date: Date(), lockGeneration: 4)
        let ready = NativeDeviceReadiness(interruptionGuardAvailable: true, f13Available: true,
            monitorRegistered: true, stateKnown: true, locked: false, lockGeneration: 4)
        let error = NativeControlAdmission.error(sessions: sessions, owner: "agent", id: "old", now: 2,
            readiness: { ready }, mode: { _ in "automation" }, legacyReady: {
                sessions.revoke(id: "old")
                _ = try! sessions.begin(owner: "agent", id: "new", ttl: 120, now: 2, date: Date(), lockGeneration: 4)
                return true
            }, serviceReady: { _ in true }, recheckNow: { 2 })
        XCTAssertEqual(error, "native_session_owned_or_expired")
        XCTAssertTrue(sessions.gate(owner: "agent", id: "new", now: 2))
    }
    func testFinalAdmissionUsesFreshClockForHeartbeatExpiry() throws {
        let sessions = NativeAutomationSession()
        _ = try sessions.begin(owner: "agent", id: "old", ttl: 120, now: 1, date: Date(), lockGeneration: 4)
        let ready = NativeDeviceReadiness(interruptionGuardAvailable: true, f13Available: true,
            monitorRegistered: true, stateKnown: true, locked: false, lockGeneration: 4)
        XCTAssertEqual(NativeControlAdmission.error(sessions: sessions, owner: "agent", id: "old", now: 2,
            readiness: { ready }, mode: { _ in "automation" }, legacyReady: { true },
            serviceReady: { _ in true }, recheckNow: { 16 }), "native_session_owned_or_expired")
        XCTAssertFalse(sessions.gate(owner: "agent", id: "old", now: 16))
    }

}
