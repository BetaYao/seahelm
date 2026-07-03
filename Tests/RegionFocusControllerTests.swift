import XCTest
@testable import seahelm

final class RegionFocusControllerTests: XCTestCase {

    func testStartsEmpty() {
        let c = RegionFocusController()
        XCTAssertTrue(c.available.isEmpty)
        XCTAssertNil(c.current)
    }

    func testSetAvailableLandsOnFirst() {
        let c = RegionFocusController()
        c.setAvailable([.sidebar, .panes])
        XCTAssertEqual(c.current, .panes)   // normalized to canonical order (panes < sidebar)
    }

    func testAvailableNormalizedToCanonicalOrder() {
        let c = RegionFocusController()
        c.setAvailable([.helm, .titlebar, .panes, .sidebar])
        XCTAssertEqual(c.available, [.panes, .sidebar, .titlebar, .helm])
    }

    func testSetAvailableDedupes() {
        let c = RegionFocusController()
        c.setAvailable([.panes, .panes, .sidebar])
        XCTAssertEqual(c.available, [.panes, .sidebar])
    }

    func testSetAvailablePreservesCurrentWhenStillPresent() {
        let c = RegionFocusController()
        c.setAvailable([.panes, .sidebar, .titlebar])
        c.focus(.titlebar)
        c.setAvailable([.sidebar, .titlebar])   // panes gone, titlebar stays
        XCTAssertEqual(c.current, .titlebar)
    }

    func testSetAvailableResetsCurrentWhenRemoved() {
        let c = RegionFocusController()
        c.setAvailable([.panes, .titlebar])
        c.focus(.titlebar)
        c.setAvailable([.panes, .sidebar])      // titlebar removed
        XCTAssertEqual(c.current, .panes)
    }

    func testFocusOnlyAcceptsAvailable() {
        let c = RegionFocusController()
        c.setAvailable([.panes, .sidebar])
        XCTAssertTrue(c.focus(.sidebar))
        XCTAssertEqual(c.current, .sidebar)
        XCTAssertFalse(c.focus(.helm))          // not available
        XCTAssertEqual(c.current, .sidebar)     // unchanged
    }

    func testNextCyclesForwardWithWrap() {
        let c = RegionFocusController()
        c.setAvailable([.panes, .sidebar, .titlebar])
        XCTAssertEqual(c.current, .panes)
        c.next(); XCTAssertEqual(c.current, .sidebar)
        c.next(); XCTAssertEqual(c.current, .titlebar)
        c.next(); XCTAssertEqual(c.current, .panes)   // wrap
    }

    func testPrevCyclesBackwardWithWrap() {
        let c = RegionFocusController()
        c.setAvailable([.panes, .sidebar, .titlebar])
        c.prev(); XCTAssertEqual(c.current, .titlebar)   // wrap from first
        c.prev(); XCTAssertEqual(c.current, .sidebar)
    }

    func testCyclingSingleRegionIsNoOp() {
        let c = RegionFocusController()
        c.setAvailable([.panes])
        c.next(); XCTAssertEqual(c.current, .panes)
        c.prev(); XCTAssertEqual(c.current, .panes)
    }

    func testCyclingEmptyIsNoOp() {
        let c = RegionFocusController()
        c.next()
        c.prev()
        XCTAssertNil(c.current)
    }
}
