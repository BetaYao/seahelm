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
