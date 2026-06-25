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
    ) throws {
        // Don't allow deleting the main worktree.
        // Use the first entry from `git worktree list` which is always the main worktree.
        // Note: `git rev-parse --show-toplevel` returns the worktree's own path when run
        // inside a linked worktree, so it cannot reliably identify the main worktree.
        let listOutput = runGit(args: ["worktree", "list", "--porcelain"], in: repoPath) ?? ""
        if let firstLine = listOutput.components(separatedBy: "\n").first,
           firstLine.hasPrefix("worktree ") {
            let mainPath = String(firstLine.dropFirst("worktree ".count))
            if worktreePath == mainPath {
                throw WorktreeDeleterError.isMainWorktree
            }
        }

        // git worktree remove <path> [--force]
        var args = ["worktree", "remove", worktreePath]
        if force { args.append("--force") }

        let (success, stderr) = runGitWithStderr(args: args, in: repoPath)
        if !success {
            throw WorktreeDeleterError.gitFailed(stderr)
        }

        // Optionally delete the branch
        if deleteBranch {
            let flag = force ? "-D" : "-d"
            let (branchOk, branchErr) = runGitWithStderr(args: ["branch", flag, branchName], in: repoPath)
            if !branchOk {
                // Non-fatal: worktree removed but branch delete failed
                NSLog("Warning: worktree removed but branch delete failed: \(branchErr)")
            }
        }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, error.localizedDescription, "")
        }

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, stderr.trimmingCharacters(in: .whitespacesAndNewlines), stdout)
    }
}
