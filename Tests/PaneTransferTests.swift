// tests/PaneTransferTests.swift
import XCTest
@testable import seahelm

final class PaneTransferTests: XCTestCase {

    // MARK: - PendingWorktreeTransfer Tests

    func testRecordAndMatch() {
        let tracker = PendingTransferTracker()
        tracker.record(sourceWorktreePath: "/repo", worktreeName: "feature-x", sessionId: "s1",
                       paneId: "amux-repo-main")

        let result = tracker.consume(newWorktreePath: "/repo/.worktrees/feature-x")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sourceWorktreePath, "/repo")
        XCTAssertEqual(result?.worktreeName, "feature-x")
        XCTAssertEqual(result?.sessionId, "s1")
        XCTAssertEqual(result?.paneId, "amux-repo-main")   // carried for precise transfer
    }

    func testPaneIdDefaultsNil() {
        let tracker = PendingTransferTracker()
        tracker.record(sourceWorktreePath: "/repo", worktreeName: "fx", sessionId: "s1")
        XCTAssertNil(tracker.consume(newWorktreePath: "/repo/fx")?.paneId)
    }

    func testConsumeRemovesEntry() {
        let tracker = PendingTransferTracker()
        tracker.record(sourceWorktreePath: "/repo", worktreeName: "feature-x", sessionId: "s1")

        _ = tracker.consume(newWorktreePath: "/repo/.worktrees/feature-x")
        let second = tracker.consume(newWorktreePath: "/repo/.worktrees/feature-x")
        XCTAssertNil(second)
    }

    func testNoMatchForUnrelatedPath() {
        let tracker = PendingTransferTracker()
        tracker.record(sourceWorktreePath: "/repo", worktreeName: "feature-x", sessionId: "s1")

        let result = tracker.consume(newWorktreePath: "/other-repo/feature-y")
        XCTAssertNil(result)
    }

    /// Transfers match on worktree NAME alone, so a new worktree in repo B can
    /// consume a transfer whose source pane lives in repo A. The source must still
    /// survive: it is absent from repo B's discovery, and losing it here strands the
    /// worktree with no card and no terminal until the app is relaunched.
    func testCrossRepoNameCollisionKeepsSourceWorktree() {
        // ShipLog is a global singleton; drop anything this test registers so it
        // can't leak sailors into tests that assert on an empty ShipLog.
        defer {
            for path in ["/repo-a", "/repo-b", "/repo-b-worktrees/collide"] {
                for id in ShipLog.shared.terminalIDs(forWorktree: path) {
                    ShipLog.shared.unregister(terminalID: id)
                }
            }
        }
        let coordinator = TabCoordinator(config: Config())
        coordinator.terminalCoordinator = TerminalCoordinator(config: Config(), activeSplitContainer: { nil })
        coordinator.statusPublisher = StatusPublisher(agentConfig: Config().agentDetect)
        coordinator.statusAggregator = WorktreeStatusAggregator()

        // Repo A — the source pane's repo. Its main worktree is what must survive.
        let aMain = WorktreeInfo(path: "/repo-a", branch: "main", commitHash: "aaaa1111", isMainWorktree: true)
        let aTree = SplitTree(worktreePath: aMain.path, rootLeafId: "leaf-a", stationId: "surface-a", sessionName: "a")
        _ = coordinator.workspaceManager.addTab(repoPath: "/repo-a", worktrees: [aMain])
        coordinator.allWorktrees.append((info: aMain, tree: aTree))
        coordinator.worktreeRepoCache[aMain.path] = "/repo-a"
        coordinator.terminalCoordinator.stationManager.registerTree(aTree, forPath: aMain.path)

        // Repo B — where a worktree named "collide" is about to appear.
        let bMain = WorktreeInfo(path: "/repo-b", branch: "main", commitHash: "bbbb2222", isMainWorktree: true)
        let bTree = SplitTree(worktreePath: bMain.path, rootLeafId: "leaf-b", stationId: "surface-b", sessionName: "b")
        let bTab = coordinator.workspaceManager.addTab(repoPath: "/repo-b", worktrees: [bMain])
        coordinator.allWorktrees.append((info: bMain, tree: bTree))
        coordinator.worktreeRepoCache[bMain.path] = "/repo-b"

        // A pane in repo A's main records a transfer for a worktree named "collide"...
        coordinator.pendingTransfers.record(sourceWorktreePath: aMain.path, worktreeName: "collide", sessionId: "s1")

        // ...but repo B's scan surfaces a same-named worktree first and consumes it.
        let bNew = WorktreeInfo(path: "/repo-b-worktrees/collide", branch: "collide", commitHash: "cccc3333", isMainWorktree: false)
        coordinator.reconcileDiscoveredWorktrees(tabIndex: bTab, oldWorktrees: [bMain], freshWorktrees: [bMain, bNew])

        XCTAssertTrue(coordinator.allWorktrees.contains { $0.info.path == aMain.path },
                      "repo-a's main was destroyed by a cross-repo transfer and cannot come back until relaunch")
        XCTAssertEqual(coordinator.worktreeRepoCache[aMain.path], "/repo-a",
                       "repo-a's main must keep its own repo, not inherit repo-b")
    }

    func testMatchByWorktreeNameSuffix() {
        let tracker = PendingTransferTracker()
        tracker.record(sourceWorktreePath: "/repo", worktreeName: "feature-x", sessionId: "s1")

        // Worktree might be created at a sibling path, not nested
        let result = tracker.consume(newWorktreePath: "/worktrees/feature-x")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.worktreeName, "feature-x")
    }

    func testStaleEntriesExpire() {
        let tracker = PendingTransferTracker()
        tracker.record(sourceWorktreePath: "/repo", worktreeName: "old", sessionId: "s1")
        // Manually expire by setting timestamp in the past
        tracker.expireAll()

        let result = tracker.consume(newWorktreePath: "/repo/.worktrees/old")
        XCTAssertNil(result)
    }

    // MARK: - StationManager Transfer Tests

    func testTransferTreeRekeys() {
        let manager = StationManager()
        let info = WorktreeInfo(path: "/repo", branch: "main", commitHash: "abc", isMainWorktree: true)
        let tree = manager.tree(for: info, backend: "local")

        let transferred = manager.transferTree(fromPath: "/repo", toPath: "/worktrees/feature-x")
        XCTAssertNotNil(transferred)
        XCTAssertNil(manager.tree(forPath: "/repo"))
        XCTAssertNotNil(manager.tree(forPath: "/worktrees/feature-x"))
        XCTAssertTrue(transferred === tree)
        // Re-homed: worktreePath must track the destination, or saveSplitLayout
        // (which keys on worktreePath) persists under the old path and the
        // transferred layout is lost on restart.
        XCTAssertEqual(transferred?.worktreePath, "/worktrees/feature-x")
    }

    func testTransferredTreeKeepsRealSessionNames() {
        // zmx can't rename: transferred leaves keep their original (source-derived)
        // session names, so a restore attaches to the still-live session.
        let manager = StationManager()
        let info = WorktreeInfo(path: "/repo", branch: "main", commitHash: "abc", isMainWorktree: true)
        let tree = manager.tree(for: info, backend: "zmx")
        let originalNames = tree.allLeaves.map(\.sessionName)
        let transferred = manager.transferTree(fromPath: "/repo", toPath: "/worktrees/feature-x")
        XCTAssertEqual(transferred?.allLeaves.map(\.sessionName), originalNames)
    }

    func testTransferTreeReturnsNilForUnknownPath() {
        let manager = StationManager()
        let result = manager.transferTree(fromPath: "/nonexistent", toPath: "/dest")
        XCTAssertNil(result)
    }
}
