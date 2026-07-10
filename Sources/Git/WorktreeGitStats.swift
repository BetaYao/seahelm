import Foundation

/// Lightweight per-worktree git summary for the dashboard cards: working-tree
/// diff size (added/removed lines vs HEAD) plus ahead/behind vs the branch's
/// upstream. Deliberately cheap — no hunk parsing, just `--numstat` and a
/// `rev-list` count — so it can be polled behind a short-TTL cache.
struct WorktreeGitStats: Equatable {
    var added: Int = 0
    var removed: Int = 0
    /// Commits on HEAD not on upstream. `nil` when there is no upstream.
    var ahead: Int?
    /// Commits on upstream not on HEAD. `nil` when there is no upstream.
    var behind: Int?

    var hasDiff: Bool { added > 0 || removed > 0 }
    var hasAheadBehind: Bool { (ahead ?? 0) > 0 || (behind ?? 0) > 0 }
    var isEmpty: Bool { !hasDiff && !hasAheadBehind }
}

enum WorktreeGitStatsProvider {
    private static let gitTimeout: TimeInterval = 5

    static func stats(worktreePath: String) -> WorktreeGitStats {
        var result = WorktreeGitStats()

        // Added/removed lines vs HEAD (staged + unstaged tracked changes).
        if let numstat = runGit(["diff", "--numstat", "HEAD"], at: worktreePath) {
            for line in numstat.split(separator: "\n") {
                let cols = line.split(separator: "\t")
                guard cols.count >= 2 else { continue }
                // Binary files report "-" for both counts — skip them.
                if let a = Int(cols[0]) { result.added += a }
                if let d = Int(cols[1]) { result.removed += d }
            }
        }

        // Ahead/behind vs upstream. `left-right` prints "<behind>\t<ahead>".
        // Exits non-zero when no upstream is configured — leave both nil.
        if let counts = runGit(["rev-list", "--count", "--left-right", "@{upstream}...HEAD"], at: worktreePath) {
            let cols = counts.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
            if cols.count == 2 {
                result.behind = Int(cols[0])
                result.ahead = Int(cols[1])
            }
        }

        return result
    }

    /// Runs git with a hard deadline; returns stdout on a clean exit, else nil.
    /// Mirrors WorktreeDiscovery's timeout guard so a wedged git on a removable
    /// volume can't hang the poll.
    private static func runGit(_ arguments: [String], at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            return nil
        }
        if group.wait(timeout: .now() + gitTimeout) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 1)
            process.terminationHandler = nil
            return nil
        }
        process.terminationHandler = nil
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

/// Short-TTL cache so the dashboard shares one git-stats read across cards and
/// resolves off the main thread on a miss/stale. Mirrors WorktreeTitleCache.
final class WorktreeGitStatsCache {
    static let shared = WorktreeGitStatsCache()

    private struct Entry { let stats: WorktreeGitStats; let at: Date }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval = 8

    /// Cached stats if present, without any disk access. Nil if never resolved.
    func cachedStats(worktreePath: String) -> WorktreeGitStats? {
        lock.lock(); defer { lock.unlock() }
        return entries[worktreePath]?.stats
    }

    /// Serves a fresh cache entry without disk access, or resolves off-main on a
    /// miss/stale. `completion` runs on main with the resolved stats.
    func refresh(worktreePath: String, completion: @escaping (WorktreeGitStats) -> Void = { _ in }) {
        lock.lock()
        if let e = entries[worktreePath], Date().timeIntervalSince(e.at) < ttl {
            let cached = e.stats
            lock.unlock()
            DispatchQueue.main.async { completion(cached) }
            return
        }
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let stats = WorktreeGitStatsProvider.stats(worktreePath: worktreePath)
            self.lock.lock(); self.entries[worktreePath] = Entry(stats: stats, at: Date()); self.lock.unlock()
            DispatchQueue.main.async { completion(stats) }
        }
    }
}
