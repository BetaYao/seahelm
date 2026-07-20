import XCTest
@testable import seahelm

final class DashboardViewControllerClickTests: XCTestCase {

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
        gitStats: nil,
        currentPaneTitle: id,
        currentPaneRunTime: ""
    )
}

private class DashboardDelegateSpy: DashboardDelegate {
    var didSelectProjectCalled = false
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
    func dashboardDidChangeSelection(_ dashboard: DashboardViewController) {}
    func dashboardDidRequestBrowseFiles(worktreePath: String) { browsePath = worktreePath }
    func dashboardDidRequestShowChanges(worktreePath: String) { changesPath = worktreePath }
}
