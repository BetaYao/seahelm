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
        coordinator.statusAggregator = CabinStatusAggregator()
        let infos = coordinator.buildSailorDisplayInfos()
        XCTAssertTrue(infos.isEmpty)
    }

    func testWorktreeDidDeleteRemovesFromList() {
        let coordinator = TabCoordinator(config: Config())
        coordinator.terminalCoordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        coordinator.statusPublisher = StatusPublisher(agentConfig: Config().agentDetect)
        coordinator.statusAggregator = CabinStatusAggregator()
        let info = WorktreeInfo(path: "/tmp/test-wt", branch: "feature", commitHash: "", isMainWorktree: false)
        let tree = SplitTree(worktreePath: info.path, rootLeafId: "leaf-1", stationId: "surface-1", paneSessionKey: "test")
        coordinator.allWorktrees.append((info: info, tree: tree))

        coordinator.worktreeDidDelete(info)
        XCTAssertTrue(coordinator.allWorktrees.isEmpty)
    }

    /// Auto-add follows an agent's cwd, so a repo cloned into a temp dir for a build
    /// must not be joined to the workspace — `workspacePaths` is never pruned, so the
    /// entry would outlive the directory.
    func testEphemeralRepoPathsAreNotAutoAdded() {
        // The exact shape that leaked in: an agent cloned to $TMPDIR and cd'd there.
        XCTAssertTrue(TabCoordinator.isEphemeralRepoPath(
            "/private/var/folders/40/hgk5mdr97v35d47cz8jy36y00000gn/T/betly-desktop-build"))
        XCTAssertTrue(TabCoordinator.isEphemeralRepoPath(NSTemporaryDirectory() + "some-clone"))
        XCTAssertTrue(TabCoordinator.isEphemeralRepoPath("/tmp/scratch-repo"))

        // Real checkouts must still auto-add — this guard only sits on the hook path.
        XCTAssertFalse(TabCoordinator.isEphemeralRepoPath("/Volumes/openbeta/workspace/teamclaw"))
        XCTAssertFalse(TabCoordinator.isEphemeralRepoPath("/Users/me/src/project"))
        // Not a prefix-match false positive: "/tmpfoo" is not under "/tmp".
        XCTAssertFalse(TabCoordinator.isEphemeralRepoPath("/tmpfoo/repo"))
    }

    func testReconcileDiscoveredWorktreesRemovesDeletedWorktree() {
        let coordinator = TabCoordinator(config: Config())
        coordinator.terminalCoordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        coordinator.statusPublisher = StatusPublisher(agentConfig: Config().agentDetect)
        coordinator.statusAggregator = CabinStatusAggregator()

        let main = WorktreeInfo(path: "/repo", branch: "main", commitHash: "abc12345", isMainWorktree: true)
        let deleted = WorktreeInfo(path: "/repo/.worktrees/feature", branch: "feature", commitHash: "def67890", isMainWorktree: false)
        let mainTree = SplitTree(worktreePath: main.path, rootLeafId: "leaf-main", stationId: "surface-main", paneSessionKey: "main")
        let deletedTree = SplitTree(worktreePath: deleted.path, rootLeafId: "leaf-feature", stationId: "surface-feature", paneSessionKey: "feature")

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

    /// A degraded `git worktree list` that omits a live worktree must not tear it
    /// down: the directory is still on disk, so the entry (and its stations) stay.
    func testReconcileDiscoveredWorktreesKeepsWorktreeStillOnDisk() throws {
        let coordinator = TabCoordinator(config: Config())
        coordinator.terminalCoordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        coordinator.statusPublisher = StatusPublisher(agentConfig: Config().agentDetect)
        coordinator.statusAggregator = CabinStatusAggregator()

        // Real directories — the guard's evidence is the filesystem, not the string.
        let repoDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seahelm-reconcile-\(UUID().uuidString)")
        let liveDir = repoDir.appendingPathComponent("live")
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }

        let main = WorktreeInfo(path: repoDir.path, branch: "main", commitHash: "abc12345", isMainWorktree: true)
        let live = WorktreeInfo(path: liveDir.path, branch: "live", commitHash: "def67890", isMainWorktree: false)
        let mainTree = SplitTree(worktreePath: main.path, rootLeafId: "leaf-main", stationId: "surface-main", paneSessionKey: "main")
        let liveTree = SplitTree(worktreePath: live.path, rootLeafId: "leaf-live", stationId: "surface-live", paneSessionKey: "live")

        let tabIndex = coordinator.workspaceManager.addTab(repoPath: repoDir.path, worktrees: [main, live])
        coordinator.allWorktrees.append((info: main, tree: mainTree))
        coordinator.allWorktrees.append((info: live, tree: liveTree))
        coordinator.worktreeRepoCache[main.path] = repoDir.path
        coordinator.worktreeRepoCache[live.path] = repoDir.path

        // Discovery drops `live` even though its directory exists.
        coordinator.reconcileDiscoveredWorktrees(tabIndex: tabIndex, oldWorktrees: [main, live], freshWorktrees: [main])

        XCTAssertEqual(Set(coordinator.allWorktrees.map(\.info.path)), Set([main.path, live.path]))
        XCTAssertEqual(coordinator.worktreeRepoCache[live.path], repoDir.path)
    }

    func testReconcileDiscoveredWorktreesHandlesAddedAndDeletedInSameScan() {
        let coordinator = TabCoordinator(config: Config())
        coordinator.terminalCoordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        coordinator.statusPublisher = StatusPublisher(agentConfig: Config().agentDetect)
        coordinator.statusAggregator = CabinStatusAggregator()

        let main = WorktreeInfo(path: "/repo", branch: "main", commitHash: "abc12345", isMainWorktree: true)
        let deleted = WorktreeInfo(path: "/repo/.worktrees/deleted", branch: "deleted", commitHash: "def67890", isMainWorktree: false)
        let added = WorktreeInfo(path: "/repo/.worktrees/added", branch: "added", commitHash: "1234abcd", isMainWorktree: false)
        let mainTree = SplitTree(worktreePath: main.path, rootLeafId: "leaf-main", stationId: "surface-main", paneSessionKey: "main")
        let deletedTree = SplitTree(worktreePath: deleted.path, rootLeafId: "leaf-deleted", stationId: "surface-deleted", paneSessionKey: "deleted")

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
