// tests/PaneTransferTests.swift
import XCTest
@testable import seahelm

final class PaneTransferTests: XCTestCase {

    // MARK: - PendingTransferTracker






    // MARK: - StationManager.moveLeaf

    private func info(_ path: String) -> WorktreeInfo {
        WorktreeInfo(path: path, branch: "main", commitHash: "abc", isMainWorktree: true)
    }

    func testMoveLeafFromSinglePaneWorktreeEmptiesTheSource() {
        let manager = StationManager()
        let tree = manager.tree(for: info("/repo"), backend: "seahelmd")
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
        // seahelmd cannot rename a session, so the live pane stays addressable only by
        // the name it was created with.
        let manager = StationManager()
        let tree = manager.tree(for: info("/repo"), backend: "seahelmd")
        let original = tree.allLeaves[0].paneSessionKey
        let stationId = tree.allLeaves[0].stationId

        let move = manager.moveLeaf(stationId: stationId, toPath: "/repo-worktrees/feature")
        XCTAssertEqual(move?.tree.allLeaves.first?.paneSessionKey, original)
        XCTAssertFalse(original.isEmpty)
    }

    func testDestinationTreeNamesLaterPanesAfterItsOwnWorktree() {
        // The adopted leaf keeps its old name; panes split off afterwards must not.
        let manager = StationManager()
        let tree = manager.tree(for: info("/repo"), backend: "seahelmd")
        let stationId = tree.allLeaves[0].stationId

        let move = manager.moveLeaf(stationId: stationId, toPath: "/repo-worktrees/feature")
        let expectedBase = SessionManager.persistentSessionName(for: "/repo-worktrees/feature")
        XCTAssertTrue(move?.tree.nextSessionName().hasPrefix(expectedBase) == true,
                      "new panes in the destination should be named after it, got \(move?.tree.nextSessionName() ?? "nil")")
    }

    func testMoveLeafTakesOnlyTheNamedPane() {
        let manager = StationManager()
        let tree = manager.tree(for: info("/repo"), backend: "seahelmd")
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
        let source = manager.tree(for: info("/repo"), backend: "seahelmd")
        let destination = manager.tree(for: info("/repo-worktrees/feature"), backend: "seahelmd")
        let residentStationId = destination.allLeaves[0].stationId
        let movingStationId = source.allLeaves[0].stationId

        let move = manager.moveLeaf(stationId: movingStationId, toPath: "/repo-worktrees/feature")
        XCTAssertEqual(move?.tree.leafCount, 2, "replacing the tree would orphan the resident pane")
        XCTAssertTrue(move?.tree.allLeaves.contains { $0.stationId == residentStationId } == true)
        XCTAssertTrue(move?.tree.allLeaves.contains { $0.stationId == movingStationId } == true)
    }

    /// The pane that leaves keeps the worktree's canonical seahelmd session name —
    /// seahelmd has no rename — so a replacement pane must claim a different one or
    /// both panes drive the same live session.
    func testReplacementPaneDoesNotReuseTheDepartedPanesSessionName() {
        let manager = StationManager()
        let source = info("/repo")
        let tree = manager.tree(for: source, backend: "seahelmd")
        let departedName = tree.allLeaves[0].paneSessionKey
        XCTAssertEqual(departedName, SessionManager.persistentSessionName(for: "/repo"))

        let move = manager.moveLeaf(stationId: tree.allLeaves[0].stationId,
                                    toPath: "/repo-worktrees/feature")
        XCTAssertEqual(move?.sourceEmptied, true)

        let replacement = manager.replacementTree(for: source, backend: "seahelmd")
        XCTAssertNotEqual(replacement.allLeaves[0].paneSessionKey, departedName)
        XCTAssertFalse(replacement.allLeaves[0].paneSessionKey.isEmpty)
    }

    func testReplacementPaneTakesTheCanonicalNameWhenItIsFree() {
        let manager = StationManager()
        let source = info("/repo")
        let replacement = manager.replacementTree(for: source, backend: "seahelmd")
        XCTAssertEqual(replacement.allLeaves[0].paneSessionKey,
                       SessionManager.persistentSessionName(for: "/repo"))
    }

    /// A stale `focusedId` must not cost the destination its panes. `removeLeaf`
    /// reassigns focus, and a tree can be adopted into long after its focus moved,
    /// so adopting has to attach to *some* leaf rather than trusting focus — the
    /// earlier form replaced `root` outright and orphaned every Station in it.
    func testAdoptIntoTreeWithStaleFocusKeepsExistingPanes() {
        let manager = StationManager()
        let destination = manager.tree(for: info("/repo-worktrees/feature"), backend: "seahelmd")
        let residentStationId = destination.allLeaves[0].stationId
        destination.focusedId = "no-such-leaf"

        let source = manager.tree(for: info("/repo"), backend: "seahelmd")
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
        let tree = manager.tree(for: info("/repo"), backend: "seahelmd")
        XCTAssertNil(manager.moveLeaf(stationId: tree.allLeaves[0].stationId, toPath: "/repo"))
        XCTAssertNotNil(manager.tree(forPath: "/repo"))
    }

    // MARK: - Fleet.rehome

    func testRehomeKeepsTheAgentsHistory() {
        defer { Fleet.shared.unregister(terminalID: "t-move") }
        Fleet.shared.registerForTesting(terminalID: "t-move", worktreePath: "/wt-a",
                                                branch: "main", project: "proj")
        Fleet.shared.applyForTesting(terminalID: "t-move",
                                     info: ["status": "Running", "last_message": "npm test", "round_duration": 12.0])

        XCTAssertTrue(Fleet.shared.rehome(terminalID: "t-move", to: "/wt-b",
                                                  branch: "feature", project: "proj"))

        let moved = Fleet.shared.pane(for: "t-move")
        XCTAssertEqual(moved?.worktreePath, "/wt-b")
        XCTAssertEqual(moved?.branch, "feature")
        // unregister+register would have reset all three — the agent is still
        // running, and losing its state is exactly what the move exists to avoid.
        XCTAssertEqual(moved?.status, .running)
        XCTAssertEqual(moved?.lastMessage, "npm test")
        XCTAssertEqual(moved?.roundDuration, 12)

        XCTAssertTrue(Fleet.shared.terminalIDs(forWorktree: "/wt-a").isEmpty)
        XCTAssertEqual(Fleet.shared.terminalIDs(forWorktree: "/wt-b"), ["t-move"])
    }

    func testRehomeToTheSameWorktreeIsRejected() {
        defer { Fleet.shared.unregister(terminalID: "t-same") }
        Fleet.shared.registerForTesting(terminalID: "t-same", worktreePath: "/wt-a",
                                                branch: "main", project: "proj")
        XCTAssertFalse(Fleet.shared.rehome(terminalID: "t-same", to: "/wt-a",
                                                   branch: "main", project: "proj"))
    }

    func testRehomeOfUnknownPaneIsRejected() {
        XCTAssertFalse(Fleet.shared.rehome(terminalID: "ghost", to: "/wt-b",
                                                   branch: "b", project: "p"))
    }

    /// `backendsByPath` is keyed by worktree, so unregistering one pane used to
    /// drop the backend for every sibling in the same worktree — closing one
    /// split silently un-backed the rest.
    func testClosingOnePaneKeepsTheWorktreeBackendForItsSiblings() {
        let first = Station()
        let second = Station()
        defer {
            Fleet.shared.unregister(terminalID: first.id)
            Fleet.shared.unregister(terminalID: second.id)
        }
        for station in [first, second] {
            Fleet.shared.register(station: station, worktreePath: "/wt-multi", branch: "main",
                                          project: "proj", startedAt: nil,
                                          paneSessionKey: "seahelm-wt-multi", backend: "seahelmd")
        }
        Fleet.shared.unregister(terminalID: first.id)
        XCTAssertEqual(Fleet.shared.backend(forWorktree: "/wt-multi"), "seahelmd")

        Fleet.shared.unregister(terminalID: second.id)
        XCTAssertNil(Fleet.shared.backend(forWorktree: "/wt-multi"),
                     "the last pane leaving should still clear it")
    }
}
