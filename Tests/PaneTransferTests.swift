// tests/PaneTransferTests.swift
import XCTest
@testable import seahelm

final class PaneTransferTests: XCTestCase {

    // MARK: - PendingWorktreeTransfer Tests

    func testRecordAndMatch() {
        let tracker = PendingTransferTracker()
        tracker.record(sourceWorktreePath: "/repo", worktreeName: "feature-x", sessionId: "s1")

        let result = tracker.consume(newWorktreePath: "/repo/.worktrees/feature-x")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sourceWorktreePath, "/repo")
        XCTAssertEqual(result?.worktreeName, "feature-x")
        XCTAssertEqual(result?.sessionId, "s1")
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
    }

    func testTransferTreeReturnsNilForUnknownPath() {
        let manager = StationManager()
        let result = manager.transferTree(fromPath: "/nonexistent", toPath: "/dest")
        XCTAssertNil(result)
    }
}
