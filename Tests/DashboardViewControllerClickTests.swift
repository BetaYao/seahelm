import XCTest
@testable import seahelm

final class DashboardViewControllerClickTests: XCTestCase {

    // MARK: - Worktree entry

    func testEnteringWorktreeKeepsExpandedSidebarExpanded() {
        let vc = DashboardViewController()
        vc.loadViewIfNeeded()
        vc.updatePanes([makePane(name: "agent-a", worktreePath: "/repo/a")])
        vc.adoptChromeCollapse(false, activePane: .firstMate)
        var requestedCollapse: Bool?
        vc.onRequestSetChromeCollapsed = { requestedCollapse = $0 }
        XCTAssertFalse(vc.isLeftColumnCollapsedState)

        vc.enterWorktree(byWorktreePath: "/repo/a")

        XCTAssertNil(requestedCollapse)
        XCTAssertFalse(vc.isLeftColumnCollapsedState)
    }

    func testEnteringWorktreeKeepsCollapsedSidebarCollapsed() {
        let vc = DashboardViewController()
        vc.loadViewIfNeeded()
        vc.updatePanes([makePane(name: "agent-a", worktreePath: "/repo/a")])
        vc.adoptChromeCollapse(true, activePane: .firstMate)
        var requestedCollapse: Bool?
        vc.onRequestSetChromeCollapsed = { requestedCollapse = $0 }
        XCTAssertTrue(vc.isLeftColumnCollapsedState)

        vc.enterWorktree(byWorktreePath: "/repo/a")

        XCTAssertNil(requestedCollapse)
        XCTAssertTrue(vc.isLeftColumnCollapsedState)
    }

    // MARK: - Row click

    func testRowClickOnUnknownPathDoesNotCallSelectProject() {
        let vc = DashboardViewController()
        let spy = DashboardDelegateSpy()
        vc.dashboardDelegate = spy
        vc.loadViewIfNeeded()
        vc.handleWorktreeRowClickForTesting(path: "/nonexistent")
        XCTAssertFalse(spy.didSelectProjectCalled,
                       "A row click must not call dashboardDidSelectProject")
    }

    func testRowClickSelectsThatWorktree() {
        let vc = DashboardViewController()
        vc.dashboardDelegate = DashboardDelegateSpy()
        vc.loadViewIfNeeded()
        vc.updatePanes([
            makePane(name: "agent-a", worktreePath: "/repo/a"),
            makePane(name: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.handleWorktreeRowClickForTesting(path: "/repo/b")
        XCTAssertEqual(vc.selectedWorktreeId, "/repo/b")
    }

    func testRowClickClosesEditorOverlayWhenSwitchingWorktrees() {
        let vc = DashboardViewController()
        vc.dashboardDelegate = DashboardDelegateSpy()
        vc.loadViewIfNeeded()
        vc.updatePanes([
            makePane(name: "agent-a", worktreePath: "/repo/a"),
            makePane(name: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.showCenterOverlay(NSView(), title: "file.env")
        XCTAssertTrue(vc.hasCenterOverlayForTesting)

        vc.handleWorktreeRowClickForTesting(path: "/repo/b")

        XCTAssertEqual(vc.selectedWorktreeId, "/repo/b")
        XCTAssertFalse(vc.hasCenterOverlayForTesting)
    }

    // MARK: - Selection survives pane churn

    /// Closing a split pane in the selected worktree used to move the selection
    /// to an unrelated worktree: a row was identified by whichever of its panes
    /// registered first, so closing that pane changed the row's id, the stored
    /// selection matched nothing, and the "validate" fallback landed on the first
    /// row of the whole fleet. A rebuild that replaces every Station must leave
    /// the selection exactly where it was.
    func testClosingAPaneKeepsTheSelectionOnTheSameWorktree() {
        let vc = DashboardViewController()
        vc.dashboardDelegate = DashboardDelegateSpy()
        vc.loadViewIfNeeded()
        vc.updatePanes([
            makePane(name: "agent-a", worktreePath: "/repo/a"),
            makePane(name: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.handleWorktreeRowClickForTesting(path: "/repo/b")
        XCTAssertEqual(vc.selectedWorktreeId, "/repo/b")

        // Same worktrees, freshly built rows carrying brand-new Stations — what a
        // pane close followed by the next status poll produces.
        vc.updatePanes([
            makePane(name: "agent-a", worktreePath: "/repo/a"),
            makePane(name: "agent-b", worktreePath: "/repo/b"),
        ])

        XCTAssertEqual(vc.selectedWorktreeId, "/repo/b",
                       "pane churn inside a worktree must not move the selection")
    }

    /// The identity a row is keyed by cannot depend on its panes.
    func testRowIdentityIsTheWorktreePathNotAPane() {
        let first = makePane(name: "agent-a", worktreePath: "/repo/a")
        let second = makePane(name: "renamed", worktreePath: "/repo/a")

        XCTAssertEqual(first.id, "/repo/a")
        XCTAssertEqual(first.id, second.id,
                       "two builds of the same worktree carry the same row id")
        XCTAssertNotEqual(first.station.id, second.station.id,
                          "…even though their Stations differ")
    }

    func testCodeEditorKeepsHorizontalScrollerVisible() {
        let scrollView = NSScrollView()

        CodeEditorScrollCoordinator.configure(scrollView)

        XCTAssertTrue(scrollView.hasHorizontalScroller)
        XCTAssertFalse(scrollView.autohidesScrollers)
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
    }

    func testRowClickNotifiesSelectionChange() {
        let vc = DashboardViewController()
        let spy = DashboardDelegateSpy()
        vc.dashboardDelegate = spy
        vc.loadViewIfNeeded()
        vc.updatePanes([
            makePane(name: "agent-a", worktreePath: "/repo/a"),
            makePane(name: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.adoptChromeCollapse(false, activePane: .firstMate)
        vc.handleWorktreeRowClickForTesting(path: "/repo/b")
        XCTAssertTrue(spy.didChangeSelectionCalled,
                      "First Mate row selection must notify so the path can be persisted")
        XCTAssertEqual(vc.selectedWorktreeId, "/repo/b")
    }

    /// Regression: split-mode row clicks used to live-preview with
    /// `focusTerminal: false`, so the pane looked focused (dim wash) but
    /// rejected typing until a second click on the pane. Clicking a row must
    /// go through `enterWorktree` (which focuses) rather than the preview path.
    func testRowClickInSplitModeSelectsViaEnterWorktree() {
        let vc = DashboardViewController()
        vc.dashboardDelegate = DashboardDelegateSpy()
        vc.loadViewIfNeeded()
        vc.updatePanes([
            makePane(name: "agent-a", worktreePath: "/repo/a"),
            makePane(name: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.adoptChromeCollapse(false, activePane: .firstMate)
        XCTAssertEqual(vc.viewMode, .split)

        vc.handleWorktreeRowClickForTesting(path: "/repo/b")

        XCTAssertEqual(vc.selectedWorktreeId, "/repo/b")
        XCTAssertEqual(vc.overviewSelectedIdForTesting, "/repo/b")
    }

    // MARK: - ⌃⇥ worktree cycle

    /// The bug this fixes: `⌃⇥` swapped the terminal content but left the fleet
    /// list — and the First Mate panel showing it — highlighting the worktree it
    /// just left, so the two disagreed about where you were.
    func testCycleToWorktreeMovesTheOverviewHighlightWithTheContent() {
        let vc = DashboardViewController()
        vc.loadViewIfNeeded()
        vc.updatePanes([
            makePane(name: "agent-a", worktreePath: "/repo/a"),
            makePane(name: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.adoptChromeCollapse(false, activePane: .firstMate)
        vc.cycleToWorktree(path: "/repo/a")

        vc.cycleToWorktree(path: "/repo/b")

        XCTAssertEqual(vc.selectedWorktreeId, "/repo/b")
        XCTAssertEqual(vc.overviewSelectedIdForTesting, "/repo/b",
                       "the fleet list is still highlighting the previous worktree")
    }

    /// Cycling to a worktree that has no row yet (the list hasn't rendered) must
    /// still leave the highlight pointing at it, so the next render agrees.
    func testCycleToWorktreeTracksSelectionWithoutARenderedRow() {
        let vc = DashboardViewController()
        vc.loadViewIfNeeded()
        vc.updatePanes([makePane(name: "agent-a", worktreePath: "/repo/a")])

        vc.cycleToWorktree(path: "/repo/a")

        XCTAssertEqual(vc.overviewSelectedIdForTesting, "/repo/a")
    }

    func testCommitWorktreeSelectionRestoresOverviewHighlight() {
        let vc = DashboardViewController()
        vc.loadViewIfNeeded()
        vc.updatePanes([
            makePane(name: "agent-a", worktreePath: "/repo/a"),
            makePane(name: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.adoptChromeCollapse(false, activePane: .firstMate)
        vc.commitWorktreeSelection(path: "/repo/b")
        XCTAssertEqual(vc.selectedWorktreeId, "/repo/b")
    }
}

// MARK: - Test helpers

private func makePane(name: String, worktreePath: String) -> WorktreeRowInfo {
    let surface = Station()
    return WorktreeRowInfo(
        name: name,
        project: "proj",
        thread: "main",
        paneStatuses: [.idle],
        rolledUpStatus: .idle,
        mostRecentMessage: "No active task.",
        lastUserPrompt: "",
        mostRecentPaneIndex: 1,
        totalDuration: "00:00:00",
        roundDuration: "00:00:00",
        station: surface,
        worktreePath: worktreePath,
        paneCount: 1,
        paneStations: [surface],
        isMainWorktree: false,
        tasks: [],
        activityEvents: [],
        lastActivityAge: "",
        lastActivityAt: nil,
        gitStats: nil,
        currentPaneTitle: name,
        currentPaneRunTime: ""
    )
}

private class DashboardDelegateSpy: DashboardDelegate {
    var didSelectProjectCalled = false
    var didChangeSelectionCalled = false
    var lastProject: String?
    var lastThread: String?
    var browsePath: String?
    var changesPath: String?

    func dashboardDidSelectProject(_ project: String, thread: String) {
        didSelectProjectCalled = true
        lastProject = project
        lastThread = thread
    }
    func dashboardDidRequestEnterProject(_ project: String) {}
    func dashboardDidReorderCards(order: [String]) {}
    func dashboardDidRequestDelete(_ terminalID: String) {}
    func dashboardDidRequestDeleteWithBranch(_ terminalID: String) {}
    func dashboardDidRequestCloseRepo(_ project: String) {}
    func dashboardDidRequestAddProject() {}
    func dashboardDidChangeSelection(_ dashboard: DashboardViewController) {
        didChangeSelectionCalled = true
    }
    func dashboardDidRequestBrowseFiles(worktreePath: String) { browsePath = worktreePath }
    func dashboardDidRequestShowChanges(worktreePath: String) { changesPath = worktreePath }
}
