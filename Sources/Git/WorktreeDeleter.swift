import Foundation

enum WorktreeDeleterError: Error, LocalizedError {
    case gitFailed(String)
    case isMainWorktree
    case pathNotFound(String)

    var errorDescription: String? {
        switch self {
        case .gitFailed(let msg): return "Git error: \(msg)"
        case .isMainWorktree: return "Cannot delete the main worktree"
        case .pathNotFound(let path): return "Worktree not found: \(path)"
        }
    }
}

struct WorktreeDeleteResult: Equatable {
    /// Non-empty when the worktree was removed but branch deletion failed.
    let branchWarning: String?
}

struct WorktreeMergeCheck: Equatable {
    let canDelete: Bool
    let reason: String
    let targetBranch: String?
}

struct WorktreeCleanupSummary: Equatable {
    struct Skipped: Equatable {
        let path: String
        let reason: String
    }

    var checkedCount: Int
    var deletedPaths: [String]
    var skipped: [Skipped]
}

enum WorktreeDeleter {
    /// `git worktree remove` deletes a whole checkout, so it gets the same
    /// generous deadline as creation rather than the read-only helpers'.
    private static let gitTimeout: TimeInterval = 120

    /// Remove a git worktree and optionally delete its branch.
    /// - Parameters:
    ///   - worktreePath: Absolute path to the worktree directory
    ///   - repoPath: Root repo path (for running git commands)
    ///   - deleteBranch: If true, also deletes the local branch
    ///   - force: If true, uses --force for dirty worktrees
    static func deleteWorktree(
        worktreePath: String,
        repoPath: String,
        branchName: String,
        deleteBranch: Bool = false,
        force: Bool = false
    ) throws -> WorktreeDeleteResult {
        // Don't allow deleting the main worktree.
        // Use the first entry from `git worktree list` which is always the main worktree.
        // Note: `git rev-parse --show-toplevel` returns the worktree's own path when run
        // inside a linked worktree, so it cannot reliably identify the main worktree.
        let listOutput = runGit(args: ["worktree", "list", "--porcelain"], in: repoPath) ?? ""
        if let firstLine = listOutput.components(separatedBy: "\n").first,
           firstLine.hasPrefix("worktree ") {
            let mainPath = String(firstLine.dropFirst("worktree ".count))
            // Compare resolved paths: git reports the real path while a caller
            // can hold one that reaches it through a symlink (any path under
            // /var, which is /private/var, and every macOS temporary directory).
            // String equality let those through to git, which rejects them too —
            // but with a message this class then has to pattern-match back into
            // meaning, and only after attempting the delete.
            if Self.samePath(worktreePath, mainPath) {
                throw WorktreeDeleterError.isMainWorktree
            }
        }

        // git worktree remove <path> [--force]
        var args = ["worktree", "remove", worktreePath]
        if force { args.append("--force") }

        let (success, stderr) = runGitWithStderr(args: args, in: repoPath)
        if !success {
            throw WorktreeDeleterError.gitFailed(classifyWorktreeRemoveError(stderr, path: worktreePath))
        }

        // Optionally delete the branch
        var branchWarning: String?
        if deleteBranch {
            let flag = force ? "-D" : "-d"
            let (branchOk, branchErr) = runGitWithStderr(args: ["branch", flag, branchName], in: repoPath)
            if !branchOk {
                branchWarning = classifyBranchDeleteError(branchErr, branch: branchName, forced: force)
                NSLog("Warning: worktree removed but branch delete failed: \(branchWarning ?? branchErr)")
            }
        }
        return WorktreeDeleteResult(branchWarning: branchWarning)
    }

    /// Check if a worktree has uncommitted changes
    static func hasUncommittedChanges(worktreePath: String) -> Bool {
        let output = runGit(args: ["status", "--porcelain"], in: worktreePath) ?? ""
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Checks whether a linked worktree's committed code is already contained
    /// in the remote main/master branch. This accepts both direct ancestry and
    /// cherry-pick-equivalent patches.
    static func mergeCheckForOnlineMainOrMaster(worktreePath: String, repoPath: String) -> WorktreeMergeCheck {
        let listOutput = runGit(args: ["worktree", "list", "--porcelain"], in: repoPath) ?? ""
        if let firstLine = listOutput.components(separatedBy: "\n").first,
           firstLine.hasPrefix("worktree ") {
            let mainPath = String(firstLine.dropFirst("worktree ".count))
            if worktreePath == mainPath {
                return WorktreeMergeCheck(
                    canDelete: false,
                    reason: "This is the main worktree.",
                    targetBranch: nil
                )
            }
        }

        if hasUncommittedChanges(worktreePath: worktreePath) {
            return WorktreeMergeCheck(
                canDelete: false,
                reason: "This worktree has uncommitted changes.",
                targetBranch: nil
            )
        }

        refreshOnlineMainOrMasterRefs(repoPath: repoPath)
        guard let target = onlineMainOrMasterRef(repoPath: repoPath) else {
            return WorktreeMergeCheck(
                canDelete: false,
                reason: "Could not find origin/main or origin/master.",
                targetBranch: nil
            )
        }

        let ancestor = runGitFull(args: ["merge-base", "--is-ancestor", "HEAD", target], in: worktreePath).success
        if ancestor {
            return WorktreeMergeCheck(
                canDelete: true,
                reason: "Merged into \(target).",
                targetBranch: target
            )
        }

        let cherry = runGit(args: ["log", "--cherry-pick", "--right-only", "--no-merges", "--format=%H", "\(target)...HEAD"], in: worktreePath)
        guard let cherry else {
            return WorktreeMergeCheck(
                canDelete: false,
                reason: "Could not compare this worktree with \(target).",
                targetBranch: target
            )
        }

        let uniqueCommits = cherry
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if uniqueCommits.isEmpty {
            return WorktreeMergeCheck(
                canDelete: true,
                reason: "Patch is already present in \(target).",
                targetBranch: target
            )
        }

        return WorktreeMergeCheck(
            canDelete: false,
            reason: "This worktree has \(uniqueCommits.count) commit(s) not merged into \(target).",
            targetBranch: target
        )
    }

    /// Scans every linked worktree and removes only the ones whose committed
    /// changes are already present in origin/main or origin/master.
    static func cleanMergedWorktrees(
        worktrees: [WorktreeInfo],
        repoPathForWorktree: (WorktreeInfo) -> String?,
        deleteBranch: Bool = false
    ) -> WorktreeCleanupSummary {
        var summary = WorktreeCleanupSummary(checkedCount: 0, deletedPaths: [], skipped: [])

        for info in worktrees where !info.isMainWorktree {
            summary.checkedCount += 1

            guard let repoPath = repoPathForWorktree(info) else {
                summary.skipped.append(.init(path: info.path, reason: "Could not resolve repository root."))
                continue
            }

            let check = mergeCheckForOnlineMainOrMaster(worktreePath: info.path, repoPath: repoPath)
            guard check.canDelete else {
                summary.skipped.append(.init(path: info.path, reason: check.reason))
                continue
            }

            do {
                try deleteWorktree(
                    worktreePath: info.path,
                    repoPath: repoPath,
                    branchName: info.branch,
                    deleteBranch: deleteBranch,
                    force: false
                )
                summary.deletedPaths.append(info.path)
            } catch {
                summary.skipped.append(.init(path: info.path, reason: error.localizedDescription))
            }
        }

        return summary
    }

    private static func refreshOnlineMainOrMasterRefs(repoPath: String) {
        _ = runGitFull(args: ["fetch", "--quiet", "origin", "main:refs/remotes/origin/main"], in: repoPath)
        _ = runGitFull(args: ["fetch", "--quiet", "origin", "master:refs/remotes/origin/master"], in: repoPath)
    }

    private static func onlineMainOrMasterRef(repoPath: String) -> String? {
        for ref in ["origin/main", "origin/master"] {
            if runGitFull(args: ["rev-parse", "--verify", "--quiet", ref], in: repoPath).success {
                return ref
            }
        }
        return nil
    }

    private static func runGit(args: [String], in directory: String) -> String? {
        let (success, _, stdout) = runGitFull(args: args, in: directory)
        return success ? stdout : nil
    }

    private static func runGitWithStderr(args: [String], in directory: String) -> (success: Bool, stderr: String) {
        let (success, stderr, _) = runGitFull(args: args, in: directory)
        return (success, stderr)
    }

    private static func runGitFull(args: [String], in directory: String) -> (success: Bool, stderr: String, stdout: String) {
        let result = GitProcess.capture(args, in: directory, timeout: gitTimeout)
        return (
            result.succeeded,
            result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            result.stdout
        )
    }

    /// Whether two paths name the same directory once symlinks are resolved.
    /// Pure and internal so the symlink case can be tested without a repo.
    static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs != rhs else { return true }
        let resolve = { (p: String) in
            URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return resolve(lhs) == resolve(rhs)
    }

    private static func classifyWorktreeRemoveError(_ stderr: String, path: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("is a main working tree") || lower.contains("main worktree") {
            return "Cannot delete the main worktree."
        }
        if lower.contains("contains modified or untracked files")
            || lower.contains("contains uncommitted changes")
            || lower.contains("would be overwritten by checkout") {
            return "Worktree has uncommitted changes. Use force delete to discard local changes."
        }
        if lower.contains("locked") || lower.contains("in use by another process") {
            return "Worktree is locked or currently in use. Close processes using it and try again."
        }
        if lower.contains("not a working tree")
            || lower.contains("no such file or directory")
            || lower.contains("could not remove") {
            return "Worktree path not found or already removed: \(path)"
        }
        if stderr.isEmpty {
            return "git worktree remove failed."
        }
        return stderr
    }

    private static func classifyBranchDeleteError(_ stderr: String, branch: String, forced: Bool) -> String {
        let lower = stderr.lowercased()
        if lower.contains("not fully merged") {
            if forced {
                return "Worktree was deleted, but branch '\(branch)' still could not be removed (not fully merged)."
            }
            return "Worktree was deleted, but branch '\(branch)' was not removed because it is not fully merged."
        }
        if lower.contains("checked out at") || lower.contains("is checked out") {
            return "Worktree was deleted, but branch '\(branch)' is still checked out by another worktree."
        }
        if lower.contains("not found") || lower.contains("branch '\(branch)' not found") {
            return "Worktree was deleted. Branch '\(branch)' was already absent locally."
        }
        if stderr.isEmpty {
            return "Worktree was deleted, but branch '\(branch)' could not be removed."
        }
        return "Worktree was deleted, but branch '\(branch)' could not be removed: \(stderr)"
    }
}
