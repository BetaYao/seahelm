import XCTest
@testable import seahelm

final class OSCProgressTests: XCTestCase {

    func testDecodesDeterminateReport() throws {
        let p = try XCTUnwrap(OSCProgress(wire: "1;42"))
        XCTAssertEqual(p.state, .set)
        XCTAssertEqual(p.percent, 42)
        XCTAssertEqual(try XCTUnwrap(p.fraction), 0.42, accuracy: 0.0001)
        XCTAssertTrue(p.isActive)
    }

    /// GhosttyBridge writes an empty percent when libghostty reports -1.
    func testMissingPercentRunsIndeterminate() throws {
        let p = try XCTUnwrap(OSCProgress(wire: "1;"))
        XCTAssertEqual(p.state, .set)
        XCTAssertNil(p.percent)
        XCTAssertNil(p.fraction, "no percentage → the bar must sweep, not sit at 0%")
    }

    func testIndeterminateStateIgnoresPercent() throws {
        let p = try XCTUnwrap(OSCProgress(wire: "3;50"))
        XCTAssertEqual(p.state, .indeterminate)
        XCTAssertNil(p.fraction)
        XCTAssertTrue(p.isActive)
    }

    func testRemoveIsInactive() throws {
        let p = try XCTUnwrap(OSCProgress(wire: "0;"))
        XCTAssertEqual(p.state, .remove)
        XCTAssertFalse(p.isActive, "state 0 is the terminal clearing the bar")
    }

    func testErrorAndPauseKeepTheirPercent() throws {
        let error = try XCTUnwrap(OSCProgress(wire: "2;80"))
        XCTAssertEqual(error.state, .error)
        XCTAssertEqual(try XCTUnwrap(error.fraction), 0.8, accuracy: 0.0001)

        let paused = try XCTUnwrap(OSCProgress(wire: "4;10"))
        XCTAssertEqual(paused.state, .pause)
        XCTAssertEqual(try XCTUnwrap(paused.fraction), 0.1, accuracy: 0.0001)
    }

    func testRejectsGarbage() {
        XCTAssertNil(OSCProgress(wire: ""), "never reported")
        XCTAssertNil(OSCProgress(wire: "9;0"), "state outside the enum")
        XCTAssertNil(OSCProgress(wire: "x;1"))
    }

    /// Out-of-range percentages degrade to indeterminate rather than drawing a
    /// bar wider than the pane.
    func testOutOfRangePercentIsDropped() throws {
        let p = try XCTUnwrap(OSCProgress(wire: "1;900"))
        XCTAssertNil(p.percent)
        XCTAssertNil(p.fraction)
    }

    func testRoundTripsWhatGhosttyBridgeWrites() throws {
        // Mirrors GhosttyBridge's encoding: "\(state.rawValue);\(percent)".
        for (state, raw) in [(OSCProgress.State.set, 1), (.error, 2), (.pause, 4)] {
            let wire = "\(raw);7"
            XCTAssertEqual(OSCProgress(wire: wire)?.state, state)
            XCTAssertEqual(OSCProgress(wire: wire)?.percent, 7)
        }
    }
}
