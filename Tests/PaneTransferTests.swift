// tests/PaneTransferTests.swift
import XCTest
@testable import seahelm

final class PaneTransferTests: XCTestCase {

    // MARK: - PendingTransferTracker

    func testRecordAndConsumeByPath() {
        let tracker = PendingTransferTracker()
        tracker.record(worktreePath: "/repo/.claude/worktrees/feature-x", paneId: "seahelm-repo-main")

        let result = tracker.consume(newWorktreePath: "/repo/.claude/worktrees/feature-x")
        XCTAssertEqual(result?.worktreePath, "/repo/.claude/worktrees/feature-x")
        XCTAssertEqual(result?.paneId, "seahelm-repo-main")
    }

    func testConsumeRemovesEntry() {
        let tracker = PendingTransferTracker()
        tracker.record(worktreePath: "/repo/wt", paneId: "p1")
        _ = tracker.consume(newWorktreePath: "/repo/wt")
        XCTAssertNil(tracker.consume(newWorktreePath: "/repo/wt"))
    }

    /// The old tracker matched on directory NAME, so a new worktree in repo B
    /// could consume a transfer recorded by a pane in repo A and the transfer
    /// then destroyed A's tree. Matching on the full path removes the ambiguity
    /// rather than defending against it.
    func testSameNameInAnotherRepoDoesNotMatch() {
        let tracker = PendingTransferTracker()
        tracker.record(worktreePath: "/repo-a-worktrees/collide", paneId: "p1")
        XCTAssertNil(tracker.consume(newWorktreePath: "/repo-b-worktrees/collide"))
        XCTAssertNotNil(tracker.consume(newWorktreePath: "/repo-a-worktrees/collide"))
    }

    func testReRecordingSamePathDoesNotStack() {
        let tracker = PendingTransferTracker()
        tracker.record(worktreePath: "/repo/wt", paneId: "p1")
        tracker.record(worktreePath: "/repo/wt", paneId: "p2")
        XCTAssertEqual(tracker.consume(newWorktreePath: "/repo/wt")?.paneId, "p2")
        XCTAssertNil(tracker.consume(newWorktreePath: "/repo/wt"))
    }

    func testStaleEntriesExpire() {
        let tracker = PendingTransferTracker()
        tracker.record(worktreePath: "/repo/wt", paneId: "p1")
        tracker.expireAll()
        XCTAssertNil(tracker.consume(newWorktreePath: "/repo/wt"))
    }

    // MARK: - StationManager.moveLeaf

    private func info(_ path: String) -> WorktreeInfo {
        WorktreeInfo(path: path, branch: "main", commitHash: "abc", isMainWorktree: true)
    }

    func testMoveLeafFromSinglePaneWorktreeEmptiesTheSource() {
        let manager = StationManager()
        let tree = manager.tree(for: info("/repo"), backend: "zmx")
        let stationId = tree.allLeaves[0].stationId

        let move = manager.moveLeaf(stationId: stationId, toPath: "/repo-worktrees/feature")
        XCTAssertNotNil(move)
        XCTAssertEqual(move?.sourcePath, "/repo")
        XCTAssertEqual(move?.sourceEmptied, true)
        // The source keeps no tree — its card is left empty rather than handed a
        // pane nobody asked for, which is what keeps the undo a clean reverse.
        XCTAssertNil(manager.tree(forPath: "/repo"))
        XCTAssertEqual(manager.tree(forPath: "/repo-worktrees/feature")?.leafCount, 1)
    }

    func testMovedLeafKeepsItsSessionName() {
        // zmx cannot rename a session, so the live pane stays addressable only by
        // the name it was created with.
        let manager = StationManager()
        let tree = manager.tree(for: info("/repo"), backend: "zmx")
        let original = tree.allLeaves[0].paneSessionKey
        let stationId = tree.allLeaves[0].stationId

        let move = manager.moveLeaf(stationId: stationId, toPath: "/repo-worktrees/feature")
        XCTAssertEqual(move?.tree.allLeaves.first?.paneSessionKey, original)
        XCTAssertFalse(original.isEmpty)
    }

    func testDestinationTreeNamesLaterPanesAfterItsOwnWorktree() {
        // The adopted leaf keeps its old name; panes split off afterwards must not.
        let manager = StationManager()
        let tree = manager.tree(for: info("/repo"), backend: "zmx")
        let stationId = tree.allLeaves[0].stationId

        let move = manager.moveLeaf(stationId: stationId, toPath: "/repo-worktrees/feature")
        let expectedBase = SessionManager.persistentSessionName(for: "/repo-worktrees/feature")
        XCTAssertTrue(move?.tree.nextSessionName().hasPrefix(expectedBase) == true,
                      "new panes in the destination should be named after it, got \(move?.tree.nextSessionName() ?? "nil")")
    }

    func testMoveLeafTakesOnlyTheNamedPane() {
        let manager = StationManager()
        let tree = manager.tree(for: info("/repo"), backend: "zmx")
        let siblingStation = Station()
        StationRegistry.shared.register(siblingStation)
        tree.splitFocusedLeaf(axis: .horizontal, newLeafId: "leaf-2",
                              newStationId: siblingStation.id, newSessionName: "seahelm-repo-2")
        let movingStationId = tree.allLeaves.first { $0.stationId != siblingStation.id }!.stationId

        let move = manager.moveLeaf(stationId: movingStationId, toPath: "/repo-worktrees/feature")
        XCTAssertEqual(move?.sourceEmptied, false)
        // The sibling has its own agent doing its own work — it must not follow.
        XCTAssertEqual(manager.tree(forPath: "/repo")?.leafCount, 1)
        XCTAssertEqual(manager.tree(forPath: "/repo")?.allLeaves.first?.stationId, siblingStation.id)
        XCTAssertEqual(move?.tree.leafCount, 1)
    }

    func testMoveIntoOccupiedWorktreeJoinsItInsteadOfReplacing() {
        let manager = StationManager()
        let source = manager.tree(for: info("/repo"), backend: "zmx")
        let destination = manager.tree(for: info("/repo-worktrees/feature"), backend: "zmx")
        let residentStationId = destination.allLeaves[0].stationId
        let movingStationId = source.allLeaves[0].stationId

        let move = manager.moveLeaf(stationId: movingStationId, toPath: "/repo-worktrees/feature")
        XCTAssertEqual(move?.tree.leafCount, 2, "replacing the tree would orphan the resident pane")
        XCTAssertTrue(move?.tree.allLeaves.contains { $0.stationId == residentStationId } == true)
        XCTAssertTrue(move?.tree.allLeaves.contains { $0.stationId == movingStationId } == true)
    }

    /// The pane that leaves keeps the worktree's canonical zmx session name —
    /// zmx has no rename — so a replacement pane must claim a different one or
    /// both panes drive the same live session.
    func testReplacementPaneDoesNotReuseTheDepartedPanesSessionName() {
        let manager = StationManager()
        let source = info("/repo")
        let tree = manager.tree(for: source, backend: "zmx")
        let departedName = tree.allLeaves[0].paneSessionKey
        XCTAssertEqual(departedName, SessionManager.persistentSessionName(for: "/repo"))

        let move = manager.moveLeaf(stationId: tree.allLeaves[0].stationId,
                                    toPath: "/repo-worktrees/feature")
        XCTAssertEqual(move?.sourceEmptied, true)

        let replacement = manager.replacementTree(for: source, backend: "zmx")
        XCTAssertNotEqual(replacement.allLeaves[0].paneSessionKey, departedName)
        XCTAssertFalse(replacement.allLeaves[0].paneSessionKey.isEmpty)
    }

    func testReplacementPaneTakesTheCanonicalNameWhenItIsFree() {
        let manager = StationManager()
        let source = info("/repo")
        let replacement = manager.replacementTree(for: source, backend: "zmx")
        XCTAssertEqual(replacement.allLeaves[0].paneSessionKey,
                       SessionManager.persistentSessionName(for: "/repo"))
    }

    /// A stale `focusedId` must not cost the destination its panes. `removeLeaf`
    /// reassigns focus, and a tree can be adopted into long after its focus moved,
    /// so adopting has to attach to *some* leaf rather than trusting focus — the
    /// earlier form replaced `root` outright and orphaned every Station in it.
    func testAdoptIntoTreeWithStaleFocusKeepsExistingPanes() {
        let manager = StationManager()
        let destination = manager.tree(for: info("/repo-worktrees/feature"), backend: "zmx")
        let residentStationId = destination.allLeaves[0].stationId
        destination.focusedId = "no-such-leaf"

        let source = manager.tree(for: info("/repo"), backend: "zmx")
        let movingStationId = source.allLeaves[0].stationId

        let move = manager.moveLeaf(stationId: movingStationId, toPath: "/repo-worktrees/feature")
        XCTAssertEqual(move?.tree.leafCount, 2)
        XCTAssertTrue(move?.tree.allLeaves.contains { $0.stationId == residentStationId } == true,
                      "the resident pane was orphaned by a stale focus")
        XCTAssertTrue(move?.tree.allLeaves.contains { $0.stationId == movingStationId } == true)
    }

    func testMoveLeafReturnsNilForUnknownStation() {
        let manager = StationManager()
        XCTAssertNil(manager.moveLeaf(stationId: "nope", toPath: "/dest"))
    }

    func testMoveLeafToItsOwnWorktreeIsANoOp() {
        let manager = StationManager()
        let tree = manager.tree(for: info("/repo"), backend: "zmx")
        XCTAssertNil(manager.moveLeaf(stationId: tree.allLeaves[0].stationId, toPath: "/repo"))
        XCTAssertNotNil(manager.tree(forPath: "/repo"))
    }

    // MARK: - AgentRegistry.rehome

    func testRehomeKeepsTheAgentsHistory() {
        defer { AgentRegistry.shared.unregister(terminalID: "t-move") }
        AgentRegistry.shared.registerForTesting(terminalID: "t-move", worktreePath: "/wt-a",
                                                branch: "main", project: "proj")
        AgentRegistry.shared.updateStatus(terminalID: "t-move", status: .running,
                                          lastMessage: "npm test", roundDuration: 12)

        XCTAssertTrue(AgentRegistry.shared.rehome(terminalID: "t-move", to: "/wt-b",
                                                  branch: "feature", project: "proj"))

        let moved = AgentRegistry.shared.pane(for: "t-move")
        XCTAssertEqual(moved?.worktreePath, "/wt-b")
        XCTAssertEqual(moved?.branch, "feature")
        // unregister+register would have reset all three — the agent is still
        // running, and losing its state is exactly what the move exists to avoid.
        XCTAssertEqual(moved?.status, .running)
        XCTAssertEqual(moved?.lastMessage, "npm test")
        XCTAssertEqual(moved?.roundDuration, 12)

        XCTAssertTrue(AgentRegistry.shared.terminalIDs(forWorktree: "/wt-a").isEmpty)
        XCTAssertEqual(AgentRegistry.shared.terminalIDs(forWorktree: "/wt-b"), ["t-move"])
    }

    func testRehomeToTheSameWorktreeIsRejected() {
        defer { AgentRegistry.shared.unregister(terminalID: "t-same") }
        AgentRegistry.shared.registerForTesting(terminalID: "t-same", worktreePath: "/wt-a",
                                                branch: "main", project: "proj")
        XCTAssertFalse(AgentRegistry.shared.rehome(terminalID: "t-same", to: "/wt-a",
                                                   branch: "main", project: "proj"))
    }

    func testRehomeOfUnknownPaneIsRejected() {
        XCTAssertFalse(AgentRegistry.shared.rehome(terminalID: "ghost", to: "/wt-b",
                                                   branch: "b", project: "p"))
    }

    /// `backendsByPath` is keyed by worktree, so unregistering one pane used to
    /// drop the backend for every sibling in the same worktree — closing one
    /// split silently un-backed the rest.
    func testClosingOnePaneKeepsTheWorktreeBackendForItsSiblings() {
        let first = Station()
        let second = Station()
        defer {
            AgentRegistry.shared.unregister(terminalID: first.id)
            AgentRegistry.shared.unregister(terminalID: second.id)
        }
        for station in [first, second] {
            AgentRegistry.shared.register(station: station, worktreePath: "/wt-multi", branch: "main",
                                          project: "proj", startedAt: nil,
                                          paneSessionKey: "seahelm-wt-multi", backend: "zmx")
        }
        AgentRegistry.shared.unregister(terminalID: first.id)
        XCTAssertEqual(AgentRegistry.shared.backendForTesting(worktreePath: "/wt-multi"), "zmx")

        AgentRegistry.shared.unregister(terminalID: second.id)
        XCTAssertNil(AgentRegistry.shared.backendForTesting(worktreePath: "/wt-multi"),
                     "the last pane leaving should still clear it")
    }
}
