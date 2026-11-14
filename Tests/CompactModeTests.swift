import XCTest
@testable import seahelm

final class CompactModeTests: XCTestCase {
    func testEnterBelowThreshold() {
        XCTAssertTrue(CompactMode.shouldBeActive(width: 759, currentlyActive: false))
        XCTAssertTrue(CompactMode.shouldBeActive(width: 700, currentlyActive: false))
    }

    func testStayInactiveInHysteresisBand() {
        XCTAssertFalse(CompactMode.shouldBeActive(width: 760, currentlyActive: false))
        XCTAssertFalse(CompactMode.shouldBeActive(width: 819, currentlyActive: false))
    }

    func testExitAtOrAboveExitThreshold() {
        XCTAssertFalse(CompactMode.shouldBeActive(width: 820, currentlyActive: true))
        XCTAssertFalse(CompactMode.shouldBeActive(width: 900, currentlyActive: true))
    }

    func testStayActiveInHysteresisBand() {
        XCTAssertTrue(CompactMode.shouldBeActive(width: 760, currentlyActive: true))
        XCTAssertTrue(CompactMode.shouldBeActive(width: 819, currentlyActive: true))
    }

    func testEffectiveCollapsed() {
        XCTAssertTrue(CompactMode.effectiveCollapsed(compactActive: true, userSidebarCollapsed: false))
        XCTAssertTrue(CompactMode.effectiveCollapsed(compactActive: false, userSidebarCollapsed: true))
        XCTAssertTrue(CompactMode.effectiveCollapsed(compactActive: true, userSidebarCollapsed: true))
        XCTAssertFalse(CompactMode.effectiveCollapsed(compactActive: false, userSidebarCollapsed: false))
    }

    func testShowPaneTabsRequiresCompactAndMultipleLeaves() {
        XCTAssertFalse(CompactMode.shouldShowPaneTabs(compactActive: true, leafCount: 1, editMode: false))
        XCTAssertTrue(CompactMode.shouldShowPaneTabs(compactActive: true, leafCount: 2, editMode: false))
        XCTAssertTrue(CompactMode.shouldShowPaneTabs(compactActive: false, leafCount: 1, editMode: true))
        XCTAssertFalse(CompactMode.shouldShowPaneTabs(compactActive: false, leafCount: 2, editMode: false))
    }
}
