import XCTest

/// Verifies ⌘B collapse moves chrome icons into the terminal header.
final class ChromeCollapseUITests: SeahelmUITestCase {

    func testCommandBCollapsesSidebarChrome() {
        let chrome = page.chrome

        // Expanded: theme / First Mate icons are hosted in the sidebar header.
        XCTAssertTrue(
            chrome.themeButton.waitForExistence(timeout: 15),
            "Expected chrome.icon.theme after launch (sidebar header)"
        )
        XCTAssertTrue(
            chrome.firstMateButton.waitForExistence(timeout: 5),
            "Expected chrome.icon.firstMate after launch"
        )

        page.app.typeKey("b", modifierFlags: .command)

        // Collapsed: icons remain reachable on the terminal header; expand control present.
        XCTAssertTrue(
            chrome.themeButton.waitForExistence(timeout: 5),
            "Expected chrome.icon.theme after ⌘B (terminal header)"
        )
        XCTAssertTrue(
            chrome.sidebarToggle.waitForExistence(timeout: 5),
            "Expected chrome.icon.sidebar expand control after collapse"
        )

        // Sidebar column should no longer be hittable when collapsed.
        if chrome.sidebarHeader.exists {
            XCTAssertFalse(
                chrome.sidebarHeader.isHittable,
                "Sidebar header should not be hittable when collapsed"
            )
        }
    }
}
