import Foundation

/// Pure adjacency helpers for cycling worktree paths (keyboard Ctrl+Tab).
enum WorktreePathNavigation {
    /// The path forward/backward from `current` in `paths`, wrapping around.
    /// Returns nil only when `paths` is empty. When `current` is nil or not in
    /// the list, forward starts at the first path and backward at the last.
    static func adjacentPath(paths: [String], from current: String?, forward: Bool) -> String? {
        guard !paths.isEmpty else { return nil }
        guard let current, let idx = paths.firstIndex(of: current) else {
            return forward ? paths.first : paths.last
        }
        let n = paths.count
        let nextIdx = ((idx + (forward ? 1 : -1)) % n + n) % n
        return paths[nextIdx]
    }
}
