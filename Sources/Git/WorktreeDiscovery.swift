import Foundation

struct WorktreeInfo {
    let path: String
    let branch: String
    let commitHash: String
    let isMainWorktree: Bool

    var displayName: String {
        return branch.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : branch
    }
}

enum WorktreeDiscovery {
    private static let backgroundQueue = DispatchQueue(label: "com.seahelm.git-discovery", qos: .userInitiated, attributes: .concurrent)

    /// Cache for repo root lookups (path -> repo root)
    private static var repoRootCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// Find the git toplevel (repo root) from any path inside the repo
    static func findRepoRoot(from path: String) -> String? {
        // Check cache first
        cacheLock.lock()
        if let cached = repoRootCache[path] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let result = _findRepoRootSync(from: path)
        if let result {
            cacheLock.lock()
            repoRootCache[path] = result
            cacheLock.unlock()
        }
        return result
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["worktree", "list", "--porcelain"]
        process.currentDirectoryURL = URL(fileURLWithPath: repoPath)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Failed to run git worktree list: \(error)")
            return []
        }

        guard process.terminationStatus == 0 else {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return parsePorcelain(output)
    }

    /// Parse `git worktree list --porcelain` output
    /// Canonical filesystem path: resolves symlinks (e.g. `/var` → `/private/var`)
    /// and `.`/`..` components so paths from different sources compare equal.
    /// `git worktree list` emits symlink-resolved paths, while paths we construct
    /// from a repo root may not be — normalize both through here before comparing.
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func parsePorcelain(_ output: String) -> [WorktreeInfo] {
        var worktrees: [WorktreeInfo] = []
        var currentPath: String?
        var currentBranch = ""
        var currentCommit = ""
        var isMainWorktree = false

        for line in output.components(separatedBy: "\n") {
            if line.isEmpty {
                // End of entry
                if let path = currentPath {
                    worktrees.append(WorktreeInfo(
                        path: path,
                        branch: currentBranch,
                        commitHash: currentCommit,
                        isMainWorktree: isMainWorktree
                    ))
                }
                currentPath = nil
                currentBranch = ""
                currentCommit = ""
                isMainWorktree = false
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
                currentBranch = "(detached)"
            }
        }

        // Handle last entry if no trailing newline
        if let path = currentPath {
            worktrees.append(WorktreeInfo(
                path: path,
                branch: currentBranch,
                commitHash: currentCommit,
                isMainWorktree: isMainWorktree
            ))
        }

        return worktrees
    }
}
