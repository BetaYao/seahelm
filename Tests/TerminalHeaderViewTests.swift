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

    private func makeHeader() -> TerminalHeaderView {
        TerminalHeaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 38))
    }

    /// Edit mode gives each column its own tab strip, so the pane title duplicates
    /// one strip's selected tab and mislabels the other. The band still has to hold
    /// the traffic lights, so it shows the cabin instead of going blank.
    func testEditModeSwapsPaneTitleForCabinContext() {
        let header = makeHeader()
        header.setPaneTitle("AGENTS.md")
        header.setCabinContext("seahelm · feat/palette")
        XCTAssertEqual(header.titleTextForTesting, "AGENTS.md")

        header.setEditMode(available: true, isOn: true)
        XCTAssertEqual(header.titleTextForTesting, "seahelm · feat/palette")

        header.setEditMode(available: true, isOn: false)
        XCTAssertEqual(header.titleTextForTesting, "AGENTS.md", "leaving edit mode restores the pane title")
    }

    /// Merely *offering* edit mode must not swap the title — only entering it does.
    func testAvailableButOffKeepsPaneTitle() {
        let header = makeHeader()
        header.setPaneTitle("AGENTS.md")
        header.setEditMode(available: true, isOn: false)
        XCTAssertEqual(header.titleTextForTesting, "AGENTS.md")
    }

    /// A pane title arriving mid-edit-mode must not displace the context.
    func testPaneTitleUpdateDoesNotOverrideContext() {
        let header = makeHeader()
        header.setCabinContext("seahelm · main")
        header.setEditMode(available: true, isOn: true)
        header.setPaneTitle("AGENTS.md")
        XCTAssertEqual(header.titleTextForTesting, "seahelm · main")
    }

    /// …and a context arriving while edit mode is on must land immediately, since
    /// the cabin can change under an open edit layout.
    func testContextUpdateAppliesWhileEditModeIsOn() {
        let header = makeHeader()
        header.setEditMode(available: true, isOn: true)
        header.setCabinContext("teamclaw · fix/thing")
        XCTAssertEqual(header.titleTextForTesting, "teamclaw · fix/thing")
    }
}
