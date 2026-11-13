import Foundation

/// Remembers which worktree is a repo's integration checkout, keyed by repo
/// path. One per repo.
///
/// The integration feature no longer runs, but existing checkouts stay on disk
/// and stay recorded here so the fleet / First Mate can still recognize them
/// (not PR work, not cleanup candidates) without recreating or updating them.
final class IntegrationWorktreeStore {
    static let shared = IntegrationWorktreeStore()

    private let store = PersistedStringMap(fileName: "integration-worktrees.json")
    /// Membership cache. `isIntegrationWorktree` is asked once per pane per
    /// render, on a two-second poll, so it must not rebuild a set each time.
    private var knownPaths: Set<String>
    private let lock = NSLock()

    private init() {
        knownPaths = store.values
    }

    func worktreePath(forRepo repoPath: String) -> String? {
        store[WorktreeDiscovery.canonicalPath(repoPath)]?.nonEmptyTrimmed
    }

    /// Every repo's checkout, keyed by repo path.
    var checkoutsByRepo: [String: String] { store.entries }

    /// Which repo a checkout belongs to. The reverse lookup, for the paths that
    /// arrive as a checkout.
    func repoPath(forCheckout path: String) -> String? {
        let canonical = WorktreeDiscovery.canonicalPath(path)
        return store.entries.first { $0.value == canonical }?.key
    }

    /// Drops everything remembered about a repo's checkout. Worktree paths get
    /// reused, so a stale entry would answer for whatever lands there next.
    func forget(repoPath: String) {
        let key = WorktreeDiscovery.canonicalPath(repoPath)
        store.remove(forKey: key)
        refreshCache()
    }

    private func refreshCache() {
        let values = store.values
        lock.lock(); knownPaths = values; lock.unlock()
    }

    /// Whether this path is some repo's integration worktree. Used to keep it
    /// out of PR / cleanup treatment, so it is asked often and must not touch disk.
    func isIntegrationWorktree(_ path: String) -> Bool {
        lock.lock(); let known = knownPaths; lock.unlock()
        guard !known.isEmpty else { return false }
        return known.contains(WorktreeDiscovery.canonicalPath(path))
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
