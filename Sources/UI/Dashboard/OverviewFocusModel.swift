import Foundation

/// Pure-value vertical focus ring for the overview (fleet) column, shared by the
/// full-bleed dashboard (mode 1) and the split left column (mode 2):
///
///     worktree rows  →  orders card row (the whole carousel is ONE row)  →  command input
///
/// The model owns which row is focused and, within the orders row, which card is
/// selected. It emits `Effect`s the host view/VC executes (focus the command
/// field, preview a worktree in the terminal panel, …). Counts are snapshots the
/// host refreshes via `rowsDidChange` whenever the fleet list or orders queue
/// rebuilds.
struct OverviewFocusModel: Equatable {

    enum Row: Equatable {
        case worktree(index: Int)
        case orders(cardIndex: Int)
        case command
    }

    enum Effect: Equatable {
        case none
        /// Landed on a worktree row — highlight it (and live-preview its terminal
        /// in split mode).
        case previewWorktree(Int)
        /// Landed on the orders row — highlight the selected card.
        case selectCard(Int)
        /// Landed on the command input — make it first responder.
        case focusCommand
        /// Left the command input upward — blur the field, then land on `Row`.
        case blurCommandThenLand(Row)
    }

    private(set) var row: Row = .worktree(index: 0)
    private(set) var worktreeCount: Int
    private(set) var orderCount: Int
    /// Remembered card selection so ↑↓ through the orders row returns to the
    /// same card.
    private var lastCardIndex = 0

    init(worktreeCount: Int, orderCount: Int) {
        self.worktreeCount = max(0, worktreeCount)
        self.orderCount = max(0, orderCount)
    }

    var selectedWorktreeIndex: Int? {
        if case .worktree(let i) = row { return i }
        return nil
    }

    var selectedCardIndex: Int? {
        if case .orders(let i) = row { return i }
        return nil
    }

    // MARK: - Vertical movement

    mutating func moveDown() -> Effect {
        switch row {
        case .worktree(let i):
            if i + 1 < worktreeCount {
                return land(.worktree(index: i + 1))
            }
            if orderCount > 0 {
                return land(.orders(cardIndex: clampedCardIndex(lastCardIndex)))
            }
            return land(.command)
        case .orders:
            return land(.command)
        case .command:
            return .none
        }
    }

    /// `commandIsEmpty` matters only when focus is in the command input: an empty
    /// field releases focus upward, a non-empty one keeps the keystroke.
    mutating func moveUp(commandIsEmpty: Bool = true) -> Effect {
        switch row {
        case .worktree(let i):
            guard i > 0 else { return .none }
            return land(.worktree(index: i - 1))
        case .orders:
            return landAboveOrders()
        case .command:
            guard commandIsEmpty else { return .none }
            let target: Row = orderCount > 0
                ? .orders(cardIndex: clampedCardIndex(lastCardIndex))
                : lastWorktreeRowOrSelf()
            row = target
            if case .orders(let c) = target { lastCardIndex = c }
            return .blurCommandThenLand(target)
        }
    }

    /// Jump straight to worktree row `index` (1-9 shortcuts, mouse hover sync).
    mutating func jumpToWorktree(_ index: Int) -> Effect {
        guard index >= 0, index < worktreeCount else { return .none }
        return land(.worktree(index: index))
    }

    /// Sync the model when the command field gains focus by mouse click.
    mutating func noteCommandFocused() {
        row = .command
    }

    /// Escape released focus from an empty command field — land on the FIRST
    /// worktree row (user-specified), falling back to orders/command when empty.
    mutating func escapeFromCommand() -> Effect {
        if worktreeCount > 0 { return land(.worktree(index: 0)) }
        if orderCount > 0 { return land(.orders(cardIndex: clampedCardIndex(lastCardIndex))) }
        return .none
    }

    // MARK: - Orders row (horizontal)

    mutating func moveLeftInOrders() -> Effect {
        guard case .orders(let i) = row, i > 0 else { return .none }
        return land(.orders(cardIndex: i - 1))
    }

    mutating func moveRightInOrders() -> Effect {
        guard case .orders(let i) = row, i + 1 < orderCount else { return .none }
        return land(.orders(cardIndex: i + 1))
    }

    // MARK: - Data changes

    /// Clamp the focus after the fleet list or orders queue rebuilds. Returns the
    /// effect to re-apply the (possibly moved) highlight.
    mutating func rowsDidChange(worktreeCount: Int, orderCount: Int) -> Effect {
        self.worktreeCount = max(0, worktreeCount)
        self.orderCount = max(0, orderCount)
        lastCardIndex = clampedCardIndex(lastCardIndex)
        switch row {
        case .worktree(let i):
            if self.worktreeCount == 0 {
                if self.orderCount > 0 { return land(.orders(cardIndex: lastCardIndex)) }
                row = .worktree(index: 0)
                return .none
            }
            return land(.worktree(index: min(i, self.worktreeCount - 1)))
        case .orders(let i):
            if self.orderCount == 0 { return land(lastWorktreeRowOrSelf()) }
            return land(.orders(cardIndex: min(i, self.orderCount - 1)))
        case .command:
            return .none
        }
    }

    // MARK: - Helpers

    private mutating func land(_ target: Row) -> Effect {
        row = target
        switch target {
        case .worktree(let i): return .previewWorktree(i)
        case .orders(let i):
            lastCardIndex = i
            return .selectCard(i)
        case .command: return .focusCommand
        }
    }

    private mutating func landAboveOrders() -> Effect {
        if worktreeCount > 0 { return land(.worktree(index: worktreeCount - 1)) }
        return .none
    }

    private func lastWorktreeRowOrSelf() -> Row {
        worktreeCount > 0 ? .worktree(index: worktreeCount - 1) : .worktree(index: 0)
    }

    private func clampedCardIndex(_ i: Int) -> Int {
        guard orderCount > 0 else { return 0 }
        return min(max(0, i), orderCount - 1)
    }
}
