import Foundation

/// What a worktree's branch has on GitHub: its newest pull request, whether
/// that PR's checks pass, and where review stands. Drawn on the fleet row so
/// "CI is red" or "approved, merge it" is visible without opening anything.
struct WorktreePRStatus: Equatable {
    enum State: String { case open, draft, merged, closed }
    /// The head commit's check rollup. Nil when the commit reports no checks.
    enum Checks: String { case passing, failing, pending }
    enum Review: String {
        case approved
        case changesRequested = "changes_requested"
        case reviewRequired = "review_required"
    }

    let number: Int
    let url: String
    let state: State
    let checks: Checks?
    let review: Review?

    /// Checks and review only mean something while the PR can still change.
    var isLive: Bool { state == .open || state == .draft }

    /// One sentence for a tooltip or a screen reader.
    var summary: String {
        var parts = ["PR #\(number)", state == .draft ? "draft" : state.rawValue]
        if isLive, let checks {
            parts.append(["passing": "checks passing", "failing": "checks failing",
                          "pending": "checks running"][checks.rawValue]!)
        }
        if isLive, let review {
            parts.append(["approved": "approved", "changes_requested": "changes requested",
                          "review_required": "review required"][review.rawValue]!)
        }
        return parts.joined(separator: " · ")
    }

    /// Wire shape for remote clients (`fleet.groups` items).
    var dict: [String: Any] {
        var d: [String: Any] = ["number": number, "url": url, "state": state.rawValue]
        if isLive, let checks { d["checks"] = checks.rawValue }
        if isLive, let review { d["review"] = review.rawValue }
        return d
    }
}

/// Reads the answer to `WorktreePRStatus.query`. Pure, so it can be tested
/// against recorded JSON.
enum WorktreePRStatusParser {
    /// The repo's recently updated PRs, newest first, with what the row draws.
    /// One request per repo covers every worktree in it; a branch whose PR has
    /// not moved among the last 30 simply shows nothing.
    static let query = """
    query($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
        pullRequests(first: 30, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number url state isDraft headRefName reviewDecision
            headRepositoryOwner { login }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          }
        }
      }
    }
    """

    /// Branch → its most recently updated PR. PRs from forks are skipped: a
    /// fork's `fix-typo` is not this repo's `fix-typo` worktree.
    static func statuses(from response: [String: Any], owner: String) -> [String: WorktreePRStatus] {
        let repository = (response["data"] as? [String: Any])?["repository"] as? [String: Any]
        let nodes = (repository?["pullRequests"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        var byBranch: [String: WorktreePRStatus] = [:]
        for node in nodes {
            guard let branch = node["headRefName"] as? String, byBranch[branch] == nil,
                  let number = node["number"] as? Int,
                  let url = node["url"] as? String,
                  let state = state(node["state"] as? String, isDraft: node["isDraft"] as? Bool ?? false)
            else { continue }
            let headOwner = (node["headRepositoryOwner"] as? [String: Any])?["login"] as? String
            guard headOwner?.caseInsensitiveCompare(owner) == .orderedSame else { continue }
            let commit = ((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.last?["commit"]
                as? [String: Any]
            let rollup = (commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String
            byBranch[branch] = WorktreePRStatus(number: number, url: url, state: state,
                                                checks: checks(rollup),
                                                review: review(node["reviewDecision"] as? String))
        }
        return byBranch
    }

    static func state(_ raw: String?, isDraft: Bool) -> WorktreePRStatus.State? {
        switch raw {
        case "OPEN": return isDraft ? .draft : .open
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default: return nil
        }
    }

    /// GitHub's rollup: ERROR is a failure too; EXPECTED is a required check
    /// that has not reported yet, which is still waiting.
    static func checks(_ raw: String?) -> WorktreePRStatus.Checks? {
        switch raw {
        case "SUCCESS": return .passing
        case "FAILURE", "ERROR": return .failing
        case "PENDING", "EXPECTED": return .pending
        default: return nil
        }
    }

    static func review(_ raw: String?) -> WorktreePRStatus.Review? {
        switch raw {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .reviewRequired
        default: return nil
        }
    }
}

/// PR status per repo, fetched off the main thread and cached, so building the
/// fleet rows only reads a dictionary. Mirrors `WorktreeCleanupStore`.
final class WorktreePRStore {
    static let shared = WorktreePRStore()

    /// CI moves on the scale of minutes; a minute is fresh enough to watch it.
    static let ttl: TimeInterval = 60
    /// After a failed request (offline, rate-limited, no access), and for a
    /// repo with no token to ask with.
    static let failureTTL: TimeInterval = 5 * 60
    /// `gh auth token` and the keychain are subprocesses; do not ask per refresh.
    static let tokenTTL: TimeInterval = 10 * 60
    static let requestTimeout: TimeInterval = 8

    /// Main queue, when what is known about any branch changed.
    var onChange: (() -> Void)?

    /// Set by `MainWindowController`, which owns the token sources.
    var resolveToken: (_ repoPath: String) -> String {
        get { lock.withLock { tokenResolver } }
        set { lock.withLock { tokenResolver = newValue } }
    }

    typealias Fetch = (_ owner: String, _ repo: String, _ token: String) -> [String: WorktreePRStatus]?

    private struct RepoEntry { let byBranch: [String: WorktreePRStatus]; let at: Date; let ok: Bool }
    private let lock = NSLock()
    private var tokenResolver: (String) -> String = { _ in "" }
    private var token: (value: String, resolvedAt: Date)?
    /// Worktree → "owner/repo"; an empty string is "not on GitHub".
    private var remotes: [String: String] = [:]
    private var repos: [String: RepoEntry] = [:]
    private var inFlight: Set<String> = []
    private let queue = DispatchQueue(label: "seahelm.worktree-pr", qos: .utility)
    private let fetch: Fetch
    private let resolveRemote: (String) -> String

    init(fetch: @escaping Fetch = WorktreePRStore.fetchFromGitHub,
         resolveRemote: @escaping (String) -> String = WorktreePRStore.githubRepo(worktreePath:)) {
        self.fetch = fetch
        self.resolveRemote = resolveRemote
    }

    /// The branch's PR as last fetched, without touching disk or network.
    func status(worktreePath: String, branch: String) -> WorktreePRStatus? {
        lock.withLock {
            guard let repo = remotes[worktreePath], !repo.isEmpty else { return nil }
            return repos[repo]?.byBranch[branch]
        }
    }

    /// Re-fetch the worktree's repo in the background unless a fresh answer is
    /// cached or on its way.
    func refresh(worktreePath: String, now: Date = Date()) {
        let known: String? = lock.withLock { remotes[worktreePath] }
        if let repo = known {
            guard !repo.isEmpty else { return }
            fetchIfStale(repo: repo, repoPath: worktreePath, now: now)
            return
        }
        let start: Bool = lock.withLock { inFlight.insert("remote:" + worktreePath).inserted }
        guard start else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let repo = self.resolveRemote(worktreePath)
            self.lock.withLock {
                self.remotes[worktreePath] = repo
                self.inFlight.remove("remote:" + worktreePath)
            }
            if !repo.isEmpty { self.fetchIfStale(repo: repo, repoPath: worktreePath, now: Date()) }
        }
    }

    private func fetchIfStale(repo: String, repoPath: String, now: Date) {
        let start: Bool = lock.withLock {
            if let entry = repos[repo],
               now.timeIntervalSince(entry.at) < (entry.ok ? Self.ttl : Self.failureTTL) { return false }
            return inFlight.insert(repo).inserted
        }
        guard start else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
            let token = self.currentToken(repoPath: repoPath)
            let fetched = (parts.count == 2 && !token.isEmpty) ? self.fetch(parts[0], parts[1], token) : nil
            let changed: Bool = self.lock.withLock {
                self.inFlight.remove(repo)
                let old = self.repos[repo]
                // A failed fetch keeps what was known: a blip offline should not
                // wipe every badge until the next success.
                let byBranch = fetched ?? old?.byBranch ?? [:]
                self.repos[repo] = RepoEntry(byBranch: byBranch, at: Date(), ok: fetched != nil)
                return (old?.byBranch ?? [:]) != byBranch
            }
            if changed { DispatchQueue.main.async { self.onChange?() } }
        }
    }

    private func currentToken(repoPath: String) -> String {
        let now = Date()
        if let token = lock.withLock({ token }), now.timeIntervalSince(token.resolvedAt) < Self.tokenTTL {
            return token.value
        }
        let value = resolveToken(repoPath)
        lock.withLock { token = (value, now) }
        return value
    }

    /// "owner/repo" when `origin` is on github.com, "" otherwise.
    static func githubRepo(worktreePath: String) -> String {
        guard let url = GitProcess.run(["remote", "get-url", "origin"], in: worktreePath),
              let remote = GitRemote.parse(url),
              case .github(let owner, let repo) = remote.kind else { return "" }
        return "\(owner)/\(repo)"
    }

    static func fetchFromGitHub(owner: String, repo: String, token: String) -> [String: WorktreePRStatus]? {
        let service = GitHubPRService(token: token, owner: owner, repo: repo, requestTimeout: requestTimeout)
        guard let response = try? GitHubReturnPRClient.awaitSync({
            try await service.graphQL(WorktreePRStatusParser.query, variables: ["owner": owner, "repo": repo])
        }) else { return nil }
        return WorktreePRStatusParser.statuses(from: response, owner: owner)
    }
}
