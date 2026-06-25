import XCTest
@testable import seahelm

private class MockTabCoordinatorDelegate: TabCoordinatorDelegate {
    var embeddedVC: NSViewController?
    var switchTabCalled = false
    var updateTitleBarCalled = false
    var showNewBranchCalled = false
    var showDiffPath: String?
    var clearContentCalled = false

    func tabCoordinator(_ coordinator: TabCoordinator, embedViewController vc: NSViewController) {
        embeddedVC = vc
    }
    func tabCoordinatorDidSwitchTab(_ coordinator: TabCoordinator) {
        switchTabCalled = true
    }
    func tabCoordinatorRequestUpdateTitleBar(_ coordinator: TabCoordinator) {
        updateTitleBarCalled = true
    }
    func tabCoordinatorRequestShowNewBranchDialog(_ coordinator: TabCoordinator) {
        showNewBranchCalled = true
    }
    func tabCoordinatorRequestShowDiff(_ coordinator: TabCoordinator, worktreePath: String) {
        showDiffPath = worktreePath
    }
    func tabCoordinatorRequestClearContentContainer(_ coordinator: TabCoordinator) {
        clearContentCalled = true
    }
}

final class TabCoordinatorTests: XCTestCase {

    func testInitialActiveTabIsZero() {
        let coordinator = TabCoordinator(config: Config())
        XCTAssertEqual(coordinator.activeTabIndex, 0)
    }

    func testSwitchToSameTabIsNoop() {
        let coordinator = TabCoordinator(config: Config())
        let mockDelegate = MockTabCoordinatorDelegate()
        coordinator.delegate = mockDelegate
        coordinator.switchToTab(0)
        XCTAssertFalse(mockDelegate.switchTabCalled)
    }

    func testBuildAgentDisplayInfosEmptyByDefault() {
        let coordinator = TabCoordinator(config: Config())
        coordinator.terminalCoordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        coordinator.statusAggregator = WorktreeStatusAggregator()
        let infos = coordinator.buildSailorDisplayInfos()
        XCTAssertTrue(infos.isEmpty)
    }

    func testWorktreeDidDeleteRemovesFromList() {
        let coordinator = TabCoordinator(config: Config())
        coordinator.terminalCoordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        coordinator.statusPublisher = StatusPublisher(agentConfig: Config().agentDetect)
        coordinator.statusAggregator = WorktreeStatusAggregator()
        let info = WorktreeInfo(path: "/tmp/test-wt", branch: "feature", commitHash: "", isMainWorktree: false)
        let tree = SplitTree(worktreePath: info.path, rootLeafId: "leaf-1", stationId: "surface-1", sessionName: "test")
        coordinator.allWorktrees.append((info: info, tree: tree))

        coordinator.worktreeDidDelete(info)
        XCTAssertTrue(coordinator.allWorktrees.isEmpty)
    }

    func testReconcileDiscoveredWorktreesRemovesDeletedWorktree() {
        let coordinator = TabCoordinator(config: Config())
        coordinator.terminalCoordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        coordinator.statusPublisher = StatusPublisher(agentConfig: Config().agentDetect)
        coordinator.statusAggregator = WorktreeStatusAggregator()

        let main = WorktreeInfo(path: "/repo", branch: "main", commitHash: "abc12345", isMainWorktree: true)
        let deleted = WorktreeInfo(path: "/repo/.worktrees/feature", branch: "feature", commitHash: "def67890", isMainWorktree: false)
        let mainTree = SplitTree(worktreePath: main.path, rootLeafId: "leaf-main", stationId: "surface-main", sessionName: "main")
        let deletedTree = SplitTree(worktreePath: deleted.path, rootLeafId: "leaf-feature", stationId: "surface-feature", sessionName: "feature")

        let tabIndex = coordinator.workspaceManager.addTab(repoPath: "/repo", worktrees: [main, deleted])
        coordinator.allWorktrees.append((info: main, tree: mainTree))
        coordinator.allWorktrees.append((info: deleted, tree: deletedTree))
        coordinator.worktreeRepoCache[main.path] = "/repo"
        coordinator.worktreeRepoCache[deleted.path] = "/repo"

        let changed = coordinator.reconcileDiscoveredWorktrees(tabIndex: tabIndex, oldWorktrees: [main, deleted], freshWorktrees: [main])

        XCTAssertTrue(changed)
        XCTAssertEqual(coordinator.allWorktrees.map(\.info.path), [main.path])
        XCTAssertNil(coordinator.worktreeRepoCache[deleted.path])
        XCTAssertEqual(coordinator.workspaceManager.tabs[tabIndex].worktrees.map(\.path), [main.path])
    }

    func testReconcileDiscoveredWorktreesHandlesAddedAndDeletedInSameScan() {
        let coordinator = TabCoordinator(config: Config())
        coordinator.terminalCoordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        coordinator.statusPublisher = StatusPublisher(agentConfig: Config().agentDetect)
        coordinator.statusAggregator = WorktreeStatusAggregator()

        let main = WorktreeInfo(path: "/repo", branch: "main", commitHash: "abc12345", isMainWorktree: true)
        let deleted = WorktreeInfo(path: "/repo/.worktrees/deleted", branch: "deleted", commitHash: "def67890", isMainWorktree: false)
        let added = WorktreeInfo(path: "/repo/.worktrees/added", branch: "added", commitHash: "1234abcd", isMainWorktree: false)
        let mainTree = SplitTree(worktreePath: main.path, rootLeafId: "leaf-main", stationId: "surface-main", sessionName: "main")
        let deletedTree = SplitTree(worktreePath: deleted.path, rootLeafId: "leaf-deleted", stationId: "surface-deleted", sessionName: "deleted")

        let tabIndex = coordinator.workspaceManager.addTab(repoPath: "/repo", worktrees: [main, deleted])
        coordinator.allWorktrees.append((info: main, tree: mainTree))
        coordinator.allWorktrees.append((info: deleted, tree: deletedTree))
        coordinator.worktreeRepoCache[main.path] = "/repo"
        coordinator.worktreeRepoCache[deleted.path] = "/repo"

        let changed = coordinator.reconcileDiscoveredWorktrees(tabIndex: tabIndex, oldWorktrees: [main, deleted], freshWorktrees: [main, added])

        XCTAssertTrue(changed)
        XCTAssertEqual(Set(coordinator.allWorktrees.map(\.info.path)), Set([main.path, added.path]))
        XCTAssertNil(coordinator.worktreeRepoCache[deleted.path])
        XCTAssertEqual(Set(coordinator.workspaceManager.tabs[tabIndex].worktrees.map(\.path)), Set([main.path, added.path]))
    }
}
