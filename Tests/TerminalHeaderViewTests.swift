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

    // MARK: - Compact pane tab strip (owned by the header)

    private func makeHeader() -> TerminalHeaderView {
        TerminalHeaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 38))
    }

    /// The header owns the strip outright. It was previously moved up from the
    /// column, which left the moved strip's clip view seated at a non-zero
    /// vertical origin — every frame stayed correct while the tabs sat outside
    /// the visible rect, painting an empty row. Owning it removes that failure.
    func testPaneStripIsOwnedAndHiddenUntilCompact() {
        let header = makeHeader()
        XCTAssertTrue(header.paneStrip.superview === header)
        XCTAssertTrue(header.paneStrip.isHidden)

        header.setHoistedStrips(.terminalOnly)
        XCTAssertFalse(header.paneStrip.isHidden)
        XCTAssertTrue(header.isTitleHiddenForTesting, "the strip takes the row")

        header.setHoistedStrips(.none)
        XCTAssertTrue(header.paneStrip.isHidden)
        XCTAssertFalse(header.isTitleHiddenForTesting, "the row goes back to the title")
    }

    /// Compact's pane strip leaves the fork controls on the header.
    func testCompactStripKeepsForkControls() {
        let header = makeHeader()
        header.setForkTarget("@feature")
        header.setForkedInto(title: "#7", toolTip: "Forked into #7")

        header.setHoistedStrips(.terminalOnly)
        header.layoutSubtreeIfNeeded()
        XCTAssertTrue(header.forkButtonIsVisibleForTesting)
        XCTAssertTrue(header.forkedBadgeIsVisibleForTesting)
    }

    /// The fullscreen file viewer titles itself with the whole path, and tail
    /// truncation would drop the filename — the one part that identifies it.
    func testPathTitlesTruncateInTheMiddle() {
        let header = makeHeader()
        header.setPaneTitle("/Volumes/openbeta/workspace/seahelm/Sources/UI/Island/IslandModel.swift")
        XCTAssertEqual(header.titleLineBreakModeForTesting, .byTruncatingMiddle)
        XCTAssertEqual(header.titleToolTipForTesting,
                       "/Volumes/openbeta/workspace/seahelm/Sources/UI/Island/IslandModel.swift")
    }

    /// Pane titles are prose or command lines; those keep tail truncation even
    /// when they happen to mention a directory.
    func testProseTitlesKeepTailTruncation() {
        let header = makeHeader()
        header.setPaneTitle("npx eslint apps/query-service/src")
        XCTAssertEqual(header.titleLineBreakModeForTesting, .byTruncatingTail)

        header.setPaneTitle("Fix the login flake")
        XCTAssertEqual(header.titleLineBreakModeForTesting, .byTruncatingTail)
    }

    func testIsPathLikeClassification() {
        XCTAssertTrue(TerminalHeaderView.isPathLike("~/src/a.swift"))
        XCTAssertTrue(TerminalHeaderView.isPathLike("Sources/a.swift"))
        XCTAssertFalse(TerminalHeaderView.isPathLike("a.swift"))
        XCTAssertFalse(TerminalHeaderView.isPathLike("cd /tmp"))
        XCTAssertFalse(TerminalHeaderView.isPathLike(""))
    }

    /// Tabs must be inside the scroll view's visible rect, not merely well-framed.
    func testStripTabsAreVisibleOnTheHeaderRow() {
        let header = makeHeader()
        header.setHoistedStrips(.terminalOnly)
        header.paneStrip.apply(items: [
            .init(id: "a", title: "First", closable: false),
        ], selectedId: "a")
        header.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.paneStrip.clipOriginYForTesting, 0)
        XCTAssertTrue(header.paneStrip.firstTabIsVisibleForTesting)
    }

    // MARK: - Memory readout

    /// The readout shares a row with a centred title, so it is formatted for a
    /// stable narrow width rather than precision.
    func testMemoryFormatting() {
        XCTAssertEqual(TerminalHeaderView.formatMemory(bytes: 512), "<1 MB")
        XCTAssertEqual(TerminalHeaderView.formatMemory(bytes: 340 * 1_048_576), "340 MB")
        XCTAssertEqual(TerminalHeaderView.formatMemory(bytes: 1023 * 1_048_576), "1023 MB")
        XCTAssertEqual(TerminalHeaderView.formatMemory(bytes: 1024 * 1_048_576), "1.0 GB")
        XCTAssertEqual(TerminalHeaderView.formatMemory(bytes: 2560 * 1_048_576), "2.5 GB")
    }

    /// Zero/nil means "not measured", which must read as blank rather than 0 MB.
    func testMemoryLabelHiddenWithoutAValue() {
        let header = makeHeader()
        header.setPaneMemory(nil)
        XCTAssertTrue(header.memoryLabelIsHiddenForTesting)
        header.setPaneMemory(0)
        XCTAssertTrue(header.memoryLabelIsHiddenForTesting)
        header.setPaneMemory(340 * 1_048_576)
        XCTAssertFalse(header.memoryLabelIsHiddenForTesting)
        XCTAssertEqual(header.memoryTextForTesting, "340 MB")
    }

    /// With First Mate over the terminal side the header is its: its memory, its
    /// name, and none of the focused pane's own controls.
    func testFirstMateTakesTheWholeHeader() {
        let header = makeHeader()
        header.setPaneTitle("Fix the login")
        header.setPaneMemory(516 * 1_048_576)
        header.setForkTarget("@other")
        header.setFirstMateMode(true)
        XCTAssertTrue(header.memoryLabelIsHiddenForTesting, "not the pane's figure while First Mate's is unknown")
        header.setFirstMateMemory(169 * 1_048_576)
        XCTAssertEqual(header.memoryTextForTesting, "169 MB")
        XCTAssertFalse(header.forkButtonIsVisibleForTesting)
        header.setPaneMemory(600 * 1_048_576)
        XCTAssertEqual(header.memoryTextForTesting, "169 MB", "the pane's refresh does not leak through")

        header.setFirstMateMode(false)
        XCTAssertEqual(header.memoryTextForTesting, "600 MB")
        XCTAssertTrue(header.forkButtonIsVisibleForTesting)
    }
}
