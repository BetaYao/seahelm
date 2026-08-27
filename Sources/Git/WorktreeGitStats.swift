import Foundation

/// Lightweight per-worktree git summary for the dashboard cards: working-tree
/// diff size (added/removed lines vs HEAD, including files git does not track
/// yet) plus ahead/behind vs the branch's upstream. Deliberately cheap — no hunk
/// parsing, just `--numstat`, an `ls-files` walk and a `rev-list` count — so it
/// can be polled behind a short-TTL cache.
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

    /// Wider deadline for the one call that walks the working tree rather than
    /// reading the index. Matches `WorktreeFileIndex`, which pays the same cost.
    private static let listTimeout: TimeInterval = 30

    /// Caps on the untracked pass, so one stray multi-gigabyte file an agent
    /// left behind cannot stall a poll that runs every few seconds. A file over
    /// the per-file ceiling is skipped outright rather than counted in part —
    /// at that size it is a log or an asset, not the work the card is reporting.
    private static let maxUntrackedFiles = 500
    private static let maxUntrackedBytes = 8 << 20
    private static let maxUntrackedFileBytes = 4 << 20

    /// How far git looks for a NUL before calling a blob binary. Mirrored here
    /// so our counts agree with the `-` numstat prints for binary files.
    private static let binarySniffWindow = 8000

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

        // `diff HEAD` sees staged additions but is blind to files git does not
        // track at all — which is the most common shape of agent work, since an
        // agent writes new files and leaves staging to the user. Without this
        // the card reports +0 for a worktree the agent just filled with code.
        result.added += untrackedAddedLines(worktreePath: worktreePath)

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

    /// Lines in files git does not track yet, counted the way `--numstat` would
    /// have if they were staged: newlines, plus one for a trailing partial line,
    /// and nothing at all for binary files. `--exclude-standard` keeps ignored
    /// build output from being mistaken for the agent's work.
    static func untrackedAddedLines(worktreePath: String) -> Int {
        guard let output = runGit(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            at: worktreePath,
            timeout: listTimeout
        ) else { return 0 }

        let root = URL(fileURLWithPath: worktreePath)
        var total = 0
        var budget = maxUntrackedBytes
        for path in output.split(separator: "\0", omittingEmptySubsequences: true).prefix(maxUntrackedFiles) {
            guard budget > 0 else { break }
            guard let data = readForCounting(root.appendingPathComponent(String(path))) else { continue }
            budget -= data.count
            total += lineCount(of: data)
        }
        return total
    }

    /// Reads a whole untracked file, or nothing if it is empty or outsized.
    ///
    /// Deliberately a bounded `FileHandle` read and not a memory map: these are
    /// files an agent is actively writing, and a mapped file truncated out from
    /// under us faults the process rather than failing the read.
    private static func readForCounting(_ url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maxUntrackedFileBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: size)
    }

    /// Lines in one blob, with git's binary rule applied first.
    private static func lineCount(of data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        return data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            let newline = UInt8(ascii: "\n")
            // Binary files are the ones numstat prints "-" for; they contribute
            // no line counts, so neither should we.
            if memchr(base, Int32(0), min(raw.count, binarySniffWindow)) != nil { return 0 }

            var lines = 0
            var cursor = base
            var remaining = raw.count
            while remaining > 0, let hit = memchr(cursor, Int32(newline), remaining) {
                lines += 1
                let consumed = UnsafeRawPointer(hit) - cursor + 1
                cursor = UnsafeRawPointer(hit) + 1
                remaining -= consumed
            }
            // A last line with no terminator still counts as a line.
            if remaining > 0 { lines += 1 }
            return lines
        }
    }

    private static func runGit(
        _ arguments: [String],
        at path: String,
        timeout: TimeInterval = gitTimeout
    ) -> String? {
        GitProcess.run(arguments, in: path, timeout: timeout)
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

    /// Drop the entry for a deleted worktree so churn doesn't grow the cache unbounded.
    func evict(worktreePath: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: worktreePath)
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
