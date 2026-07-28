import XCTest
@testable import seahelm

final class OverviewFocusModelTests: XCTestCase {

    // MARK: - Vertical ring (the cabin list, and nothing below it)

    func testMoveDownWalksWorktreesAndStopsAtTheLast() {
        var m = OverviewFocusModel(worktreeCount: 2)
        XCTAssertEqual(m.row, .worktree(index: 0))
        XCTAssertEqual(m.moveDown(), .previewWorktree(1))
        // Bottom of the list: the ring used to continue into the orders carousel
        // and the composer, both of which moved to the island.
        XCTAssertEqual(m.moveDown(), .none)
        XCTAssertEqual(m.row, .worktree(index: 1))
    }

    func testMoveUpWalksBack() {
        var m = OverviewFocusModel(worktreeCount: 3)
        _ = m.jumpToWorktree(2)
        XCTAssertEqual(m.moveUp(), .previewWorktree(1))
        XCTAssertEqual(m.moveUp(), .previewWorktree(0))
    }

    func testMoveUpAtFirstWorktreeIsNoop() {
        var m = OverviewFocusModel(worktreeCount: 2)
        XCTAssertEqual(m.moveUp(), .none)
        XCTAssertEqual(m.row, .worktree(index: 0))
    }

    func testMovementOnEmptyListIsNoop() {
        var m = OverviewFocusModel(worktreeCount: 0)
        XCTAssertEqual(m.moveDown(), .none)
        XCTAssertEqual(m.moveUp(), .none)
    }

    // MARK: - rowsDidChange clamping

    func testRowsDidChangeClampsWorktreeIndex() {
        var m = OverviewFocusModel(worktreeCount: 5)
        _ = m.jumpToWorktree(4)
        XCTAssertEqual(m.rowsDidChange(worktreeCount: 2), .previewWorktree(1))
    }

    func testRowsDidChangeOnEmptyListResetsToZero() {
        var m = OverviewFocusModel(worktreeCount: 3)
        _ = m.jumpToWorktree(2)
        XCTAssertEqual(m.rowsDidChange(worktreeCount: 0), .none)
        XCTAssertEqual(m.row, .worktree(index: 0))
    }

    // MARK: - rowsDidChange follows identity across a re-sort

    /// The fleet list re-sorts by status, so the selected row moves. Without an
    /// anchor the index clamp keeps the old slot — which now holds a *different*
    /// worktree — and the highlight silently drifts off the user's selection.
    func testRowsDidChangeFollowsAnchorWhenListReorders() {
        var m = OverviewFocusModel(worktreeCount: 4)
        _ = m.jumpToWorktree(1)
        // Same count, but the selected row is now at index 3 after the re-sort.
        XCTAssertEqual(m.rowsDidChange(worktreeCount: 4, worktreeAnchor: 3),
                       .previewWorktree(3))
        XCTAssertEqual(m.row, .worktree(index: 3))
    }

    func testRowsDidChangeWithoutAnchorStillClamps() {
        var m = OverviewFocusModel(worktreeCount: 5)
        _ = m.jumpToWorktree(4)
        // Anchor nil = selected row is gone; fall back to the plain clamp.
        XCTAssertEqual(m.rowsDidChange(worktreeCount: 2, worktreeAnchor: nil),
                       .previewWorktree(1))
    }

    func testRowsDidChangeClampsOutOfRangeAnchor() {
        var m = OverviewFocusModel(worktreeCount: 5)
        _ = m.jumpToWorktree(4)
        XCTAssertEqual(m.rowsDidChange(worktreeCount: 3, worktreeAnchor: 9),
                       .previewWorktree(2))
    }

    func testJumpToWorktreeBounds() {
        var m = OverviewFocusModel(worktreeCount: 2)
        XCTAssertEqual(m.jumpToWorktree(5), .none)
        XCTAssertEqual(m.jumpToWorktree(1), .previewWorktree(1))
    }
}
