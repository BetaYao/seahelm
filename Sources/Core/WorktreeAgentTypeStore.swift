import Foundation

/// Persists the agent type chosen at worktree-creation time, keyed by worktree
/// path, so the card badge reflects the user's pick immediately — instead of
/// waiting for seahelm to detect the agent from terminal output. Stored as JSON
/// alongside config.json (`~/.config/seahelm/worktree-agents.json`).
final class WorktreeAgentTypeStore {
    static let shared = WorktreeAgentTypeStore()

    private let store = PersistedStringMap(fileName: "worktree-agents.json")

    private init() {}

    /// The agent type the user picked when creating this worktree, if recorded.
    func agentType(forWorktree path: String) -> AgentType? {
        store[path].flatMap { AgentType(rawValue: $0) }
    }

    /// Record (and persist) the chosen agent type for a worktree path.
    func set(_ type: AgentType, forWorktree path: String) {
        store.set(type.rawValue, forKey: path)
    }

    // MARK: - Last chosen

    /// Worktree keys are absolute paths, so this one can never collide.
    private static let lastChosenKey = "@last-chosen"

    /// The agent the user last picked for a new worktree, on whichever surface
    /// (the desktop form or the web client) — the next form starts on it.
    var lastChosen: AgentType? {
        store[Self.lastChosenKey].flatMap { AgentType(rawValue: $0) }
    }

    func recordChoice(_ type: AgentType) {
        store.set(type.rawValue, forKey: Self.lastChosenKey)
    }

    /// The choices with the last one picked moved to the front, the rest in
    /// their given order.
    static func lastChosenFirst(_ choices: [AgentType], lastChosen: AgentType?) -> [AgentType] {
        guard let last = lastChosen, choices.contains(last) else { return choices }
        return [last] + choices.filter { $0 != last }
    }
}
