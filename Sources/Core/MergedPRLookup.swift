import Foundation

/// Merged PRs for a branch, from GitHub, so the Changes list can count only the
/// work after the last one. A squash merge leaves git no ancestry to find; the
/// PR's own head commit is the one record of exactly what went in.
///
/// Lookups run on the Changes panel's background queue and block it, so every
/// request has a short deadline and every answer is cached per repo, branch and
/// base — failures too, or an offline Mac would stall each reload. No GitHub
/// remote or no token means no request at all.
final class MergedPRLookup {
    static let shared = MergedPRLookup()

    /// A merged PR stays merged; this only bounds how late a newer one shows.
    static let hitTTL: TimeInterval = 10 * 60
    /// Short, so a PR merged a minute ago is picked up on the next reload.
    static let missTTL: TimeInterval = 60
    /// `gh auth token` and the keychain are subprocesses; do not ask per reload.
    static let tokenTTL: TimeInterval = 10 * 60
    static let requestTimeout: TimeInterval = 4

    /// Set by `MainWindowController`, which owns the token sources. Takes a
    /// repo path for the per-project ones (`.env`, git config).
    var resolveToken: (_ repoPath: String) -> String {
        get { lock.withLock { tokenResolver } }
        set { lock.withLock { tokenResolver = newValue } }
    }

    private let lock = NSLock()
    private var tokenResolver: (String) -> String = { _ in "" }
    private var token: (value: String, resolvedAt: Date)?
    private var cache: [String: (prs: [MergedPRHead], fetchedAt: Date)] = [:]

    func mergedPRs(worktreePath: String, branch: String, baseBranch: String) -> [MergedPRHead] {
        guard let url = GitProcess.run(["remote", "get-url", "origin"], in: worktreePath),
              let remote = GitRemote.parse(url),
              case .github(let owner, let repo) = remote.kind else { return [] }

        let key = "\(owner)/\(repo) \(branch) -> \(baseBranch)"
        let now = Date()
        if let cached = lock.withLock({ cache[key] }),
           now.timeIntervalSince(cached.fetchedAt) < (cached.prs.isEmpty ? Self.missTTL : Self.hitTTL) {
            return cached.prs
        }

        let token = currentToken(repoPath: worktreePath, now: now)
        var prs: [MergedPRHead] = []
        if !token.isEmpty {
            let service = GitHubPRService(token: token, owner: owner, repo: repo, requestTimeout: Self.requestTimeout)
            var params = GitHubPRListParams()
            params.state = "closed"
            params.head = "\(owner):\(branch)"
            params.base = baseBranch
            params.perPage = 20
            if let closed = try? GitHubReturnPRClient.awaitSync({ try await service.listPRs(params: params) }) {
                prs = Self.mergedHeads(closed)
            }
        }
        lock.withLock { cache[key] = (prs, now) }
        return prs
    }

    /// Closed-but-unmerged PRs dropped, newest merge first. GitHub's timestamps
    /// are ISO 8601 in UTC, so they order as strings.
    static func mergedHeads(_ prs: [GitHubPR]) -> [MergedPRHead] {
        prs.compactMap { pr in pr.mergedAt.map { (pr, $0) } }
            .sorted { $0.1 > $1.1 }
            .map { MergedPRHead(number: $0.0.number, headSHA: $0.0.head.sha) }
    }

    private func currentToken(repoPath: String, now: Date) -> String {
        if let token = lock.withLock({ token }), now.timeIntervalSince(token.resolvedAt) < Self.tokenTTL {
            return token.value
        }
        let value = resolveToken(repoPath)
        lock.withLock { token = (value, now) }
        return value
    }
}
