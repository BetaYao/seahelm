import Foundation

/// Why a freshly built integration was not checked out.
enum IntegrationHoldReason: Equatable {
    /// Someone edited files in the integration checkout. Publishing would
    /// discard them, so it waits to be told.
    case dirtyWorktree
}

enum IntegrationPublishOutcome: Equatable {
    /// Checked out. The integration worktree is now at this commit.
    case published(commit: String)
    /// Already there — the build produced what is already checked out.
    case unchanged(commit: String)
    /// Built, not checked out. The commit is kept so the caller can offer it.
    case held(reason: IntegrationHoldReason, commit: String)
    case failed(String)
}

/// The integration checkout: creating it, and moving it to a built commit.
///
/// It is deliberately **detached**. A branch would be a thing to manage — a name
/// to reset, something pushable, and an entry in `git branch -a`, which is what
/// the new-branch dialog offers as a base. A worktree based on the integration
/// branch would then inherit a half-tested mixture of everyone's work. Detached,
/// there is no ref to pick.
///
/// Publishing is one `reset --hard` onto a commit that is *already merged*, so
/// it cannot fail partway and cannot leave a conflicted checkout. That is the
/// difference between this and running `git merge` here, and it is what makes
/// the operation safe to repeat unattended.
enum IntegrationWorktree {
    static let timeout: TimeInterval = 60

    /// Directory name inside the repo's worktree folder.
    static let directoryName = "integration"

    /// Sibling of the agent worktrees, matching `WorktreeCreator`'s layout.
    static func defaultPath(forRepo repoPath: String) -> String {
        let repoURL = URL(fileURLWithPath: repoPath)
        return repoURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(repoURL.lastPathComponent)-worktrees/\(directoryName)")
            .path
    }

    enum CreateError: LocalizedError {
        case pathExists(String)
        case noBaseRef
        case gitFailed(String)

        var errorDescription: String? {
            switch self {
            case .pathExists(let path): return "Path already exists: \(path)"
            case .noBaseRef: return "Could not find a trunk to base the integration on"
            case .gitFailed(let message): return message
            }
        }
    }

    /// Creates the detached checkout at `base`. Does not record it anywhere —
    /// the caller owns the store, so this stays testable without touching the
    /// user's config.
    @discardableResult
    static func create(repoPath: String, at path: String, base: String) throws -> String {
        if FileManager.default.fileExists(atPath: path) {
            throw CreateError.pathExists(path)
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let result = GitProcess.capture(
            ["worktree", "add", "--detach", path, base],
            in: repoPath,
            timeout: timeout
        )
        guard result.succeeded else {
            throw CreateError.gitFailed(result.stderr.isEmpty ? "git worktree add failed" : result.stderr)
        }
        return path
    }

    /// Removes the checkout. Detached, so there is no branch to clean up after.
    static func remove(repoPath: String, path: String) -> Bool {
        GitProcess.capture(
            ["worktree", "remove", "--force", path],
            in: repoPath,
            timeout: timeout
        ).succeeded
    }

    /// Moves the checkout onto `commit`.
    ///
    /// `reset --hard` discards anything uncommitted, so a dirty checkout holds
    /// instead — this is the one irreversible step in the feature, and it needs
    /// a deliberate `force` rather than happening quietly while someone is
    /// mid-edit.
    static func publish(commit: String, to path: String, force: Bool = false) -> IntegrationPublishOutcome {
        // Trees, not commits. `commit-tree` stamps a timestamp, so rebuilding an
        // unchanged fleet yields a different commit holding identical files —
        // comparing commits would make every round look like a change and reset
        // the checkout for nothing.
        guard let headTree = revParse("HEAD^{tree}", in: path) else {
            return .failed("Not a worktree: \(path)")
        }
        let targetTree = revParse("\(commit)^{tree}", in: path)

        let status = GitProcess.run(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            in: path,
            timeout: timeout
        )
        let isDirty = !(status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if let targetTree, targetTree == headTree, !isDirty {
            return .unchanged(commit: commit)
        }
        if isDirty && !force {
            return .held(reason: .dirtyWorktree, commit: commit)
        }

        let result = GitProcess.capture(["reset", "--hard", commit], in: path, timeout: timeout)
        guard result.succeeded else {
            return .failed(result.stderr.isEmpty ? "git reset --hard failed" : result.stderr)
        }
        return .published(commit: commit)
    }

    private static func revParse(_ rev: String, in path: String) -> String? {
        let value = GitProcess.run(["rev-parse", "--verify", "--quiet", rev], in: path, timeout: timeout)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    /// True when the checkout carries edits that publishing would discard.
    static func hasLocalEdits(at path: String) -> Bool {
        guard let status = GitProcess.run(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            in: path,
            timeout: timeout
        ) else { return false }
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
