import AppKit

/// Per-worktree "open file previews" model, decoupled from the display mode.
///
/// Selecting a file in the Files side panel adds it here; focus mode shows the
/// active file fullscreen (center overlay) while edit mode shows the whole set as
/// tabs. State is keyed by worktree path so it naturally follows the worktree as
/// the user switches tabs. Intentionally in-memory: a preview set is session
/// scratch, and persisting file paths would resurrect stale/deleted files on
/// relaunch. The edit-mode flag + split ratio live here too so the whole
/// edit-layout state has one owner.
final class PreviewSetController {
    private var filesByWorktree: [String: [String]] = [:]
    private var activeByWorktree: [String: String] = [:]
    private var editModeByWorktree: [String: Bool] = [:]
    private var ratioByWorktree: [String: CGFloat] = [:]

    // MARK: - Preview files

    func files(for worktree: String) -> [String] {
        filesByWorktree[worktree] ?? []
    }

    func activeFile(for worktree: String) -> String? {
        activeByWorktree[worktree]
    }

    func isEmpty(_ worktree: String) -> Bool {
        files(for: worktree).isEmpty
    }

    /// Append the file if new (preserving tab order) and make it active.
    func add(_ path: String, to worktree: String) {
        var list = filesByWorktree[worktree] ?? []
        if !list.contains(path) {
            list.append(path)
            filesByWorktree[worktree] = list
        }
        activeByWorktree[worktree] = path
    }

    func setActive(_ path: String, for worktree: String) {
        guard files(for: worktree).contains(path) else { return }
        activeByWorktree[worktree] = path
    }

    /// Remove a file; re-pick the adjacent tab as active. Returns the new active
    /// file (nil once the set is empty).
    @discardableResult
    func remove(_ path: String, from worktree: String) -> String? {
        var list = filesByWorktree[worktree] ?? []
        guard let idx = list.firstIndex(of: path) else {
            return activeByWorktree[worktree]
        }
        list.remove(at: idx)
        filesByWorktree[worktree] = list

        if activeByWorktree[worktree] == path {
            if list.isEmpty {
                activeByWorktree[worktree] = nil
            } else {
                // Prefer the tab that slid into this slot, else the previous one.
                activeByWorktree[worktree] = list[min(idx, list.count - 1)]
            }
        }
        return activeByWorktree[worktree]
    }

    // MARK: - Edit mode

    /// Edit mode is only *effective* when there is something to preview.
    func isEditMode(for worktree: String) -> Bool {
        (editModeByWorktree[worktree] ?? false) && !isEmpty(worktree)
    }

    func setEditMode(_ enabled: Bool, for worktree: String) {
        editModeByWorktree[worktree] = enabled
    }

    func splitRatio(for worktree: String) -> CGFloat {
        ratioByWorktree[worktree] ?? 0.5
    }

    func setSplitRatio(_ ratio: CGFloat, for worktree: String) {
        ratioByWorktree[worktree] = min(max(ratio, 0.15), 0.85)
    }

    // MARK: - Cleanup

    /// Drop state for worktrees that no longer exist (called when a worktree is
    /// deleted) so the dictionaries don't leak.
    func forget(worktree: String) {
        filesByWorktree.removeValue(forKey: worktree)
        activeByWorktree.removeValue(forKey: worktree)
        editModeByWorktree.removeValue(forKey: worktree)
        ratioByWorktree.removeValue(forKey: worktree)
    }
}
