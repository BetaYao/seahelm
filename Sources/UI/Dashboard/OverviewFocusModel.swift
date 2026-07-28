import Foundation

/// Pure-value vertical focus ring for the overview (fleet) column, shared by the
/// full-bleed dashboard (mode 1) and the split left column (mode 2).
///
/// The ring is just the worktree rows. It used to continue into an orders-card
/// row and a command input at the bottom of the column; both moved to the island,
/// so ↑↓ now stays inside the fleet list and the bottom of the column is a static
/// shortcut strip with nothing to focus.
///
/// The model owns which row is focused and emits `Effect`s the host view/VC
/// executes (highlight the row, live-preview its terminal, …). Counts are
/// snapshots the host refreshes via `rowsDidChange` whenever the fleet list
/// rebuilds.
struct OverviewFocusModel: Equatable {

    enum Row: Equatable {
        case worktree(index: Int)
    }

    enum Effect: Equatable {
        case none
        /// Landed on a worktree row — highlight it (and live-preview its terminal
        /// in split mode).
        case previewWorktree(Int)
    }

    private(set) var row: Row = .worktree(index: 0)
    private(set) var worktreeCount: Int

    init(worktreeCount: Int) {
        self.worktreeCount = max(0, worktreeCount)
    }

    var selectedWorktreeIndex: Int? {
        if case .worktree(let i) = row { return i }
        return nil
    }

    // MARK: - Vertical movement

    mutating func moveDown() -> Effect {
        guard case .worktree(let i) = row, i + 1 < worktreeCount else { return .none }
        return land(.worktree(index: i + 1))
    }

    mutating func moveUp() -> Effect {
        guard case .worktree(let i) = row, i > 0 else { return .none }
        return land(.worktree(index: i - 1))
    }

    /// Jump straight to worktree row `index` (1-9 shortcuts, mouse hover sync).
    mutating func jumpToWorktree(_ index: Int) -> Effect {
        guard index >= 0, index < worktreeCount else { return .none }
        return land(.worktree(index: index))
    }

    // MARK: - Data changes

    /// Clamp the focus after the fleet list rebuilds. Returns the effect to
    /// re-apply the (possibly moved) highlight.
    ///
    /// `worktreeAnchor` is where the row the host still considers selected now
    /// lives. The fleet list is re-sorted by status, so a row index is NOT a
    /// stable identity across rebuilds: a single status flip elsewhere reshuffles
    /// the list and the old index silently lands on a different worktree. Pass the
    /// anchor to follow the selection by identity; nil keeps the plain clamp (the
    /// selected row is gone, or the host tracks no identity).
    mutating func rowsDidChange(worktreeCount: Int, worktreeAnchor: Int? = nil) -> Effect {
        self.worktreeCount = max(0, worktreeCount)
        guard case .worktree(let i) = row else { return .none }
        if self.worktreeCount == 0 {
            row = .worktree(index: 0)
            return .none
        }
        let target = worktreeAnchor ?? i
        return land(.worktree(index: min(max(0, target), self.worktreeCount - 1)))
    }

    // MARK: - Helpers

    private mutating func land(_ target: Row) -> Effect {
        row = target
        guard case .worktree(let i) = target else { return .none }
        return .previewWorktree(i)
    }
}
