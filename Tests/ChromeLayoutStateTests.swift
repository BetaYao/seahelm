import XCTest
@testable import seahelm

final class ChromeLayoutStateTests: XCTestCase {
    func testToggleCollapseRemembersLastPane() {
        var s = ChromeLayoutState(width: 300, collapsed: false, activePane: .firstMate)
        s.setActivePane(.files)
        s.toggleCollapsed()
        XCTAssertTrue(s.isCollapsed)
        s.toggleCollapsed()
        XCTAssertFalse(s.isCollapsed)
        XCTAssertEqual(s.activePane, .files)
    }

    func testExpandFromCollapsedWithNoPaneDefaultsToFirstMate() {
        var s = ChromeLayoutState(width: 300, collapsed: true, activePane: nil)
        s.toggleCollapsed()
        XCTAssertFalse(s.isCollapsed)
        XCTAssertEqual(s.activePane, .firstMate)
    }

    func testSelectSamePaneWhenExpandedCollapses() {
        var s = ChromeLayoutState(width: 300, collapsed: false, activePane: .files)
        s.selectPane(.files) // re-click active → collapse (today's toggleSide)
        XCTAssertTrue(s.isCollapsed)
        XCTAssertEqual(s.activePane, .files)
    }

    func testSelectDifferentPaneExpandsAndSwitches() {
        var s = ChromeLayoutState(width: 300, collapsed: false, activePane: .files)
        s.selectPane(.changes)
        XCTAssertFalse(s.isCollapsed)
        XCTAssertEqual(s.activePane, .changes)
    }
}
