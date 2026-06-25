import XCTest
@testable import seahelm

final class DashboardViewControllerClickTests: XCTestCase {

    // MARK: - Single-click

    func testSingleClickUpdatesSelectedSailorId() {
        let vc = DashboardViewController()
        vc.agentCardClicked(agentId: "agent-1")
        XCTAssertEqual(vc.selectedSailorId, "agent-1")
    }

    func testSingleClickDoesNotCallDelegate() {
        let vc = DashboardViewController()
        let spy = DashboardDelegateSpy()
        vc.dashboardDelegate = spy
        vc.agentCardClicked(agentId: "agent-1")
        XCTAssertFalse(spy.didSelectProjectCalled,
                       "Single click must not call dashboardDidSelectProject")
    }

    // MARK: - Double-click on unknown agentId (guard path)

    func testDoubleClickWithUnknownSailorIdIsNoop() {
        let vc = DashboardViewController()
        let spy = DashboardDelegateSpy()
        vc.dashboardDelegate = spy
        vc.agentCardDoubleClicked(agentId: "nonexistent")
        XCTAssertFalse(spy.didSelectProjectCalled,
                       "Double click on unknown agentId must not call delegate")
    }

    func testBrowseFilesRequestUsesRightClickedAgentWorktreePath() {
        let vc = DashboardViewController()
        let spy = DashboardDelegateSpy()
        vc.dashboardDelegate = spy
        vc.loadViewIfNeeded()
        vc.updateSailors([
            makeSailor(id: "agent-a", worktreePath: "/repo/a"),
            makeSailor(id: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.agentCardClicked(agentId: "agent-a")

        vc.agentCardDidRequestBrowseFiles(agentId: "agent-b")

        XCTAssertEqual(spy.browsePath, "/repo/b")
        XCTAssertNil(spy.changesPath)
    }

    func testShowChangesRequestUsesRightClickedSailorWorktreePath() {
        let vc = DashboardViewController()
        let spy = DashboardDelegateSpy()
        vc.dashboardDelegate = spy
        vc.loadViewIfNeeded()
        vc.updateSailors([
            makeSailor(id: "agent-a", worktreePath: "/repo/a"),
            makeSailor(id: "agent-b", worktreePath: "/repo/b"),
        ])
        vc.agentCardClicked(agentId: "agent-a")

        vc.agentCardDidRequestShowChanges(agentId: "agent-b")

        XCTAssertEqual(spy.changesPath, "/repo/b")
        XCTAssertNil(spy.browsePath)
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
        activityEvents: []
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
