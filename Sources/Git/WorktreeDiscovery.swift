import Foundation

struct WorktreeInfo {
    let path: String
    /// Empty when the worktree is checked out at a bare commit — see `isDetached`.
    let branch: String
    let commitHash: String
    let isMainWorktree: Bool
    /// A worktree sitting on a commit rather than a branch. Rare by hand, but
    /// the normal state for a jj workspace, which is anonymous by design.
    let isDetached: Bool

    init(
        path: String,
        branch: String,
        commitHash: String,
        isMainWorktree: Bool,
        isDetached: Bool = false
    ) {
        self.path = path
        self.branch = branch
        self.commitHash = commitHash
        self.isMainWorktree = isMainWorktree
        self.isDetached = isDetached
    }

    var displayName: String {
        return branch.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : branch
    }
}

enum WorktreeDiscovery {
    private static let backgroundQueue = DispatchQueue(label: "com.seahelm.git-discovery", qos: .userInitiated, attributes: .concurrent)

    /// Upper bound on any single git invocation. A repo on a removable volume
    /// that was ejected and remounted can leave git blocked in uninterruptible
    /// kernel I/O; without a bound the whole launch state-restore pipeline hangs
    /// behind it. See `GitProcess` for the deadline + pipe-draining mechanics.
    private static let gitTimeout: TimeInterval = 5

    /// Cache for repo root lookups (path -> repo root)
    private static var repoRootCache: [String: String] = [:]
    /// Paths known *not* to sit in a repo, and when that was established.
    ///
    /// Only hits used to be cached, so every lookup of a path that is not a
    /// repo spawned a fresh `git` — and the caller that hurts is the
    /// integration coordinator, which asks once per worktree per round, on the
    /// main thread. Worse where it matters most: a path on a volume that has
    /// gone away makes git block until `gitTimeout`, so one unreachable
    /// worktree stalled the main thread for seconds, over and over. Sampling
    /// the app found 78% of main-thread time inside `posix_spawn` and
    /// `ulock_wait` under exactly this call.
    ///
    /// Time-limited because the answer can legitimately change — `git init` or
    /// a clone turns a plain directory into a repo.
    private static var repoRootMissCache: [String: Date] = [:]
    static var repoRootMissTTL: TimeInterval = 60
    private static let cacheLock = NSLock()

    /// Find the git toplevel (repo root) from any path inside the repo
    static func findRepoRoot(from path: String) -> String? {
        // Check cache first
        cacheLock.lock()
        if let cached = repoRootCache[path] {
            cacheLock.unlock()
            return cached
        }
        if let missedAt = repoRootMissCache[path],
           Date().timeIntervalSince(missedAt) < repoRootMissTTL {
            cacheLock.unlock()
            return nil
        }
        cacheLock.unlock()

        let result = _findRepoRootSync(from: path)
        cacheLock.lock()
        if let result {
            repoRootCache[path] = result
            repoRootMissCache.removeValue(forKey: path)
        } else {
            repoRootMissCache[path] = Date()
        }
        cacheLock.unlock()
        return result
    }

    /// Drops both caches. Tests only — a repo root does not move at runtime.
    static func resetRepoRootCacheForTesting() {
        cacheLock.lock()
        repoRootCache.removeAll()
        repoRootMissCache.removeAll()
        cacheLock.unlock()
    }

    private static func _findRepoRootSync(from path: String) -> String? {
        // `--show-toplevel` inside a linked worktree returns the *worktree's own*
        // path, not the main repo — which once let a worktree get added to
        // workspace_paths as if it were a repo. `--git-common-dir` always points
        // at the main repo's .git, so its parent is the true repo root.
        guard let commonDir = runGit(["rev-parse", "--git-common-dir"], at: path)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !commonDir.isEmpty else { return nil }
        var url = URL(fileURLWithPath: commonDir)
        // Relative form (".git" in the main worktree) — resolve against `path`.
        if !commonDir.hasPrefix("/") {
            url = URL(fileURLWithPath: path).appendingPathComponent(commonDir)
        }
        url = url.standardizedFileURL
        // Non-bare repos: root is the directory containing .git.
        if url.lastPathComponent == ".git" {
            return url.deletingLastPathComponent().path
        }
        return url.path
    }

    private static func runGit(_ arguments: [String], at path: String) -> String? {
        GitProcess.run(arguments, in: path, timeout: gitTimeout)
    }

    /// Async version: find repo root on background queue, callback on main
    static func findRepoRootAsync(from path: String, completion: @escaping (String?) -> Void) {
        // Check cache first
        cacheLock.lock()
        if let cached = repoRootCache[path] {
            cacheLock.unlock()
            DispatchQueue.main.async { completion(cached) }
            return
        }
        cacheLock.unlock()

        backgroundQueue.async {
            let result = _findRepoRootSync(from: path)
            if let result {
                cacheLock.lock()
                repoRootCache[path] = result
                cacheLock.unlock()
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Discover all worktrees for a given repository path
    static func discover(repoPath: String) -> [WorktreeInfo] {
        return _discoverSync(repoPath: repoPath)
    }

    /// Async version: discover worktrees on background queue, callback on main
    static func discoverAsync(repoPath: String, completion: @escaping ([WorktreeInfo]) -> Void) {
        backgroundQueue.async {
            let result = _discoverSync(repoPath: repoPath)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func _discoverSync(repoPath: String) -> [WorktreeInfo] {
        guard let output = runGit(["worktree", "list", "--porcelain"], at: repoPath) else {
            NSLog("git worktree list timed out or failed at \(repoPath)")
            return []
        }
        return parsePorcelain(output)
    }

    /// Parse `git worktree list --porcelain` output
    /// Canonical filesystem path: resolves symlinks (e.g. `/var` → `/private/var`)
    /// and `.`/`..` components so paths from different sources compare equal.
    /// `git worktree list` emits symlink-resolved paths, while paths we construct
    /// from a repo root may not be — normalize both through here before comparing.
    ///
    /// Symlink resolution is bounded: against a stale removable mount,
    /// `resolvingSymlinksInPath` blocks forever in the kernel and was the
    /// beachball that froze the whole UI after an external disk dropped. A
    /// fenced volume (see `VolumeFence`) skips the filesystem entirely.
    static func canonicalPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if VolumeFence.isFenced(standardized) {
            return standardized
        }
        if let resolver = canonicalPathResolverForTesting {
            return resolver(standardized) ?? standardized
        }
        return FileSystemProbe.resolvedPath(standardized) ?? standardized
    }

    /// Test seam for the bounded resolver. Production uses `FileSystemProbe.resolvedPath`.
    static var canonicalPathResolverForTesting: ((String) -> String?)?

    static func resetCanonicalPathResolverForTesting() {
        canonicalPathResolverForTesting = nil
    }

    static func parsePorcelain(_ output: String) -> [WorktreeInfo] {
        var worktrees: [WorktreeInfo] = []
        var currentPath: String?
        var currentBranch = ""
        var currentCommit = ""
        var isMainWorktree = false
        var isDetached = false

        for line in output.components(separatedBy: "\n") {
            if line.isEmpty {
                // End of entry
                if let path = currentPath {
                    worktrees.append(WorktreeInfo(
                        path: path,
                        branch: currentBranch,
                        commitHash: currentCommit,
                        isMainWorktree: isMainWorktree,
                        isDetached: isDetached
                    ))
                }
                currentPath = nil
                currentBranch = ""
                currentCommit = ""
                isMainWorktree = false
                isDetached = false
            } else if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
                    .trimmingCharacters(in: .whitespaces)
                // First worktree entry is always the main worktree
                if worktrees.isEmpty && currentPath != nil {
                    isMainWorktree = true
                }
            } else if line.hasPrefix("HEAD ") {
                currentCommit = String(line.dropFirst("HEAD ".count).prefix(8))
            } else if line.hasPrefix("branch ") {
                let fullRef = String(line.dropFirst("branch ".count))
                // Strip refs/heads/ prefix
                if fullRef.hasPrefix("refs/heads/") {
                    currentBranch = String(fullRef.dropFirst("refs/heads/".count))
                } else {
                    currentBranch = fullRef
                }
            } else if line == "bare" {
                // bare worktree, skip
            } else if line == "detached" {
                // Leave `branch` empty rather than naming it "(detached)": that
                // string is not a branch, it defeats the directory-name fallback
                // in `displayName`, and it makes every detached worktree look
                // like the same one to anything matching on branch name.
                isDetached = true
            }
        }

        // Handle last entry if no trailing newline
        if let path = currentPath {
            worktrees.append(WorktreeInfo(
                path: path,
                branch: currentBranch,
                commitHash: currentCommit,
                isMainWorktree: isMainWorktree,
                isDetached: isDetached
            ))
        }

        return worktrees
    }
}
