import Foundation

/// Persists the task description entered at worktree-creation time, keyed by
/// worktree path, so the card/capsule title can show the user's task
/// immediately (before the agent has written its own session summary). Stored
/// as JSON alongside config.json (`~/.config/seahelm/worktree-tasks.json`).
final class WorktreeTaskStore {
    static let shared = WorktreeTaskStore()

    private let store = PersistedStringMap(fileName: "worktree-tasks.json")

    private init() {}

    /// The task description recorded for this worktree path, if any.
    func task(forWorktree path: String) -> String? {
        store[path]
    }

    /// Record (and persist) the task description for a worktree path.
    func set(_ task: String, forWorktree path: String) {
        store.set(task, forKey: path)
    }
}
