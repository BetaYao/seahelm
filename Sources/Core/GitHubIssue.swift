import Foundation

/// One issue from `GET /repos/{owner}/{repo}/issues`. That endpoint also
/// returns pull requests; they carry `pull_request` and are dropped by
/// `GitHubPRService.listIssues`.
struct GitHubIssue: Codable {
    let number: Int
    let title: String
    let body: String?
    let state: String           // "open", "closed"
    let htmlURL: String
    let user: GitHubUser
    let labels: [GitHubLabel]
    let assignees: [GitHubUser]?
    let comments: Int
    let createdAt: String
    let updatedAt: String
    let pullRequest: PullRequestMarker?

    /// Present only on a PR; its contents are not needed.
    struct PullRequestMarker: Codable {}

    var isPullRequest: Bool { pullRequest != nil }

    enum CodingKeys: String, CodingKey {
        case number, title, body, state, user, labels, assignees, comments
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }
}

/// Which issue a worktree is working on, read from what the work already says
/// about itself: its branch name, and the body of the PR opened from it.
/// Neither is authoritative on its own, so the store only shows a number that
/// turns out to be an open issue of the same repo.
enum IssueLink {
    /// `fix/123-crash`, `123-crash`, `issue-123`, `feat/gh-123-x`, `issues/123`.
    /// A bare number counts only at the start of a path segment and followed by
    /// `-`/`_` or the segment's end, so `release/2.0.74` and `v2` are not
    /// issues. A date-prefixed branch (`2026-10-cleanup`) does read as one; the
    /// store's open-issue check is what keeps that from showing.
    static func issueNumber(inBranch branch: String) -> Int? {
        for segment in branch.split(separator: "/").map(String.init) {
            if let n = firstMatch(segment, Self.leadingNumber) { return n }
            if let n = firstMatch(segment, Self.taggedNumber) { return n }
        }
        return nil
    }

    /// `Closes #12`, `fixes: #3`, `Resolved #40` — GitHub's own closing
    /// keywords, same-repo references only.
    static func closingIssueNumbers(inPRBody body: String) -> [Int] {
        let range = NSRange(body.startIndex..., in: body)
        var seen = Set<Int>()
        var numbers: [Int] = []
        for match in closingKeyword.matches(in: body, range: range) {
            guard let r = Range(match.range(at: 1), in: body), let n = Int(body[r]),
                  seen.insert(n).inserted else { continue }
            numbers.append(n)
        }
        return numbers
    }

    private static let leadingNumber = try! NSRegularExpression(pattern: #"^(\d{1,7})(?:[-_]|$)"#)
    private static let taggedNumber = try! NSRegularExpression(
        pattern: #"(?:^|[-_])(?:issues?|gh)[-_]?(\d{1,7})(?:[-_]|$)"#,
        options: .caseInsensitive
    )
    private static let closingKeyword = try! NSRegularExpression(
        pattern: #"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+#(\d{1,7})\b"#,
        options: .caseInsensitive
    )

    private static func firstMatch(_ text: String, _ regex: NSRegularExpression) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }
}

/// What the ▶ on an issue hands a new worktree: a branch named after the issue,
/// so `IssueLink` ties the two together, and an opening brief for its agent.
enum IssueStartBrief {
    /// Slugged by `WorktreeCreator` into `task/issue-123-<title…>`.
    static func branchHint(for issue: GitHubIssue) -> String {
        "issue \(issue.number) \(issue.title)"
    }

    /// First line doubles as the worktree's task title.
    static func task(for issue: GitHubIssue) -> String {
        var lines = ["#\(issue.number) \(issue.title)", "",
                     "Work on GitHub issue #\(issue.number): \(issue.htmlURL)"]
        let body = issue.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !body.isEmpty { lines += ["", body] }
        lines += ["", "When you open a PR for this, put `Closes #\(issue.number)` in its body."]
        return lines.joined(separator: "\n")
    }
}
