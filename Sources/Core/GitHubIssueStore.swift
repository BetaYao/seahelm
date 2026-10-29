import Foundation

/// `owner/repo` on github.com.
struct GitHubRepoRef: Hashable {
    let owner: String
    let repo: String
    var fullName: String { "\(owner)/\(repo)" }
}

/// One repo's open issues, plus which branches its open PRs say they close.
struct GitHubIssueSnapshot {
    let issues: [GitHubIssue]
    /// PR head branch → issue numbers its body closes (`Closes #12`).
    let closingByBranch: [String: [Int]]
    let fetchedAt: Date
    /// The token's owner; nil when `/user` could not be read, which leaves
    /// only the "All" scope.
    var viewerLogin: String? = nil
    /// Read without a token — a public repo. Refreshed less often, since
    /// anonymous requests share 60 an hour per IP.
    var isAnonymous = false

    /// The open issues `branch` works on: the number its name carries, then
    /// whatever its open PR closes. A number that is not an open issue here —
    /// a date-prefixed branch, an issue already closed — is left out.
    func linkedIssues(branch: String) -> [GitHubIssue] {
        guard !branch.isEmpty else { return [] }
        var numbers: [Int] = []
        if let n = IssueLink.issueNumber(inBranch: branch) { numbers.append(n) }
        for n in closingByBranch[branch] ?? [] where !numbers.contains(n) { numbers.append(n) }
        return numbers.compactMap { n in issues.first { $0.number == n } }
    }
}

enum GitHubIssueListState {
    case loading
    case loaded(GitHubIssueSnapshot)
    /// No token, and the repo did not answer anonymously: it is private
    /// (GitHub says 404 rather than revealing it exists), or this network's
    /// anonymous quota — 60 an hour, shared by everyone behind the same IP —
    /// is spent. Either way a token fixes it, so the panel is still offered
    /// to say so.
    case needsLogin(LoginReason)

    enum LoginReason { case privateRepo, anonymousLimit }
    /// Issues cannot be read and signing in would not help: issues disabled,
    /// no access with the token there is, offline. Carries a line for the panel.
    case unavailable(String)

    var snapshot: GitHubIssueSnapshot? {
        if case .loaded(let snapshot) = self { return snapshot }
        return nil
    }
}

/// GitHub issues per repo, for the Issues panel and the issue badge on fleet
/// rows. All state lives on the main thread; the remote lookup and the
/// network run on a background queue and land back on main, which then posts
/// `didChange` so views re-ask.
///
/// A public repo is read anonymously when there is no token. A repo whose
/// issues cannot be read stays `.unavailable` and the chrome hides the Issues
/// icon for it; one that only needs a token (`.needsLogin`) keeps the icon so
/// the panel can say so.
final class GitHubIssueStore {
    static let shared = GitHubIssueStore()
    static let didChange = Notification.Name("seahelm.githubIssuesDidChange")

    /// A list this old is refetched the next time someone asks.
    static let freshFor: TimeInterval = 5 * 60
    static let anonymousFreshFor: TimeInterval = 15 * 60
    /// A failed lookup is retried sooner, so a token added later is noticed.
    static let retryAfter: TimeInterval = 60
    static let requestTimeout: TimeInterval = 10

    /// Set by `MainWindowController`, which owns the token sources.
    var resolveToken: (_ repoPath: String) -> String = { _ in "" }

    private enum RepoResolution {
        case pending
        case resolved(GitHubRepoRef?)
    }

    private var repoByWorktree: [String: RepoResolution] = [:]
    private var states: [GitHubRepoRef: (state: GitHubIssueListState, at: Date)] = [:]
    private var inFlight: Set<GitHubRepoRef> = []
    private let queue = DispatchQueue(label: "seahelm.github-issues", qos: .utility)

    /// Seam for tests: fetch without the network.
    var fetch: (_ repo: GitHubRepoRef, _ token: String) throws -> GitHubIssueSnapshot = GitHubIssueStore.fetchFromGitHub

    // MARK: - Main-thread API

    /// The GitHub repo a worktree's `origin` points at. Nil while that is
    /// being worked out (it is a `git` subprocess) and for non-GitHub repos;
    /// `didChange` fires once it is known.
    func repo(forWorktree path: String) -> GitHubRepoRef? {
        switch repoByWorktree[path] {
        case .resolved(let ref): return ref
        case .pending: return nil
        case nil:
            repoByWorktree[path] = .pending
            queue.async { [weak self] in
                let ref = Self.resolveRepo(worktreePath: path)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.repoByWorktree[path] = .resolved(ref)
                    if let ref { self.refreshIfStale(ref, tokenPath: path) }
                    NotificationCenter.default.post(name: Self.didChange, object: self)
                }
            }
            return nil
        }
    }

    func state(for repo: GitHubRepoRef) -> GitHubIssueListState? { states[repo]?.state }

    /// The state for a worktree's repo, kicking off a fetch if there is none
    /// yet or it has gone stale.
    func state(forWorktree path: String) -> GitHubIssueListState? {
        guard let ref = repo(forWorktree: path) else { return nil }
        refreshIfStale(ref, tokenPath: path)
        return states[ref]?.state
    }

    /// Whether the Issues icon should be offered for this worktree.
    func hasIssues(forWorktree path: String) -> Bool {
        switch state(forWorktree: path) {
        case .loaded?, .needsLogin?: return true
        case .loading?, .unavailable?, nil: return false
        }
    }

    func linkedIssues(worktreePath: String, branch: String) -> [GitHubIssue] {
        guard let ref = repo(forWorktree: worktreePath),
              let snapshot = states[ref]?.state.snapshot else { return [] }
        return snapshot.linkedIssues(branch: branch)
    }

    func refresh(worktreePath path: String) {
        guard let ref = repo(forWorktree: path) else { return }
        start(ref, tokenPath: path)
    }

    // MARK: - Fetching

    private func refreshIfStale(_ ref: GitHubRepoRef, tokenPath: String) {
        if let entry = states[ref] {
            let age = Date().timeIntervalSince(entry.at)
            switch entry.state {
            case .loading: return
            case .loaded(let snapshot):
                if age < (snapshot.isAnonymous ? Self.anonymousFreshFor : Self.freshFor) { return }
            // Retried soon, so signing in (or a fixed token) is picked up.
            case .needsLogin, .unavailable: if age < Self.retryAfter { return }
            }
        }
        start(ref, tokenPath: tokenPath)
    }

    private func start(_ ref: GitHubRepoRef, tokenPath: String) {
        guard inFlight.insert(ref).inserted else { return }
        // A refresh of a list already on screen keeps showing it.
        if states[ref]?.state.snapshot == nil {
            states[ref] = (.loading, Date())
        }
        let resolveToken = self.resolveToken
        let fetch = self.fetch
        queue.async { [weak self] in
            let token = resolveToken(tokenPath)
            let result: GitHubIssueListState
            do {
                result = .loaded(try fetch(ref, token))
            } catch {
                result = Self.state(after: error, hadToken: !token.isEmpty)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(ref)
                // A failed refresh does not throw away a list that worked.
                if case .unavailable = result, let previous = self.states[ref]?.state, previous.snapshot != nil {
                    self.states[ref] = (previous, Date())
                } else {
                    self.states[ref] = (result, Date())
                }
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
        }
    }

    private static func resolveRepo(worktreePath: String) -> GitHubRepoRef? {
        guard let url = GitProcess.run(["remote", "get-url", "origin"], in: worktreePath),
              let remote = GitRemote.parse(url),
              case .github(let owner, let repo) = remote.kind else { return nil }
        return GitHubRepoRef(owner: owner, repo: repo)
    }

    static func fetchFromGitHub(_ ref: GitHubRepoRef, token: String) throws -> GitHubIssueSnapshot {
        let service = GitHubPRService(token: token, owner: ref.owner, repo: ref.repo,
                                      requestTimeout: requestTimeout)
        let anonymous = token.isEmpty
        let issues = try GitHubReturnPRClient.awaitSync { try await service.listIssues() }
        // PR links are a bonus: a failure here still leaves the issue list.
        var params = GitHubPRListParams()
        params.state = "open"
        params.perPage = 100
        let prs = (try? GitHubReturnPRClient.awaitSync { try await service.listPRs(params: params) }) ?? []
        // `/user` needs a token; asking anonymously only spends the quota.
        let viewer = anonymous ? nil : try? GitHubReturnPRClient.awaitSync { try await service.currentUser() }
        return GitHubIssueSnapshot(issues: issues, closingByBranch: closingByBranch(prs), fetchedAt: Date(),
                                   viewerLogin: viewer?.login, isAnonymous: anonymous)
    }

    static func closingByBranch(_ prs: [GitHubPR]) -> [String: [Int]] {
        var result: [String: [Int]] = [:]
        for pr in prs {
            let numbers = IssueLink.closingIssueNumbers(inPRBody: pr.body ?? "")
            guard !numbers.isEmpty else { continue }
            result[pr.head.ref, default: []].append(contentsOf: numbers)
        }
        return result
    }

    /// Without a token, 404/401 is what a private repo looks like and 403 is
    /// the anonymous quota; a token cures both. With a token the same answers
    /// mean that token cannot see the repo, which signing in again would not fix.
    static func state(after error: Error, hadToken: Bool) -> GitHubIssueListState {
        guard !hadToken else { return .unavailable(describe(error)) }
        switch error as? GitHubAPIError {
        case .notFound?, .unauthorized?: return .needsLogin(.privateRepo)
        case .rateLimitExceeded?, .forbidden?: return .needsLogin(.anonymousLimit)
        default: return .unavailable(describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? GitHubAPIError {
        case .unauthorized?: return "GitHub token was refused"
        case .forbidden?: return "No access to this repo's issues"
        case .notFound?: return "Repo not found on GitHub"
        case .rateLimitExceeded?: return "GitHub rate limit reached"
        case .serverError(let status, _)? where status == 410: return "Issues are turned off for this repo"
        default: return "Could not reach GitHub"
        }
    }
}
