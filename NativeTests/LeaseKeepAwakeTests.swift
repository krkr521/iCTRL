import XCTest
@testable import NativePolicy

final class LeaseKeepAwakeTests: XCTestCase {
    typealias Lease = LeaseKeepAwakePolicy.Lease
    func testNoLeaseAndExpiredLeaseNeverPulse() {
        var p = LeaseKeepAwakePolicy()
        XCTAssertFalse(p.admit(nil, locked: false, now: 1))
        XCTAssertFalse(p.admit(Lease(id: "a", deadline: 2), locked: false, now: 2))
    }
    func testPulseCadenceAndLongQueueDelayNeverCatchUp() {
        var p = LeaseKeepAwakePolicy()
        let lease = Lease(id: "a", deadline: 300)
        XCTAssertTrue(p.admit(lease, locked: false, now: 0))
        XCTAssertFalse(p.admit(lease, locked: false, now: 9.99))
        XCTAssertTrue(p.admit(lease, locked: false, now: 10))
        XCTAssertTrue(p.admit(lease, locked: false, now: 51))
        XCTAssertFalse(p.admit(lease, locked: false, now: 51))
        XCTAssertFalse(p.admit(lease, locked: false, now: 60))
        XCTAssertTrue(p.admit(lease, locked: false, now: 61))
    }
    func testLockedLeaseDoesNotResumeAfterManualUnlock() {
        var p = LeaseKeepAwakePolicy()
        let lease = Lease(id: "a", deadline: 300)
        XCTAssertFalse(p.admit(lease, locked: true, now: 0))
        XCTAssertFalse(p.admit(lease, locked: false, now: 10))
        XCTAssertTrue(p.admit(Lease(id: "b", deadline: 300), locked: false, now: 11))
    }
    func testFailureDisconnectAndStopLatchOldLease() {
        for mode in 0...2 {
            var p = LeaseKeepAwakePolicy()
            let lease = Lease(id: "a", deadline: 300)
            XCTAssertTrue(p.admit(lease, locked: false, now: 0))
            if mode == 0 { p.fail() }
            if mode == 1 { XCTAssertFalse(p.admit(nil, locked: false, now: 1)) }
            if mode == 2 { p.stop() }
            XCTAssertFalse(p.admit(lease, locked: false, now: 20))
        }
    }
    func testInvalidAndRegressedClocksFailClosed() {
        for bad in [Double.nan, Double.infinity, -1] {
            var p = LeaseKeepAwakePolicy()
            let lease = Lease(id: "a", deadline: 300)
            XCTAssertTrue(p.admit(lease, locked: false, now: 10))
            XCTAssertFalse(p.admit(lease, locked: false, now: bad))
            XCTAssertFalse(p.admit(lease, locked: false, now: 30))
        }
        var p = LeaseKeepAwakePolicy()
        XCTAssertFalse(p.admit(Lease(id: "a", deadline: .nan), locked: false, now: 0))
        XCTAssertFalse(p.admit(Lease(id: "", deadline: 30), locked: false, now: 1))
    }
    func testSwitchingLeaseCannotRevivePreviousOwner() {
        var p = LeaseKeepAwakePolicy()
        let a = Lease(id: "a", deadline: 300)
        XCTAssertTrue(p.admit(a, locked: false, now: 0))
        XCTAssertTrue(p.admit(Lease(id: "b", deadline: 300), locked: false, now: 1))
        XCTAssertFalse(p.admit(a, locked: false, now: 20))
    }
}
