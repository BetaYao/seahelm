import XCTest
@testable import seahelm

final class TerminalHeaderViewTests: XCTestCase {
    func testTerminalTitlePrefersPane() {
        XCTAssertEqual(TerminalHeaderView.formatTitle(repo: "seahelm", pane: "Fix login"), "Fix login")
    }

    func testTerminalTitleFallsBackToRepo() {
        XCTAssertEqual(TerminalHeaderView.formatTitle(repo: "seahelm", pane: ""), "seahelm")
        XCTAssertEqual(TerminalHeaderView.formatTitle(repo: "", pane: "main"), "main")
        XCTAssertEqual(TerminalHeaderView.formatTitle(repo: "", pane: ""), "")
        XCTAssertEqual(TerminalHeaderView.formatTitle(repo: "  ", pane: " main "), "main")
    }

    // MARK: - Title vs. the edit-mode tab strips

    /// Edit mode gives each column its own tab strip, so the single centered title
    /// duplicates one strip's selected tab and mislabels the other.
    func testTitleHidesWhileEditModeIsOn() {
        let header = TerminalHeaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 38))
        XCTAssertTrue(header.isTitleVisibleForTesting, "title shows in the normal layout")

        header.setEditMode(available: true, isOn: true)
        XCTAssertFalse(header.isTitleVisibleForTesting)

        header.setEditMode(available: true, isOn: false)
        XCTAssertTrue(header.isTitleVisibleForTesting, "leaving edit mode restores it")
    }

    /// Merely *offering* edit mode must not hide the title — only entering it does.
    func testAvailableButOffKeepsTitle() {
        let header = TerminalHeaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 38))
        header.setEditMode(available: true, isOn: false)
        XCTAssertTrue(header.isTitleVisibleForTesting)
    }

    /// A title arriving while edit mode is on must not un-hide the label.
    func testPaneTitleUpdateDoesNotResurrectTheLabel() {
        let header = TerminalHeaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 38))
        header.setEditMode(available: true, isOn: true)
        header.setPaneTitle("AGENTS.md")
        XCTAssertFalse(header.isTitleVisibleForTesting)
    }
}
