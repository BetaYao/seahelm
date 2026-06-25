import Foundation

/// Persists the task description entered at worktree-creation time, keyed by
/// worktree path, so the card/capsule title can show the user's task
/// immediately (before the agent has written its own session summary). Stored
/// as JSON alongside config.json (`~/.config/seahelm/worktree-tasks.json`).
final class WorktreeTaskStore {
    static let shared = WorktreeTaskStore()

    private let fileURL = Config.configDir.appendingPathComponent("worktree-tasks.json")
    private let lock = NSLock()
    private var map: [String: String]   // worktreePath -> task description

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
    }

    /// The task description recorded for this worktree path, if any.
    func task(forWorktree path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[path]
    }

    /// Record (and persist) the task description for a worktree path.
    func set(_ task: String, forWorktree path: String) {
        lock.lock()
        map[path] = task
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
