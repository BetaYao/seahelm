import Foundation

// MARK: - Facts

/// What `/return` found when it looked at a worktree, gathered before anything
/// is touched. The planner below is a pure function of this, which is what
/// keeps "would it delete, ship, or refuse" testable without a repo.
struct WorktreeReturnFacts: Equatable {
    var branch: String
    var isMain = false
    var isIntegration = false
    /// Sitting on a commit rather than a branch: nothing to push.
    var isDetached = false
    var agentRunning = false
    var inMergeOrRebase = false
    var uncommittedFileCount = 0
    /// The branch this worktree was cut from, by name (`main`). The PR's base.
    var baseBranch: String?
    /// The base was refreshed from origin before judging. False means the
    /// verdict rests on a local ref that may be behind.
    var fetchedBase = false
    var baseOnRemote = false
    /// Commits on HEAD that are on neither the base nor the branch's upstream,
    /// patch-equivalent ones excluded. Nil when there was nothing to measure
    /// against.
    var unshippedCommits: Int?
    /// The branch's whole diff is already in the base as one commit — what a
    /// squash merge leaves, which commit-by-commit comparison cannot see.
    var squashMergedIntoBase = false
    /// The branch is a trunk name itself; the worktree can go, the branch not.
    var branchIsTrunk = false
    var remote: WorktreeReturnRemote = .none
    var hasGitHubToken = false
    var existingPRURL: String?
    var taskDescription: String?

    init(branch: String) { self.branch = branch }

    var hasUncommittedChanges: Bool { uncommittedFileCount > 0 }
    /// Nothing on this branch that the base does not already have.
    var isMerged: Bool { unshippedCommits == 0 || squashMergedIntoBase }
}

enum WorktreeReturnRemote: Equatable {
    case github(owner: String, repo: String)
    case other(host: String)
    case none
}

// MARK: - Plan

enum WorktreeReturnStep: Equatable {
    case commit(message: String, files: Int)
    case push(branch: String)
    case openPR(title: String, base: String)
    /// No PR this time, and why; the return still completes.
    case skipPR(reason: String)
    /// End here — the worktree stays.
    case stop(reason: String)
    case delete(deleteBranch: Bool)
}

enum WorktreeReturnPlan: Equatable {
    case refuse(String)
    /// Nothing to ship: clean, and the base already has everything.
    case delete(deleteBranch: Bool, reason: String)
    /// Commit if needed, push, open a PR where one can be opened, then delete.
    case ship([WorktreeReturnStep])
}

/// Decides what returning a worktree means, from facts alone.
enum WorktreeReturnPlanner {
    static let commitTrailer = "Committed by seahelm on /return."

    static func plan(_ f: WorktreeReturnFacts) -> WorktreeReturnPlan {
        if f.isMain { return .refuse("is the main worktree — it cannot be returned.") }
        if f.isIntegration { return .refuse("is the integration checkout — reset or delete it from its row.") }
        if f.agentRunning { return .refuse("has an agent running — leaving it alone.") }
        if f.inMergeOrRebase { return .refuse("is in the middle of a merge or rebase — finish that in the pane first.") }

        let base = f.baseBranch.map { f.fetchedBase ? "origin/\($0)" : $0 } ?? "its base"
        if !f.hasUncommittedChanges, f.isMerged {
            let reason = f.fetchedBase ? "nothing beyond \(base)" : "nothing beyond \(base) (judged locally — origin could not be reached)"
            return .delete(deleteBranch: !f.branchIsTrunk && !f.isDetached, reason: reason)
        }
        if f.isDetached { return .refuse("is on a detached HEAD with work on it — there is no branch to push.") }
        if f.branch.isEmpty { return .refuse("has no branch to push.") }
        if case .none = f.remote { return .refuse("has work to ship but no remote to push to.") }

        var steps: [WorktreeReturnStep] = []
        if f.hasUncommittedChanges {
            steps.append(.commit(message: f.taskDescription ?? f.branch, files: f.uncommittedFileCount))
        }
        steps.append(.push(branch: f.branch))
        switch f.remote {
        case .github:
            if let url = f.existingPRURL {
                steps.append(.skipPR(reason: "a PR is already open: \(url)"))
            } else if !f.hasGitHubToken {
                steps.append(.skipPR(reason: "no GitHub token — open the PR yourself"))
            } else if !f.baseOnRemote {
                steps.append(.stop(reason: "base branch \(f.baseBranch ?? "main") is not on origin — push it first, or return after it merges"))
                return .ship(steps)
            } else {
                steps.append(.openPR(title: f.taskDescription ?? f.branch, base: f.baseBranch ?? "main"))
            }
        case .other(let host):
            steps.append(.skipPR(reason: "origin is on \(host), not GitHub — open the merge request yourself"))
        case .none:
            break
        }
        steps.append(.delete(deleteBranch: !f.branchIsTrunk))
        return .ship(steps)
    }

    /// The plan as one line, for the confirmation: what will happen, in order.
    static func summary(of steps: [WorktreeReturnStep], label: String) -> String {
        let parts = steps.map { step -> String in
            switch step {
            case .commit(_, let files): return "commit \(files) file\(files == 1 ? "" : "s")"
            case .push(let branch): return "push \(branch)"
            case .openPR(_, let base): return "open a PR against \(base)"
            case .skipPR(let reason): return "no PR (\(reason))"
            case .stop(let reason): return "then stop: \(reason)"
            case .delete(let deleteBranch): return deleteBranch ? "delete the worktree and its branch" : "delete the worktree"
            }
        }
        return "Return \(label): " + parts.joined(separator: " → ")
    }
}

// MARK: - Execution

protocol WorktreeReturnGit {
    /// Stage everything git does not ignore and commit it.
    func commitAll(message: String) throws
    /// `git push -u origin <branch>`. Never forced: a rejected push stops the return.
    func push(branch: String) throws
    /// Subjects of the commits the branch adds over `base`, oldest first.
    func commitSubjects(since base: String) -> [String]
}

protocol WorktreeReturnPRClient {
    /// Opens the PR and returns its URL.
    func createPR(title: String, body: String, head: String, base: String) throws -> String
}

struct WorktreeReturnOutcome: Equatable {
    var completed: [WorktreeReturnStep] = []
    var prURL: String?
    var notes: [String] = []
    var failure: String?
    /// The plan reached its delete step; the host tears the worktree down.
    var deletesWorktree = false
    var deletesBranch = false
}

enum WorktreeReturnError: LocalizedError, Equatable {
    case git(String)
    case pr(String)

    var errorDescription: String? {
        switch self {
        case .git(let message): return message
        case .pr(let message): return message
        }
    }
}

/// Carries a plan out step by step and stops at the first failure — a return
/// that pushed but could not open its PR leaves the worktree where it is,
/// with the push done, rather than deleting on a half-finished plan.
enum WorktreeReturnRunner {
    static func run(_ plan: WorktreeReturnPlan, branch: String, task: String?,
                    git: WorktreeReturnGit, pr: WorktreeReturnPRClient?) -> WorktreeReturnOutcome {
        var out = WorktreeReturnOutcome()
        switch plan {
        case .refuse(let why):
            out.failure = why
        case .delete(let deleteBranch, _):
            out.deletesWorktree = true
            out.deletesBranch = deleteBranch
        case .ship(let steps):
            for step in steps {
                do {
                    switch step {
                    case .commit(let message, _):
                        try git.commitAll(message: message)
                    case .push(let name):
                        try git.push(branch: name)
                    case .openPR(let title, let base):
                        guard let pr else { throw WorktreeReturnError.pr("no GitHub client") }
                        let body = prBody(task: task, commits: git.commitSubjects(since: base))
                        out.prURL = try pr.createPR(title: title, body: body, head: branch, base: base)
                    case .skipPR(let reason):
                        out.notes.append(reason)
                    case .stop(let reason):
                        out.notes.append(reason)
                        out.completed.append(step)
                        return out
                    case .delete(let deleteBranch):
                        out.deletesWorktree = true
                        out.deletesBranch = deleteBranch
                    }
                    out.completed.append(step)
                } catch {
                    out.failure = "\(name(of: step)) failed: \(error.localizedDescription)"
                    return out
                }
            }
        }
        return out
    }

    static func prBody(task: String?, commits: [String]) -> String {
        var lines: [String] = []
        if let task, !task.isEmpty { lines.append(task); lines.append("") }
        if !commits.isEmpty {
            lines.append("Commits:")
            lines.append(contentsOf: commits.prefix(30).map { "- \($0)" })
            if commits.count > 30 { lines.append("- … and \(commits.count - 30) more") }
            lines.append("")
        }
        lines.append("Opened by seahelm `/return`.")
        return lines.joined(separator: "\n")
    }

    private static func name(of step: WorktreeReturnStep) -> String {
        switch step {
        case .commit: return "Commit"
        case .push: return "Push"
        case .openPR: return "Opening the PR"
        case .skipPR: return "PR"
        case .stop: return "Stop"
        case .delete: return "Delete"
        }
    }
}

// MARK: - Remote

/// `origin`'s URL, in the three shapes git writes it.
struct GitRemote: Equatable {
    let host: String
    let owner: String
    let repo: String

    static func parse(_ url: String) -> GitRemote? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var hostAndPath: (String, String)?
        if let range = trimmed.range(of: "://") {
            // ssh://git@github.com/owner/repo.git, https://github.com/owner/repo
            let rest = trimmed[range.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var host = String(rest[..<slash])
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
            hostAndPath = (host, String(rest[rest.index(after: slash)...]))
        } else if let colon = trimmed.firstIndex(of: ":") {
            // git@github.com:owner/repo.git
            var host = String(trimmed[..<colon])
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            hostAndPath = (host, String(trimmed[trimmed.index(after: colon)...]))
        }
        guard let (host, path) = hostAndPath else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, !host.isEmpty else { return nil }
        var repo = parts[parts.count - 1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        let owner = parts[parts.count - 2]
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return GitRemote(host: host.lowercased(), owner: owner, repo: repo)
    }

    var kind: WorktreeReturnRemote {
        host == "github.com" ? .github(owner: owner, repo: repo) : .other(host: host)
    }
}

// MARK: - Assessment (git)

/// Gathers `WorktreeReturnFacts` from a checkout. Every call here is a git
/// subprocess; run it off the main thread.
enum WorktreeReturnAssessor {
    static let fetchTimeout: TimeInterval = 30

    static func assess(worktreePath: String, repoPath: String, branch: String,
                       isMain: Bool, isDetached: Bool, recordedBase: String?) -> WorktreeReturnFacts {
        var facts = WorktreeReturnFacts(branch: branch)
        facts.isMain = isMain
        facts.isDetached = isDetached
        facts.inMergeOrRebase = isMergeOrRebaseInProgress(worktreePath: worktreePath)
        facts.uncommittedFileCount = uncommittedFileCount(worktreePath: worktreePath)

        let baseName = recordedBase.map(Self.stripOrigin) ?? Self.defaultBaseName(worktreePath: worktreePath)
        facts.baseBranch = baseName
        if let baseName {
            facts.fetchedBase = fetch(baseName, worktreePath: worktreePath)
            facts.baseOnRemote = facts.fetchedBase || refExists("origin/\(baseName)", worktreePath: worktreePath)
            let baseRef = refExists("origin/\(baseName)", worktreePath: worktreePath) ? "origin/\(baseName)"
                : (refExists(baseName, worktreePath: worktreePath) ? baseName : nil)
            facts.unshippedCommits = WorktreeDeleter.unpublishedCommitCount(worktreePath: worktreePath, trunk: baseRef)
            if let baseRef, facts.unshippedCommits != 0 {
                facts.squashMergedIntoBase = isSquashMerged(worktreePath: worktreePath, base: baseRef)
            }
            facts.branchIsTrunk = !branch.isEmpty && (branch == baseName || ["main", "master"].contains(branch))
        } else {
            facts.branchIsTrunk = ["main", "master"].contains(branch)
        }

        if let url = GitProcess.run(["remote", "get-url", "origin"], in: worktreePath),
           let remote = GitRemote.parse(url) {
            facts.remote = remote.kind
        }
        return facts
    }

    /// `git fetch origin <base>` — the one network call in the assessment.
    /// False offline, or when the base is not on origin at all.
    @discardableResult
    static func fetch(_ base: String, worktreePath: String) -> Bool {
        GitProcess.capture(["fetch", "--quiet", "origin", base], in: worktreePath, timeout: fetchTimeout).succeeded
    }

    /// The branch's whole diff already sits in `base` as one commit. Squash
    /// merges leave exactly this: no commit of the branch is an ancestor and
    /// no single patch matches, but a commit made of the branch's entire tree
    /// change has the same patch-id as the squash commit. `git cherry` reports
    /// that as `-`.
    static func isSquashMerged(worktreePath: String, base: String) -> Bool {
        guard let mergeBase = GitProcess.run(["merge-base", base, "HEAD"], in: worktreePath)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !mergeBase.isEmpty,
              let tree = GitProcess.run(["rev-parse", "HEAD^{tree}"], in: worktreePath)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !tree.isEmpty else { return false }
        // Same tree as the merge base: the branch adds nothing at all.
        if let baseTree = GitProcess.run(["rev-parse", "\(mergeBase)^{tree}"], in: worktreePath)?
            .trimmingCharacters(in: .whitespacesAndNewlines), baseTree == tree { return true }
        guard let probe = GitProcess.run(["commit-tree", tree, "-p", mergeBase, "-m", "seahelm squash probe"],
                                         in: worktreePath)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !probe.isEmpty,
              let cherry = GitProcess.run(["cherry", base, probe], in: worktreePath) else { return false }
        return cherry.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-")
    }

    static func isMergeOrRebaseInProgress(worktreePath: String) -> Bool {
        for marker in ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD"] {
            guard let path = GitProcess.run(["rev-parse", "--git-path", marker], in: worktreePath)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { continue }
            let full = path.hasPrefix("/") ? path : (worktreePath as NSString).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: full) { return true }
        }
        return false
    }

    static func uncommittedFileCount(worktreePath: String) -> Int {
        let output = GitProcess.run(["status", "--porcelain"], in: worktreePath) ?? ""
        return output.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// `main` or `master`, whichever origin has (or the checkout knows).
    static func defaultBaseName(worktreePath: String) -> String? {
        for name in ["main", "master"]
        where refExists("origin/\(name)", worktreePath: worktreePath) || refExists(name, worktreePath: worktreePath) {
            return name
        }
        return nil
    }

    static func stripOrigin(_ ref: String) -> String {
        ref.hasPrefix("origin/") ? String(ref.dropFirst("origin/".count)) : ref
    }

    static func refExists(_ ref: String, worktreePath: String) -> Bool {
        GitProcess.run(["rev-parse", "--verify", "--quiet", ref], in: worktreePath) != nil
    }
}

/// The real git behind a return: subprocesses in the worktree.
struct WorktreeReturnGitProcess: WorktreeReturnGit {
    let worktreePath: String
    /// Push goes over the network; commit and log do not.
    static let pushTimeout: TimeInterval = 120

    func commitAll(message: String) throws {
        let add = GitProcess.capture(["add", "-A"], in: worktreePath, timeout: 30)
        guard add.succeeded else { throw WorktreeReturnError.git(Self.clean(add.stderr, fallback: "git add failed")) }
        let commit = GitProcess.capture(["commit", "-m", message, "-m", WorktreeReturnPlanner.commitTrailer],
                                        in: worktreePath, timeout: 30)
        guard commit.succeeded else { throw WorktreeReturnError.git(Self.clean(commit.stderr, fallback: "git commit failed")) }
    }

    func push(branch: String) throws {
        let push = GitProcess.capture(["push", "-u", "origin", branch], in: worktreePath, timeout: Self.pushTimeout)
        guard push.succeeded else { throw WorktreeReturnError.git(Self.clean(push.stderr, fallback: "git push failed")) }
    }

    func commitSubjects(since base: String) -> [String] {
        let ref = WorktreeReturnAssessor.refExists("origin/\(base)", worktreePath: worktreePath) ? "origin/\(base)" : base
        let output = GitProcess.run(["log", "--reverse", "--format=%s", "\(ref)..HEAD"], in: worktreePath) ?? ""
        return output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// git's stderr is several lines of hints; the last non-empty one is the reason.
    private static func clean(_ stderr: String, fallback: String) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let meaningful = lines.filter { !$0.hasPrefix("hint:") && !$0.hasPrefix("To ") }
        return meaningful.last ?? lines.last ?? fallback
    }
}
