import Foundation

/// Persists the agent type chosen at worktree-creation time, keyed by worktree
/// path, so the card badge reflects the user's pick immediately — instead of
/// waiting for seahelm to detect the agent from terminal output. Stored as JSON
/// alongside config.json (`~/.config/seahelm/worktree-agents.json`).
final class WorktreeSailorTypeStore {
    static let shared = WorktreeSailorTypeStore()

    private let store = PersistedStringMap(fileName: "worktree-agents.json")

    private init() {}

    /// The agent type the user picked when creating this worktree, if recorded.
    func agentType(forWorktree path: String) -> SailorType? {
        store[path].flatMap { SailorType(rawValue: $0) }
    }

    /// Record (and persist) the chosen agent type for a worktree path.
    func set(_ type: SailorType, forWorktree path: String) {
        store.set(type.rawValue, forKey: path)
    }
}
