import XCTest
@testable import seahelm

final class GitHubIssueTests: XCTestCase {
    // MARK: - Branch names

    func testBranchNumberAtTheStartOfASegment() {
        XCTAssertEqual(IssueLink.issueNumber(inBranch: "fix/123-crash"), 123)
        XCTAssertEqual(IssueLink.issueNumber(inBranch: "123-crash"), 123)
        XCTAssertEqual(IssueLink.issueNumber(inBranch: "issues/45"), 45)
    }

    func testBranchNumberTaggedAnywhereInASegment() {
        XCTAssertEqual(IssueLink.issueNumber(inBranch: "feat/issue-77-panel"), 77)
        XCTAssertEqual(IssueLink.issueNumber(inBranch: "fix-gh-9"), 9)
        XCTAssertEqual(IssueLink.issueNumber(inBranch: "Issue_12"), 12)
    }

    func testVersionsAndPlainNamesAreNotIssues() {
        XCTAssertNil(IssueLink.issueNumber(inBranch: "release/2.0.74"))
        XCTAssertNil(IssueLink.issueNumber(inBranch: "v2"))
        XCTAssertNil(IssueLink.issueNumber(inBranch: "feat/auto-fork-on-worktree-move"))
        XCTAssertNil(IssueLink.issueNumber(inBranch: "main"))
    }

    // MARK: - PR bodies

    func testClosingKeywordsInAPRBody() {
        let body = "Fixes #12, and also\ncloses: #3. Resolved #12 again. See #99."
        XCTAssertEqual(IssueLink.closingIssueNumbers(inPRBody: body), [12, 3])
    }

    // MARK: - Decoding

    func testPullRequestsAreMarked() throws {
        let json = """
        [{"number":1,"title":"Bug","body":null,"state":"open","html_url":"u","user":{"login":"a","id":1},
          "labels":[],"comments":0,"created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-02T00:00:00Z"},
         {"number":2,"title":"PR","body":"","state":"open","html_url":"u","user":{"login":"a","id":1},
          "labels":[],"comments":0,"created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-02T00:00:00Z",
          "pull_request":{"url":"x"}}]
        """
        let items = try JSONDecoder().decode([GitHubIssue].self, from: Data(json.utf8))
        XCTAssertEqual(items.map(\.isPullRequest), [false, true])
    }

    // MARK: - Linking and the list

    private func issue(_ n: Int, _ title: String = "t", labels: [String] = []) -> GitHubIssue {
        GitHubIssue(number: n, title: title, body: nil, state: "open", htmlURL: "",
                    user: GitHubUser(login: "a", id: 1, avatarURL: nil, type: nil),
                    labels: labels.map { GitHubLabel(name: $0, color: "fff", description: nil) },
                    assignees: nil, comments: 0, createdAt: "", updatedAt: "", pullRequest: nil)
    }

    func testLinkedIssuesNeedAnOpenIssueAndIncludeThePRsClosingRefs() {
        let snapshot = GitHubIssueSnapshot(issues: [issue(5), issue(8)],
                                           closingByBranch: ["fix/5-x": [8, 404]], fetchedAt: Date())
        XCTAssertEqual(snapshot.linkedIssues(branch: "fix/5-x").map(\.number), [5, 8])
        XCTAssertEqual(snapshot.linkedIssues(branch: "2026-10-cleanup").map(\.number), [],
                       "a date prefix is not an issue unless one exists with that number")
    }

    func testRowsPutThisWorktreeFirstThenOthersThenTheRest() {
        let snapshot = GitHubIssueSnapshot(issues: [issue(1), issue(2), issue(3)],
                                           closingByBranch: [:], fetchedAt: Date())
        let rows = IssueListSections.rows(snapshot: snapshot, currentBranch: "fix/2-a",
                                          otherBranches: ["fix/2-a", "feat/3-b"])
        let shape: [String] = rows.map {
            switch $0 {
            case .group(let title): return title
            case .issue(let issue, let branch): return "#\(issue.number)@\(branch ?? "-")"
            }
        }
        XCTAssertEqual(shape, ["This worktree", "#2@fix/2-a", "In a worktree · 1", "#3@feat/3-b",
                               "Open · 1", "#1@-"])
    }

    func testAListWithNothingLinkedHasNoHeadings() {
        let snapshot = GitHubIssueSnapshot(issues: [issue(1), issue(2)], closingByBranch: [:], fetchedAt: Date())
        let rows = IssueListSections.rows(snapshot: snapshot, currentBranch: "main", otherBranches: [])
        XCTAssertEqual(rows.count, 2)
    }

    func testFilterMatchesNumberTitleAndLabel() {
        let snapshot = GitHubIssueSnapshot(issues: [issue(12, "Crash on launch"), issue(30, "Docs", labels: ["ui"])],
                                           closingByBranch: [:], fetchedAt: Date())
        func numbers(_ q: String) -> [Int] {
            IssueListSections.rows(snapshot: snapshot, currentBranch: nil, otherBranches: [], filter: q)
                .compactMap { if case .issue(let i, _) = $0 { return i.number } else { return nil } }
        }
        XCTAssertEqual(numbers("#12"), [12])
        XCTAssertEqual(numbers("crash"), [12])
        XCTAssertEqual(numbers("UI"), [30])
    }

    // MARK: - Scope

    private func issue(_ n: Int, by author: String, assignees: [String]) -> GitHubIssue {
        GitHubIssue(number: n, title: "t", body: nil, state: "open", htmlURL: "",
                    user: GitHubUser(login: author, id: 1, avatarURL: nil, type: nil), labels: [],
                    assignees: assignees.map { GitHubUser(login: $0, id: 2, avatarURL: nil, type: nil) },
                    comments: 0, createdAt: "", updatedAt: "", pullRequest: nil)
    }

    func testScopeCreatedAndAssignedFollowTheViewer() {
        let snapshot = GitHubIssueSnapshot(
            issues: [issue(1, by: "me", assignees: []), issue(2, by: "bob", assignees: ["Me"]),
                     issue(3, by: "bob", assignees: ["alice"])],
            closingByBranch: [:], fetchedAt: Date(), viewerLogin: "me")
        func numbers(_ scope: IssueScope) -> [Int] {
            IssueListSections.rows(snapshot: snapshot, currentBranch: nil, otherBranches: [], scope: scope)
                .compactMap { if case .issue(let i, _) = $0 { return i.number } else { return nil } }
        }
        XCTAssertEqual(numbers(.all), [1, 2, 3])
        XCTAssertEqual(numbers(.created), [1])
        XCTAssertEqual(numbers(.assigned), [2])
    }

    func testScopeWithoutAViewerShowsNothingButAll() {
        XCTAssertFalse(IssueScope.created.includes(issue(1, by: "me", assignees: ["me"]), viewer: nil))
        XCTAssertTrue(IssueScope.all.includes(issue(1, by: "me", assignees: []), viewer: nil))
    }

    // MARK: - Starting an issue

    func testStartBranchCarriesTheIssueNumber() {
        let hint = IssueStartBrief.branchHint(for: issue(42, "Crash on launch"))
        let branch = WorktreeCreator.branchName(fromTaskDescription: hint)
        XCTAssertEqual(IssueLink.issueNumber(inBranch: branch), 42, branch)
    }

    func testStartBriefLeadsWithTheIssue() {
        let brief = IssueStartBrief.task(for: issue(42, "Crash on launch"))
        XCTAssertEqual(brief.components(separatedBy: "\n").first, "#42 Crash on launch")
        XCTAssertTrue(brief.contains("Closes #42"))
    }

    // MARK: - Without a token

    func testNoTokenAnd404MeansSignInNotGiveUp() {
        guard case .needsLogin(.privateRepo) = GitHubIssueStore.state(after: GitHubAPIError.notFound,
                                                                     hadToken: false) else {
            return XCTFail("a private repo read anonymously should ask for a login")
        }
        guard case .unavailable = GitHubIssueStore.state(after: GitHubAPIError.notFound, hadToken: true) else {
            return XCTFail("a token that cannot see the repo is not fixed by signing in")
        }
        guard case .needsLogin(.anonymousLimit) = GitHubIssueStore.state(
            after: GitHubAPIError.rateLimitExceeded(resetAt: ""), hadToken: false) else {
            return XCTFail("a spent anonymous quota is cured by a token")
        }
        guard case .unavailable = GitHubIssueStore.state(
            after: GitHubAPIError.rateLimitExceeded(resetAt: ""), hadToken: true) else {
            return XCTFail("a token's own limit is not a login problem")
        }
    }
}
