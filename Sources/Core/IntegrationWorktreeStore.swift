import Foundation

/// Remembers which worktree is a repo's integration checkout, keyed by repo
/// path. One per repo.
///
/// Identity is recorded rather than inferred from the path: the directory name
/// is a convention, and a convention is not something the rest of the app
/// should have to re-derive every time it needs to know whether a worktree is
/// a fleet member or the place they get combined.
final class IntegrationWorktreeStore {
    static let shared = IntegrationWorktreeStore()

    private let store = PersistedStringMap(fileName: "integration-worktrees.json")

    private init() {}

    func worktreePath(forRepo repoPath: String) -> String? {
        store[WorktreeDiscovery.canonicalPath(repoPath)]?.nonEmptyTrimmed
    }

    func set(_ worktreePath: String, forRepo repoPath: String) {
        store.set(
            WorktreeDiscovery.canonicalPath(worktreePath),
            forKey: WorktreeDiscovery.canonicalPath(repoPath)
        )
    }

    func forget(repoPath: String) {
        store.remove(forKey: WorktreeDiscovery.canonicalPath(repoPath))
    }

    /// Whether this path is some repo's integration worktree. Used to keep it
    /// out of the fleet groupings, so it is asked often and must not touch disk.
    func isIntegrationWorktree(_ path: String) -> Bool {
        let canonical = WorktreeDiscovery.canonicalPath(path)
        return store.values.contains(canonical)
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
