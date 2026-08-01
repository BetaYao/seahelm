import XCTest
@testable import seahelm

final class DashboardViewControllerClickTests: XCTestCase {

    // MARK: - Worktree entry

    func testEnteringWorktreeKeepsExpandedSidebarExpanded() {
        let vc = DashboardViewController()
        vc.loadViewIfNeeded()
        vc.updateSailors([makeSailor(id: "agent-a", worktreePath: "/repo/a")])
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
        vc.updateSailors([makeSailor(id: "agent-a", worktreePath: "/repo/a")])
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
        vc.updateSailors([
            makeSailor(id: "agent-a", worktreePath: "/repo/a"),
            makeSailor(id: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.handleWorktreeRowClickForTesting(path: "/repo/b")
        XCTAssertEqual(vc.selectedSailorId, "agent-b")
    }

    func testRowClickClosesEditorOverlayWhenSwitchingWorktrees() {
        let vc = DashboardViewController()
        vc.dashboardDelegate = DashboardDelegateSpy()
        vc.loadViewIfNeeded()
        vc.updateSailors([
            makeSailor(id: "agent-a", worktreePath: "/repo/a"),
            makeSailor(id: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.showCenterOverlay(NSView(), title: "file.env")
        XCTAssertTrue(vc.hasCenterOverlayForTesting)

        vc.handleWorktreeRowClickForTesting(path: "/repo/b")

        XCTAssertEqual(vc.selectedSailorId, "agent-b")
        XCTAssertFalse(vc.hasCenterOverlayForTesting)
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
        vc.updateSailors([
            makeSailor(id: "agent-a", worktreePath: "/repo/a"),
            makeSailor(id: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.adoptChromeCollapse(false, activePane: .firstMate)
        vc.handleWorktreeRowClickForTesting(path: "/repo/b")
        XCTAssertTrue(spy.didChangeSelectionCalled,
                      "First Mate row selection must notify so the path can be persisted")
        XCTAssertEqual(vc.selectedSailorId, "agent-b")
    }

    /// Regression: split-mode row clicks used to live-preview with
    /// `focusTerminal: false`, so the pane looked focused (dim wash) but
    /// rejected typing until a second click on the pane. Clicking a row must
    /// go through `enterWorktree` (which focuses) rather than the preview path.
    func testRowClickInSplitModeSelectsViaEnterWorktree() {
        let vc = DashboardViewController()
        vc.dashboardDelegate = DashboardDelegateSpy()
        vc.loadViewIfNeeded()
        vc.updateSailors([
            makeSailor(id: "agent-a", worktreePath: "/repo/a"),
            makeSailor(id: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.adoptChromeCollapse(false, activePane: .firstMate)
        XCTAssertEqual(vc.viewMode, .split)

        vc.handleWorktreeRowClickForTesting(path: "/repo/b")

        XCTAssertEqual(vc.selectedSailorId, "agent-b")
        XCTAssertEqual(vc.overviewSelectedIdForTesting, "agent-b")
    }

    // MARK: - ⌃⇥ cabin cycle

    /// The bug this fixes: `⌃⇥` swapped the terminal content but left the fleet
    /// list — and the First Mate panel showing it — highlighting the cabin it
    /// just left, so the two disagreed about where you were.
    func testCycleToCabinMovesTheOverviewHighlightWithTheContent() {
        let vc = DashboardViewController()
        vc.loadViewIfNeeded()
        vc.updateSailors([
            makeSailor(id: "agent-a", worktreePath: "/repo/a"),
            makeSailor(id: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.adoptChromeCollapse(false, activePane: .firstMate)
        vc.cycleToCabin(path: "/repo/a")

        vc.cycleToCabin(path: "/repo/b")

        XCTAssertEqual(vc.selectedSailorId, "agent-b")
        XCTAssertEqual(vc.overviewSelectedIdForTesting, "agent-b",
                       "the fleet list is still highlighting the previous cabin")
    }

    /// Cycling to a cabin that has no row yet (the list hasn't rendered) must
    /// still leave the highlight pointing at it, so the next render agrees.
    func testCycleToCabinTracksSelectionWithoutARenderedRow() {
        let vc = DashboardViewController()
        vc.loadViewIfNeeded()
        vc.updateSailors([makeSailor(id: "agent-a", worktreePath: "/repo/a")])

        vc.cycleToCabin(path: "/repo/a")

        XCTAssertEqual(vc.overviewSelectedIdForTesting, "agent-a")
    }

    func testCommitWorktreeSelectionRestoresOverviewHighlight() {
        let vc = DashboardViewController()
        vc.loadViewIfNeeded()
        vc.updateSailors([
            makeSailor(id: "agent-a", worktreePath: "/repo/a"),
            makeSailor(id: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.adoptChromeCollapse(false, activePane: .firstMate)
        vc.commitWorktreeSelection(path: "/repo/b")
        XCTAssertEqual(vc.selectedSailorId, "agent-b")
    }
}

// MARK: - Test helpers

private func makeSailor(id: String, worktreePath: String) -> SailorDisplayInfo {
    let surface = Station()
    return SailorDisplayInfo(
        id: id,
        name: id,
        project: "proj",
        thread: "main",
        paneStatuses: [.idle],
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
        currentPaneTitle: id,
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
    func dashboardDidRequestCloseRepo(_ project: String) {}
    func dashboardDidRequestAddProject() {}
    func dashboardDidChangeSelection(_ dashboard: DashboardViewController) {
        didChangeSelectionCalled = true
    }
    func dashboardDidRequestBrowseFiles(worktreePath: String) { browsePath = worktreePath }
    func dashboardDidRequestShowChanges(worktreePath: String) { changesPath = worktreePath }
}
