import XCTest
@testable import seahelm

final class OverviewFocusModelTests: XCTestCase {

    // MARK: - Vertical ring: worktrees → orders → command

    func testMoveDownThroughWorktreesOrdersCommand() {
        var m = OverviewFocusModel(worktreeCount: 2, orderCount: 2)
        XCTAssertEqual(m.row, .worktree(index: 0))
        XCTAssertEqual(m.moveDown(), .previewWorktree(1))
        XCTAssertEqual(m.moveDown(), .selectCard(0))
        XCTAssertEqual(m.row, .orders(cardIndex: 0))
        XCTAssertEqual(m.moveDown(), .focusCommand)
        XCTAssertEqual(m.row, .command)
        // Bottom of the ring: down in command is a no-op for the model.
        XCTAssertEqual(m.moveDown(), .none)
    }

    func testMoveDownSkipsOrdersRowWhenNoCards() {
        var m = OverviewFocusModel(worktreeCount: 1, orderCount: 0)
        XCTAssertEqual(m.moveDown(), .focusCommand)
        XCTAssertEqual(m.row, .command)
    }

    func testMoveUpFromOrdersLandsOnLastWorktree() {
        var m = OverviewFocusModel(worktreeCount: 3, orderCount: 1)
        _ = m.jumpToWorktree(2)
        XCTAssertEqual(m.moveDown(), .selectCard(0))
        XCTAssertEqual(m.moveUp(), .previewWorktree(2))
    }

    func testMoveUpAtFirstWorktreeIsNoop() {
        var m = OverviewFocusModel(worktreeCount: 2, orderCount: 0)
        XCTAssertEqual(m.moveUp(), .none)
        XCTAssertEqual(m.row, .worktree(index: 0))
    }

    // MARK: - Command input hand-off

    func testEmptyCommandArrowUpBlursAndLandsOnOrdersRow() {
        var m = OverviewFocusModel(worktreeCount: 2, orderCount: 2)
        _ = m.jumpToWorktree(1)
        _ = m.moveDown()          // orders
        _ = m.moveRightInOrders() // remember card 1
        _ = m.moveDown()          // command
        XCTAssertEqual(m.moveUp(commandIsEmpty: true),
                       .blurCommandThenLand(.orders(cardIndex: 1)))
        XCTAssertEqual(m.row, .orders(cardIndex: 1))
    }

    func testEmptyCommandArrowUpLandsOnLastWorktreeWhenNoCards() {
        var m = OverviewFocusModel(worktreeCount: 3, orderCount: 0)
        _ = m.moveDown(); _ = m.moveDown(); _ = m.moveDown() // → command
        XCTAssertEqual(m.row, .command)
        XCTAssertEqual(m.moveUp(commandIsEmpty: true),
                       .blurCommandThenLand(.worktree(index: 2)))
    }

    func testNonEmptyCommandArrowUpStaysPut() {
        var m = OverviewFocusModel(worktreeCount: 1, orderCount: 0)
        _ = m.moveDown()
        XCTAssertEqual(m.moveUp(commandIsEmpty: false), .none)
        XCTAssertEqual(m.row, .command)
    }

    func testEscapeFromCommandLandsOnFirstWorktree() {
        var m = OverviewFocusModel(worktreeCount: 3, orderCount: 2)
        _ = m.moveDown(); _ = m.moveDown(); _ = m.moveDown(); _ = m.moveDown()
        XCTAssertEqual(m.row, .command)
        XCTAssertEqual(m.escapeFromCommand(), .previewWorktree(0))
        XCTAssertEqual(m.row, .worktree(index: 0))
    }

    func testNoteCommandFocusedSyncsMouseClick() {
        var m = OverviewFocusModel(worktreeCount: 2, orderCount: 0)
        m.noteCommandFocused()
        XCTAssertEqual(m.row, .command)
    }

    // MARK: - Orders row horizontal movement

    func testOrdersLeftRightClampsWithoutWrapping() {
        var m = OverviewFocusModel(worktreeCount: 1, orderCount: 3)
        _ = m.moveDown() // orders
        XCTAssertEqual(m.moveLeftInOrders(), .none)
        XCTAssertEqual(m.moveRightInOrders(), .selectCard(1))
        XCTAssertEqual(m.moveRightInOrders(), .selectCard(2))
        XCTAssertEqual(m.moveRightInOrders(), .none)
        XCTAssertEqual(m.moveLeftInOrders(), .selectCard(1))
    }

    func testHorizontalMovementOutsideOrdersRowIsNoop() {
        var m = OverviewFocusModel(worktreeCount: 2, orderCount: 2)
        XCTAssertEqual(m.moveLeftInOrders(), .none)
        XCTAssertEqual(m.moveRightInOrders(), .none)
        XCTAssertEqual(m.row, .worktree(index: 0))
    }

    func testCardSelectionRememberedAcrossRowTrips() {
        var m = OverviewFocusModel(worktreeCount: 1, orderCount: 3)
        _ = m.moveDown()            // orders(0)
        _ = m.moveRightInOrders()   // orders(1)
        _ = m.moveUp()              // worktree
        XCTAssertEqual(m.moveDown(), .selectCard(1))
    }

    // MARK: - rowsDidChange clamping

    func testRowsDidChangeClampsWorktreeIndex() {
        var m = OverviewFocusModel(worktreeCount: 5, orderCount: 0)
        _ = m.jumpToWorktree(4)
        XCTAssertEqual(m.rowsDidChange(worktreeCount: 2, orderCount: 0), .previewWorktree(1))
    }

    func testRowsDidChangeMovesOffEmptyOrdersRow() {
        var m = OverviewFocusModel(worktreeCount: 2, orderCount: 1)
        _ = m.jumpToWorktree(1)
        _ = m.moveDown() // orders
        XCTAssertEqual(m.rowsDidChange(worktreeCount: 2, orderCount: 0), .previewWorktree(1))
    }

    func testRowsDidChangeKeepsCommandFocus() {
        var m = OverviewFocusModel(worktreeCount: 1, orderCount: 1)
        _ = m.moveDown(); _ = m.moveDown()
        XCTAssertEqual(m.row, .command)
        XCTAssertEqual(m.rowsDidChange(worktreeCount: 3, orderCount: 0), .none)
        XCTAssertEqual(m.row, .command)
    }

    func testJumpToWorktreeBounds() {
        var m = OverviewFocusModel(worktreeCount: 2, orderCount: 0)
        XCTAssertEqual(m.jumpToWorktree(5), .none)
        XCTAssertEqual(m.jumpToWorktree(1), .previewWorktree(1))
    }
}
