import Foundation

/// Remembers which worktree is a repo's integration checkout, keyed by repo
/// path. One per repo.
///
/// The integration feature no longer runs, but existing checkouts stay on disk
/// and stay recorded here so the fleet / First Mate can still recognize them
/// (not PR work, not cleanup candidates) without recreating or updating them.
/// Nothing adds an entry any more; one leaves when its checkout is deleted, or
/// all of them at launch if the user had the feature switched off.
final class IntegrationWorktreeStore {
    static let shared = IntegrationWorktreeStore()

    private let store = PersistedStringMap(fileName: "integration-worktrees.json")
    /// Membership cache. `isIntegrationWorktree` is asked once per pane per
    /// render, on a two-second poll, so it must not rebuild a set each time.
    private var knownPaths: Set<String>
    private let lock = NSLock()

    private init() {
        Self.retireObsoleteState(configDir: Config.configDir)
        if Self.featureWasTurnedOff(configData: try? Data(contentsOf: Config.configPath)) {
            for repo in store.entries.keys { store.remove(forKey: repo) }
        }
        knownPaths = store.values
    }

    /// Files only the removed integration feature read: the commit last
    /// published into each checkout, and each checkout's round status. Nothing
    /// reads them now, and worktree paths get reused, so they go.
    static let obsoleteFileNames = ["integration-published.json", "integration-status.json"]

    static func retireObsoleteState(configDir: URL) {
        for name in obsoleteFileNames {
            let url = configDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Whether the user had switched the feature off (`integration_enabled:
    /// false`, which `Config.save` keeps as a foreign key). With it off the
    /// checkout was an ordinary worktree — every grouping, `/return` allowed —
    /// and there is no setting left to say so, so its record is dropped instead.
    static func featureWasTurnedOff(configData: Data?) -> Bool {
        guard let configData,
              let object = try? JSONSerialization.jsonObject(with: configData) as? [String: Any]
        else { return false }
        return object["integration_enabled"] as? Bool == false
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
