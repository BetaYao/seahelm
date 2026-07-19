import XCTest
@testable import seahelm

final class ChromeTitlebarRegionTests: XCTestCase {

    func testTitlebarRegionTargetsSidebarHeaderWhenExpanded() {
        let chrome = WindowChromeController()
        _ = chrome.view
        chrome.applyState(
            ChromeLayoutState(width: 300, collapsed: false, activePane: .firstMate),
            animated: false
        )
        let target = chrome.titlebarRegionFocusTarget()
        XCTAssertEqual(target.accessibilityIdentifier(), "chrome.sidebarHeader")
    }

    func testTitlebarRegionTargetsTerminalHeaderWhenCollapsed() {
        let chrome = WindowChromeController()
        _ = chrome.view
        chrome.applyState(
            ChromeLayoutState(width: 300, collapsed: true, activePane: .firstMate),
            animated: false
        )
        let target = chrome.titlebarRegionFocusTarget()
        XCTAssertEqual(target.accessibilityIdentifier(), "chrome.terminalHeader")
    }

    func testRegionCycleOrderIncludesTitlebarBetweenSidebarAndHelm() {
        let c = RegionFocusController()
        c.setAvailable([.panes, .sidebar, .titlebar, .helm])
        XCTAssertEqual(c.current, .panes)
        c.next(); XCTAssertEqual(c.current, .sidebar)
        c.next(); XCTAssertEqual(c.current, .titlebar)
        c.next(); XCTAssertEqual(c.current, .helm)
        c.next(); XCTAssertEqual(c.current, .panes)
    }
}
