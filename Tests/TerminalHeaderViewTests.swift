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

    // MARK: - Edit-mode tab strips (owned by the header)

    /// The header owns the strips outright. They were previously moved up from the
    /// columns, which left the moved strip's clip view seated at a non-zero vertical
    /// origin — every frame stayed correct while the tabs sat outside the visible
    /// rect, painting an empty row. Owning them removes that failure mode.
    func testStripsAreOwnedAndHiddenUntilEditMode() {
        let header = makeHeader()
        XCTAssertTrue(header.editTerminalStrip.superview === header)
        XCTAssertTrue(header.editPreviewStrip.superview === header)
        XCTAssertTrue(header.editTerminalStrip.isHidden)

        header.setEditStripsActive(true, ratio: 0.5)
        XCTAssertFalse(header.editTerminalStrip.isHidden)
        XCTAssertFalse(header.editPreviewStrip.isHidden)
        XCTAssertTrue(header.isTitleHiddenForTesting, "the strips take the whole row")

        header.setEditStripsActive(false, ratio: 0.5)
        XCTAssertTrue(header.editTerminalStrip.isHidden)
        XCTAssertFalse(header.isTitleHiddenForTesting, "the row goes back to the title")
    }

    /// The seam has to land on the column divider, computed from the same width.
    func testSeamTracksTheDividerRatio() {
        let header = makeHeader()
        header.setEditStripsActive(true, ratio: 0.5)
        header.layoutSubtreeIfNeeded()
        let midSeam = header.editPreviewStrip.frame.minX

        header.setEditStripRatio(0.75)
        header.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(header.editPreviewStrip.frame.minX, midSeam,
                             "a wider terminal column pushes the seam right")
    }

    /// A divider dragged to the far edge must not drive a strip negative.
    func testExtremeRatiosKeepBothStripsPositive() {
        let header = makeHeader()
        header.setEditStripsActive(true, ratio: 0.5)

        for ratio in [0.0, 0.02, 0.98, 1.0] as [CGFloat] {
            header.setEditStripRatio(ratio)
            header.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(header.editTerminalStrip.frame.width, 0, "terminal strip at ratio \(ratio)")
            XCTAssertGreaterThan(header.editPreviewStrip.frame.width, 0, "preview strip at ratio \(ratio)")
        }
    }

    /// Tabs must be inside the scroll view's visible rect, not merely well-framed.
    func testStripTabsAreVisibleOnTheHeaderRow() {
        let header = makeHeader()
        header.setEditStripsActive(true, ratio: 0.5)
        header.editTerminalStrip.apply(items: [
            .init(id: "a", title: "First", closable: false),
        ], selectedId: "a")
        header.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.editTerminalStrip.clipOriginYForTesting, 0)
        XCTAssertTrue(header.editTerminalStrip.firstTabIsVisibleForTesting)
    }
}
