import Foundation

/// Why a freshly built integration was not checked out.
enum IntegrationHoldReason: Equatable {
    /// Someone edited files in the integration checkout. Publishing would
    /// discard them, so it waits to be told. It carries the paths because the
    /// only useful question about a hold is which files are in the way.
    case dirtyWorktree(paths: [String])
    /// The checkout is not where seahelm left it — someone committed in here.
    /// `reset --hard` would drop those commits with nothing to recover them
    /// from, and a hand-resolved conflict is exactly the kind of work that
    /// arrives this way: the checkout is where you go to resolve one.
    case movedHead(head: String)

    /// The sheet line for a reset or delete that would destroy this. Names
    /// what goes, because that is the whole decision.
    var lossDescription: String {
        switch self {
        case .dirtyWorktree(let paths):
            return "Local edits in the integration worktree will be discarded"
                + IntegrationWorktree.pathList(paths) + "."
        case .movedHead(let head):
            return "Commits made in the integration worktree (at \(head.prefix(9))) are on no branch"
                + " and will be dropped."
        }
    }
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
    ///
    /// Uncommitted work is not the only thing a reset can destroy: a commit made
    /// in the checkout leaves it perfectly clean, so the dirty check waves it
    /// through and the next round overwrites it. `expectedHead` (the commit
    /// seahelm last published here) and `base` (the trunk this round is built
    /// on) are what let it tell its own work from someone else's — see
    /// `isSeahelmsOwnWork`. Passing neither skips the check entirely, because
    /// with no information at all a guard could only guess.
    static func publish(
        commit: String,
        to path: String,
        force: Bool = false,
        expectedHead: String? = nil,
        base: String? = nil
    ) -> IntegrationPublishOutcome {
        // Trees, not commits. `commit-tree` stamps a timestamp, so rebuilding an
        // unchanged fleet yields a different commit holding identical files —
        // comparing commits would make every round look like a change and reset
        // the checkout for nothing.
        guard let headTree = revParse("HEAD^{tree}", in: path) else {
            return .failed("Not a worktree: \(path)")
        }
        let targetTree = revParse("\(commit)^{tree}", in: path)

        let dirtyPaths = localEditPaths(at: path)

        // Nothing to do: the files already match, so neither a stray commit nor
        // the absence of one can cost anything — there is no reset to hold back.
        if let targetTree, targetTree == headTree, dirtyPaths.isEmpty {
            return .unchanged(commit: commit)
        }
        if !force, let reason = handWork(at: path, dirtyPaths: dirtyPaths, expectedHead: expectedHead, base: base) {
            return .held(reason: reason, commit: commit)
        }

        let result = GitProcess.capture(["reset", "--hard", commit], in: path, timeout: timeout)
        guard result.succeeded else {
            return .failed(result.stderr.isEmpty ? "git reset --hard failed" : result.stderr)
        }
        return .published(commit: commit)
    }

    /// Work in the checkout that arrived by hand — what a `reset --hard` would
    /// destroy. Nil when there is none. `expectedHead` and `base` as in
    /// `publish`; passing neither skips the commit check.
    static func handWork(at path: String, expectedHead: String?, base: String?) -> IntegrationHoldReason? {
        handWork(at: path, dirtyPaths: localEditPaths(at: path), expectedHead: expectedHead, base: base)
    }

    private static func handWork(
        at path: String,
        dirtyPaths: [String],
        expectedHead: String?,
        base: String?
    ) -> IntegrationHoldReason? {
        // Checked before the dirty case: both block the same reset, but losing
        // committed work is the more surprising of the two, and "discard your
        // edits" is the wrong thing to offer someone who committed them.
        if expectedHead != nil || base != nil, let head = revParse("HEAD", in: path),
           !isSeahelmsOwnWork(head: head, expectedHead: expectedHead, base: base, path: path) {
            return .movedHead(head: head)
        }
        if !dirtyPaths.isEmpty {
            return .dirtyWorktree(paths: dirtyPaths)
        }
        return nil
    }

    // MARK: - Reset to trunk

    /// Where a reset lands.
    struct ResetTarget: Equatable {
        let ref: String
        let commit: String
    }

    /// The trunk a reset moves the checkout onto: `origin/main` when the repo
    /// has one, then the same list `GitDiff` guesses a base from. `fetch`
    /// refreshes it from origin first — "in sync with origin/main" means the
    /// origin's main, not the one seen at the last fetch — but only best
    /// effort: offline, the reset still lands on the trunk already known.
    static func resetTarget(repoPath: String, fetch: Bool = true) -> ResetTarget? {
        if fetch { fetchTrunk(repoPath: repoPath) }
        for ref in GitDiff.preferredBaseRefs {
            if let commit = revParse(ref, in: repoPath) {
                return ResetTarget(ref: ref, commit: commit)
            }
        }
        return nil
    }

    private static func fetchTrunk(repoPath: String) {
        for name in ["main", "master"] {
            // `+` so a rewound trunk still updates; the prompt is disabled
            // because there is no terminal to answer one on.
            _ = GitProcess.capture(
                ["fetch", "--quiet", "origin", "+\(name):refs/remotes/origin/\(name)"],
                in: repoPath,
                timeout: timeout,
                environment: ["GIT_TERMINAL_PROMPT": "0"]
            )
        }
    }

    /// Moves the checkout onto trunk. Same hold rules as `publish`, so a
    /// reset never quietly walks over edits or commits someone made here —
    /// the caller presents a held reset and comes back with `force`.
    ///
    /// Unlike `publish`, this compares commits rather than trees: the point
    /// is for HEAD to *be* trunk, not merely to hold the same files.
    static func reset(
        to target: ResetTarget,
        at path: String,
        force: Bool = false,
        expectedHead: String? = nil
    ) -> IntegrationPublishOutcome {
        guard let head = revParse("HEAD", in: path) else {
            return .failed("Not a worktree: \(path)")
        }
        let dirtyPaths = localEditPaths(at: path)
        if head == target.commit, dirtyPaths.isEmpty {
            return .unchanged(commit: target.commit)
        }
        if !force, let reason = handWork(at: path, dirtyPaths: dirtyPaths, expectedHead: expectedHead, base: target.ref) {
            return .held(reason: reason, commit: target.commit)
        }
        let result = GitProcess.capture(["reset", "--hard", target.commit], in: path, timeout: timeout)
        guard result.succeeded else {
            return .failed(result.stderr.isEmpty ? "git reset --hard failed" : result.stderr)
        }
        return .published(commit: target.commit)
    }

    /// What deleting the checkout would destroy, in the same terms a reset
    /// uses. A checkout sitting where seahelm left it holds nothing of its
    /// own — its commits are throwaway builds — so it goes without a sheet.
    static func assessDeletion(path: String, repoPath: String, expectedHead: String?) -> WorktreeDeleteAssessment {
        let base = resetTarget(repoPath: repoPath, fetch: false)?.ref
        let losses = handWork(at: path, expectedHead: expectedHead, base: base).map { [$0.lossDescription] } ?? []
        // Detached: there is no branch to delete.
        return WorktreeDeleteAssessment(losses: losses, deletesBranch: false)
    }

    /// A hold is only actionable if it says what is in the way, and only
    /// readable if it stops before the whole tree — a `pnpm install` dirties
    /// hundreds of paths.
    static func pathList(_ paths: [String], limit: Int = 4) -> String {
        guard !paths.isEmpty else { return "" }
        let shown = paths.prefix(limit).joined(separator: ", ")
        let rest = paths.count - min(limit, paths.count)
        return rest > 0 ? " (\(shown) +\(rest) more)" : " (\(shown))"
    }

    /// Whether the checkout's HEAD is something seahelm put there.
    ///
    /// Three ways to be sure, in order of how directly they answer:
    ///
    /// 1. it is the commit we recorded publishing;
    /// 2. it carries seahelm's committer identity, which only
    ///    `WorktreeSnapshotter.commitTree` writes — this is what makes the
    ///    guard work on the *first* round after an upgrade, rather than one
    ///    round late, which is one round too late for the work it protects;
    /// 3. it is contained in the trunk this round builds on, i.e. the checkout
    ///    holds nothing of its own. A checkout sitting where it was created
    ///    answers here.
    ///
    /// Anything else is work that arrived by hand, and a `reset --hard` would
    /// be the only record that it ever existed.
    static func isSeahelmsOwnWork(head: String, expectedHead: String?, base: String?, path: String) -> Bool {
        if let expectedHead, head == expectedHead { return true }
        let committer = GitProcess.run(["log", "-1", "--format=%ce", head], in: path, timeout: timeout)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if committer == WorktreeSnapshotter.authorEmail { return true }
        if let base {
            return GitProcess.capture(
                ["merge-base", "--is-ancestor", head, base],
                in: path,
                timeout: timeout
            ).succeeded
        }
        return false
    }

    private static func revParse(_ rev: String, in path: String) -> String? {
        let value = GitProcess.run(["rev-parse", "--verify", "--quiet", rev], in: path, timeout: timeout)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    /// True when the checkout carries edits that publishing would discard.
    static func hasLocalEdits(at path: String) -> Bool {
        !localEditPaths(at: path).isEmpty
    }

    /// The paths publishing would discard — modified, staged and untracked.
    static func localEditPaths(at path: String) -> [String] {
        guard let status = GitProcess.run(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            in: path,
            timeout: timeout
        ) else { return [] }
        return parseStatusPaths(status)
    }

    /// `XY <path>\0` per entry, except renames and copies, which append the
    /// origin path as a field of its own. Reading that origin as another entry
    /// would list a file that is not in the way twice over.
    static func parseStatusPaths(_ raw: String) -> [String] {
        var paths: [String] = []
        var fields = raw.components(separatedBy: "\0").filter { !$0.isEmpty }[...]
        while let entry = fields.first {
            fields = fields.dropFirst()
            guard entry.count > 3 else { continue }
            let code = entry.prefix(2)
            paths.append(String(entry.dropFirst(3)))
            if code.contains("R") || code.contains("C") {
                fields = fields.dropFirst()
            }
        }
        return paths
    }
}
