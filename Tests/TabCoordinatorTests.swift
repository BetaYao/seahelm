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
        let infos = coordinator.buildWorktreeRowInfos()
        XCTAssertTrue(infos.isEmpty)
    }

    func testWorktreeDidDeleteRemovesFromList() {
        let coordinator = TabCoordinator(config: Config())
        coordinator.terminalCoordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        coordinator.statusPublisher = StatusPublisher(agentConfig: Config().agentDetect)
        coordinator.statusAggregator = WorktreeStatusAggregator()
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

    /// A daemon that generates apps under a hidden directory and runs its own
    /// agents inside them turned each generated app into a permanent project:
    /// those agents inherit `SEAHELM_PANE_ID` from the pane that started the
    /// daemon, so their cwd reaches the hook path indistinguishable from a pane
    /// that moved, and `workspacePaths` is never pruned.
    func testToolStateReposAreNotAutoAdded() {
        XCTAssertTrue(TabCoordinator.isToolStateRepoPath(
            "/Users/me/.amuxd/teams/e84103ca-c229/apps/dcb910dc-1688"))
        XCTAssertTrue(TabCoordinator.isToolStateRepoPath("/Users/me/.local/state/thing/repo"))

        // Real checkouts still auto-add; the guard is about hidden directories,
        // not about hidden *files* or a dot inside a name.
        XCTAssertFalse(TabCoordinator.isToolStateRepoPath("/Volumes/openbeta/workspace/teamclaw"))
        XCTAssertFalse(TabCoordinator.isToolStateRepoPath("/Users/me/src/project.v2"))
    }

    // MARK: - Auto-follow policy

    private let repoA = "/Volumes/openbeta/workspace/teamclaw"
    private let repoB = "/Users/me/.amuxd/teams/t/apps/a"

    /// The move the feature exists for: an agent's cwd lands in another worktree
    /// of the repo the pane is already working on.
    func testFollowsWithinTheSameRepo() {
        XCTAssertTrue(TabCoordinator.shouldAutoFollow(
            currentRepo: repoA, destinationRepo: repoA,
            lastRehomedAt: nil, now: Date(), cooldown: 600))
    }

    /// The pane that was hauled out of `teamclaw-worktrees/integration` into an
    /// amuxd app directory: the events carried the pane's own id, because the
    /// agent emitting them was spawned *by* that pane and inherited its
    /// `SEAHELM_PANE_ID`. Only the cwd's repo tells the two apart.
    func testDoesNotFollowIntoAnotherRepo() {
        XCTAssertFalse(TabCoordinator.shouldAutoFollow(
            currentRepo: repoA, destinationRepo: repoB,
            lastRehomedAt: nil, now: Date(), cooldown: 600))
    }

    /// An unknown repo on either side is not a move we can vouch for.
    func testDoesNotFollowWhenEitherRepoIsUnknown() {
        XCTAssertFalse(TabCoordinator.shouldAutoFollow(
            currentRepo: nil, destinationRepo: repoA,
            lastRehomedAt: nil, now: Date(), cooldown: 600))
        XCTAssertFalse(TabCoordinator.shouldAutoFollow(
            currentRepo: repoA, destinationRepo: nil,
            lastRehomedAt: nil, now: Date(), cooldown: 600))
    }

    /// Claude runs `cd <worktree> && …` for one tool call and is back at the repo
    /// root for the next. Following both bounced the pane in and out and left a
    /// replacement pane behind on every departure, so the agent ended up back on
    /// the card it started from with two stray panes to show for it.
    func testDoesNotFollowAgainDuringTheCooldown() {
        let movedAt = Date()
        XCTAssertFalse(TabCoordinator.shouldAutoFollow(
            currentRepo: repoA, destinationRepo: repoA,
            lastRehomedAt: movedAt, now: movedAt.addingTimeInterval(15), cooldown: 600))
    }

    /// The cooldown delays the pane, it does not pin it: once the agent has
    /// settled somewhere else the next event moves it.
    func testFollowsAgainOnceTheCooldownExpires() {
        let movedAt = Date()
        XCTAssertTrue(TabCoordinator.shouldAutoFollow(
            currentRepo: repoA, destinationRepo: repoA,
            lastRehomedAt: movedAt, now: movedAt.addingTimeInterval(601), cooldown: 600))
    }

    // MARK: - Placeholder replacement

    /// The shape the rule exists for: discovery stands a worktree up with one
    /// pane, nobody touches it, and the agent that made the worktree arrives.
    /// Splitting put the working agent beside an empty terminal on the card.
    func testUntouchedPaneSeahelmCreatedIsAPlaceholder() {
        XCTAssertTrue(TabCoordinator.isPlaceholderPane(
            autoCreated: true, agentType: .unknown, status: .unknown,
            hasActivity: false, showsOnlyPrompt: true))
        XCTAssertTrue(TabCoordinator.isPlaceholderPane(
            autoCreated: true, agentType: .unknown, status: .idle,
            hasActivity: false, showsOnlyPrompt: true))
    }

    /// A pane restored from a saved layout is attached to a zmx session that may
    /// still hold work, and an attach that has not painted yet looks exactly like
    /// an empty one — so provenance, not appearance, is what clears it.
    func testRestoredPaneIsNeverAPlaceholder() {
        XCTAssertFalse(TabCoordinator.isPlaceholderPane(
            autoCreated: false, agentType: .unknown, status: .unknown,
            hasActivity: false, showsOnlyPrompt: true))
    }

    /// nil is "cannot read it" — an asleep pane, a failed read — and a pane about
    /// to be destroyed does not get the benefit of the doubt.
    func testUnreadablePaneIsNotAPlaceholder() {
        XCTAssertFalse(TabCoordinator.isPlaceholderPane(
            autoCreated: true, agentType: .unknown, status: .unknown,
            hasActivity: false, showsOnlyPrompt: nil))
    }

    func testUsedPaneIsNotAPlaceholder() {
        // Something is on screen.
        XCTAssertFalse(TabCoordinator.isPlaceholderPane(
            autoCreated: true, agentType: .unknown, status: .idle,
            hasActivity: false, showsOnlyPrompt: false))
        // An agent is in it.
        XCTAssertFalse(TabCoordinator.isPlaceholderPane(
            autoCreated: true, agentType: .claudeCode, status: .idle,
            hasActivity: false, showsOnlyPrompt: true))
        // It ran something.
        XCTAssertFalse(TabCoordinator.isPlaceholderPane(
            autoCreated: true, agentType: .unknown, status: .idle,
            hasActivity: true, showsOnlyPrompt: true))
        // It is busy, whatever the screen says.
        XCTAssertFalse(TabCoordinator.isPlaceholderPane(
            autoCreated: true, agentType: .unknown, status: .running,
            hasActivity: false, showsOnlyPrompt: true))
    }

    /// "One line of prompt and nothing else" — blank lines around it do not count,
    /// and a prompt plus its first command output does.
    func testPromptOnlyViewport() {
        XCTAssertTrue(Station.promptOnly(""))
        XCTAssertTrue(Station.promptOnly("\n\n"))
        XCTAssertTrue(Station.promptOnly("➜  integration git:(5bfee693) ✗\n\n\n"))
        XCTAssertFalse(Station.promptOnly("➜  integration git:(5bfee693) ✗ pwd\n/Volumes/openbeta\n"))
    }

    func testReconcileDiscoveredWorktreesRemovesDeletedWorktree() {
        let coordinator = TabCoordinator(config: Config())
        coordinator.terminalCoordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        coordinator.statusPublisher = StatusPublisher(agentConfig: Config().agentDetect)
        coordinator.statusAggregator = WorktreeStatusAggregator()

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
        coordinator.statusAggregator = WorktreeStatusAggregator()

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
        coordinator.statusAggregator = WorktreeStatusAggregator()

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

    /// 10s on the 5s timer. This tick is the only thing advancing the elapsed
    /// labels, so it has to stay fast enough that a seconds readout doesn't
    /// visibly freeze.
    func testShouldRefreshDashboardElapsedTimeEveryTenSeconds() {
        XCTAssertFalse(TabCoordinator.shouldRefreshDashboardElapsedTime(tick: 0))
        XCTAssertFalse(TabCoordinator.shouldRefreshDashboardElapsedTime(tick: 1))
        XCTAssertTrue(TabCoordinator.shouldRefreshDashboardElapsedTime(tick: 2))
        XCTAssertFalse(TabCoordinator.shouldRefreshDashboardElapsedTime(tick: 3))
        XCTAssertTrue(TabCoordinator.shouldRefreshDashboardElapsedTime(tick: 4))
    }

    /// Regression: the orphan sweep treats this set as authoritative, so a repo
    /// whose discovery never landed must withhold the whole set rather than
    /// report a partial one — otherwise its live sessions read as orphans.
    func testLivePaneSessionNamesWithheldWhenARepoHasNoWorktrees() {
        var config = Config()
        config.workspacePaths = ["/tmp/repo-a", "/tmp/repo-b"]
        let coordinator = TabCoordinator(config: config)
        coordinator.terminalCoordinator = TerminalCoordinator(config: config, activeSplitContainer: { nil })
        coordinator.runtimeBackend = "zmx"

        let info = WorktreeInfo(path: "/tmp/repo-a", branch: "main", commitHash: "", isMainWorktree: true)
        let tree = SplitTree(worktreePath: info.path, rootLeafId: "leaf-a",
                             stationId: "station-a", paneSessionKey: "seahelm-repo-a-main")
        coordinator.allWorktrees = [(info: info, tree: tree)]
        coordinator.worktreeRepoCache[info.path] = "/tmp/repo-a"

        XCTAssertTrue(coordinator.livePaneSessionNames().isEmpty,
                      "repo-b contributed no worktrees — the set must be withheld")

        let infoB = WorktreeInfo(path: "/tmp/repo-b", branch: "main", commitHash: "", isMainWorktree: true)
        let treeB = SplitTree(worktreePath: infoB.path, rootLeafId: "leaf-b",
                              stationId: "station-b", paneSessionKey: "seahelm-repo-b-main")
        coordinator.allWorktrees.append((info: infoB, tree: treeB))
        coordinator.worktreeRepoCache[infoB.path] = "/tmp/repo-b"

        XCTAssertEqual(coordinator.livePaneSessionNames(),
                       ["seahelm-repo-a-main", "seahelm-repo-b-main"])
    }
}
