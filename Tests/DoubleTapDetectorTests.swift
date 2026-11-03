import XCTest
import AppKit
@testable import seahelm

final class DoubleTapDetectorTests: XCTestCase {
    private var d = DoubleTapDetector()

    private func tap(at t: TimeInterval, hold: TimeInterval = 0.08) -> Bool {
        _ = d.feed(.flags(.control), at: t)
        return d.feed(.flags([]), at: t + hold)
    }

    func testTwoQuickTapsFire() {
        XCTAssertFalse(tap(at: 0))
        XCTAssertTrue(tap(at: 0.25))
        XCTAssertFalse(tap(at: 0.5), "a third tap starts over")
    }

    func testTapsTooFarApartDoNot() {
        XCTAssertFalse(tap(at: 0))
        XCTAssertFalse(tap(at: 1.0))
    }

    func testHeldControlIsNotATap() {
        XCTAssertFalse(tap(at: 0, hold: 0.6))
        XCTAssertFalse(tap(at: 0.7))
    }

    /// Ctrl-C twice: the C in between is a key, so it is a chord, not a tap.
    func testAChordInBetweenCancels() {
        _ = d.feed(.flags(.control), at: 0)
        _ = d.feed(.key, at: 0.05)
        _ = d.feed(.flags([]), at: 0.1)
        XCTAssertFalse(tap(at: 0.2))
    }

    func testAnotherModifierCancels() {
        _ = d.feed(.flags(.control), at: 0)
        _ = d.feed(.flags([.control, .shift]), at: 0.05)
        _ = d.feed(.flags([]), at: 0.1)
        XCTAssertFalse(tap(at: 0.2))
    }

    func testCapsLockDoesNotGetInTheWay() {
        _ = d.feed(.flags([.control, .capsLock]), at: 0)
        _ = d.feed(.flags(.capsLock), at: 0.05)
        _ = d.feed(.flags([.control, .capsLock]), at: 0.2)
        XCTAssertTrue(d.feed(.flags(.capsLock), at: 0.25))
    }
}
