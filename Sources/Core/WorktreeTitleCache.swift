import Foundation

/// Caches resolved worktree titles (Claude session summary → prompt → branch)
/// with a short TTL so the top capsule and mini cards share one source instead
/// of re-reading session JSONL from disk on every status poll.
final class WorktreeTitleCache {
    static let shared = WorktreeTitleCache()

    private struct Entry { let title: String; let at: Date }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval = 8

    /// Cached title if present, without any disk access. Nil if never resolved.
    func cachedTitle(worktreePath: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return entries[worktreePath]?.title
    }

    /// Resolves the title, serving a fresh cache entry without disk access or
    /// resolving off the main thread on a miss/stale. `completion` runs on main.
    func title(worktreePath: String, lastUserPrompt: String, branch: String,
               completion: @escaping (String) -> Void) {
        lock.lock()
        if let e = entries[worktreePath], Date().timeIntervalSince(e.at) < ttl {
            let cached = e.title
            lock.unlock()
            DispatchQueue.main.async { completion(cached) }
            return
        }
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let title = WorktreeTitleResolver.resolve(
                worktreePath: worktreePath, lastUserPrompt: lastUserPrompt, branch: branch
            )
            self.lock.lock(); self.entries[worktreePath] = Entry(title: title, at: Date()); self.lock.unlock()
            DispatchQueue.main.async { completion(title) }
        }
    }
}
