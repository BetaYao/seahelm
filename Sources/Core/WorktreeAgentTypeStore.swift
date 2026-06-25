import Foundation

/// Persists the agent type chosen at worktree-creation time, keyed by worktree
/// path, so the card badge reflects the user's pick immediately — instead of
/// waiting for seahelm to detect the agent from terminal output. Stored as JSON
/// alongside config.json (`~/.config/seahelm/worktree-agents.json`).
final class WorktreeAgentTypeStore {
    static let shared = WorktreeAgentTypeStore()

    private let fileURL = Config.configDir.appendingPathComponent("worktree-agents.json")
    private let lock = NSLock()
    private var map: [String: String]   // worktreePath -> AgentType.rawValue

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
    }

    /// The agent type the user picked when creating this worktree, if recorded.
    func agentType(forWorktree path: String) -> AgentType? {
        lock.lock(); defer { lock.unlock() }
        return map[path].flatMap { AgentType(rawValue: $0) }
    }

    /// Record (and persist) the chosen agent type for a worktree path.
    func set(_ type: AgentType, forWorktree path: String) {
        lock.lock()
        map[path] = type.rawValue
        let snapshot = map
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ snapshot: [String: String]) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }
}
