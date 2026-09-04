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
    /// Checkout path → the commit seahelm last published there. Provenance,
    /// not display: `IntegrationWorktree.publish` compares it against the
    /// checkout's real HEAD to notice work that arrived by hand.
    private let published = PersistedStringMap(fileName: "integration-published.json")
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

    func set(_ worktreePath: String, forRepo repoPath: String) {
        store.set(
            WorktreeDiscovery.canonicalPath(worktreePath),
            forKey: WorktreeDiscovery.canonicalPath(repoPath)
        )
        refreshCache()
    }

    /// Every repo's checkout, keyed by repo path.
    var checkoutsByRepo: [String: String] { store.entries }

    /// Which repo a checkout belongs to. The reverse lookup, for the paths that
    /// arrive as a checkout — a card, a CLI call from inside one.
    func repoPath(forCheckout path: String) -> String? {
        let canonical = WorktreeDiscovery.canonicalPath(path)
        return store.entries.first { $0.value == canonical }?.key
    }

    /// The commit seahelm last checked out there, or nil if it never has.
    func lastPublishedCommit(forCheckout path: String) -> String? {
        published[WorktreeDiscovery.canonicalPath(path)]?.nonEmptyTrimmed
    }

    func recordPublished(_ commit: String, forCheckout path: String) {
        published.set(commit, forKey: WorktreeDiscovery.canonicalPath(path))
    }

    /// Drops everything remembered about a repo's checkout. Worktree paths get
    /// reused, so a stale entry would answer for whatever lands there next.
    func forget(repoPath: String) {
        let key = WorktreeDiscovery.canonicalPath(repoPath)
        if let checkout = store[key] {
            published.remove(forKey: checkout)
            IntegrationStatusStore.shared.forget(worktreePath: checkout)
        }
        store.remove(forKey: key)
        refreshCache()
    }

    private func refreshCache() {
        let values = store.values
        lock.lock(); knownPaths = values; lock.unlock()
    }

    /// Whether this path is some repo's integration worktree. Used to keep it
    /// out of the fleet groupings, so it is asked often and must not touch disk.
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
