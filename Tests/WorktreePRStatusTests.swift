import XCTest
@testable import seahelm

final class WorktreePRStatusTests: XCTestCase {
    private func node(_ number: Int, branch: String, state: String = "OPEN", draft: Bool = false,
                      owner: String = "acme", review: String? = nil, rollup: String? = nil) -> [String: Any] {
        var commit: [String: Any] = [:]
        if let rollup { commit["statusCheckRollup"] = ["state": rollup] }
        var n: [String: Any] = [
            "number": number, "url": "https://github.com/acme/app/pull/\(number)",
            "state": state, "isDraft": draft, "headRefName": branch,
            "headRepositoryOwner": ["login": owner],
            "commits": ["nodes": [["commit": commit]]],
        ]
        if let review { n["reviewDecision"] = review }
        return n
    }

    private func response(_ nodes: [[String: Any]]) -> [String: Any] {
        ["data": ["repository": ["pullRequests": ["nodes": nodes]]]]
    }

    // MARK: - parsing

    func testReadsStateChecksAndReview() {
        let byBranch = WorktreePRStatusParser.statuses(from: response([
            node(12, branch: "feat/a", review: "APPROVED", rollup: "SUCCESS"),
            node(13, branch: "feat/b", draft: true, rollup: "PENDING"),
            node(14, branch: "feat/c", review: "CHANGES_REQUESTED", rollup: "ERROR"),
            node(15, branch: "feat/d", state: "MERGED"),
        ]), owner: "acme")
        XCTAssertEqual(byBranch["feat/a"], WorktreePRStatus(number: 12, url: "https://github.com/acme/app/pull/12",
                                                           state: .open, checks: .passing, review: .approved))
        XCTAssertEqual(byBranch["feat/b"]?.state, .draft)
        XCTAssertEqual(byBranch["feat/b"]?.checks, .pending)
        XCTAssertEqual(byBranch["feat/c"]?.checks, .failing, "ERROR is a failed check")
        XCTAssertEqual(byBranch["feat/c"]?.review, .changesRequested)
        XCTAssertEqual(byBranch["feat/d"]?.state, .merged)
        XCTAssertNil(byBranch["feat/d"]?.checks)
    }

    /// Nodes come newest-updated first; a branch reopened as a new PR is that one.
    func testNewestPRForABranchWins() {
        let byBranch = WorktreePRStatusParser.statuses(from: response([
            node(20, branch: "fix"), node(9, branch: "fix", state: "CLOSED"),
        ]), owner: "acme")
        XCTAssertEqual(byBranch["fix"]?.number, 20)
    }

    func testForkPRsAreNotThisRepositorysBranches() {
        let byBranch = WorktreePRStatusParser.statuses(from: response([
            node(30, branch: "main", owner: "someone-else"), node(31, branch: "fix", owner: "ACME"),
        ]), owner: "acme")
        XCTAssertNil(byBranch["main"])
        XCTAssertEqual(byBranch["fix"]?.number, 31, "owner match ignores case")
    }

    func testEmptyOrErrorAnswerIsNothing() {
        XCTAssertTrue(WorktreePRStatusParser.statuses(from: ["errors": [["message": "x"]]], owner: "acme").isEmpty)
    }

    // MARK: - wire and words

    func testWireDropsChecksAndReviewOnceThePRIsDone() {
        let merged = WorktreePRStatus(number: 1, url: "u", state: .merged, checks: .failing, review: .approved)
        XCTAssertNil(merged.dict["checks"])
        XCTAssertNil(merged.dict["review"])
        XCTAssertEqual(merged.dict["state"] as? String, "merged")
        let open = WorktreePRStatus(number: 2, url: "u", state: .open, checks: .failing, review: nil)
        XCTAssertEqual(open.dict["checks"] as? String, "failing")
        XCTAssertEqual(open.summary, "PR #2 · open · checks failing")
    }

    // MARK: - the store

    func testStoreFetchesOncePerRepoAndServesEveryBranch() {
        let fetched = expectation(description: "fetched")
        var calls = 0
        let store = WorktreePRStore(
            fetch: { owner, repo, _ in
                calls += 1
                XCTAssertEqual("\(owner)/\(repo)", "acme/app")
                return ["feat/a": WorktreePRStatus(number: 1, url: "u", state: .open, checks: .passing, review: nil)]
            },
            resolveRemote: { _ in "acme/app" })
        store.resolveToken = { _ in "token" }
        store.onChange = { fetched.fulfill() }
        store.refresh(worktreePath: "/wt/a")
        wait(for: [fetched], timeout: 2)
        store.refresh(worktreePath: "/wt/a")
        XCTAssertEqual(store.status(worktreePath: "/wt/a", branch: "feat/a")?.number, 1)
        XCTAssertNil(store.status(worktreePath: "/wt/a", branch: "other"))
        XCTAssertEqual(calls, 1, "fresh for a minute")
    }

    func testNoTokenNoRequest() {
        let settled = expectation(description: "settled")
        settled.isInverted = true
        let store = WorktreePRStore(fetch: { _, _, _ in XCTFail("asked GitHub without a token"); return [:] },
                                    resolveRemote: { _ in "acme/app" })
        store.onChange = { settled.fulfill() }
        store.refresh(worktreePath: "/wt/a")
        wait(for: [settled], timeout: 0.5)
    }

    func testNotOnGitHubIsNeverFetched() {
        let settled = expectation(description: "settled")
        settled.isInverted = true
        let store = WorktreePRStore(fetch: { _, _, _ in XCTFail("fetched a non-GitHub repo"); return [:] },
                                    resolveRemote: { _ in "" })
        store.resolveToken = { _ in "token" }
        store.onChange = { settled.fulfill() }
        store.refresh(worktreePath: "/wt/a")
        wait(for: [settled], timeout: 0.5)
        XCTAssertNil(store.status(worktreePath: "/wt/a", branch: "x"))
    }

    // MARK: - the row

    func testRowBadgeReadsLikeTheSummary() {
        func text(_ pr: WorktreePRStatus) -> String { DashboardOverviewView.prAttributed(pr).string }
        XCTAssertEqual(text(.init(number: 12, url: "u", state: .open, checks: .passing, review: .approved)),
                       "#12 \u{2713} approved")
        XCTAssertEqual(text(.init(number: 3, url: "u", state: .draft, checks: .failing, review: nil)),
                       "#3 draft \u{2715}")
        XCTAssertEqual(text(.init(number: 4, url: "u", state: .merged, checks: .passing, review: .approved)),
                       "#4 merged")
        XCTAssertEqual(text(.init(number: 5, url: "u", state: .open, checks: nil, review: .reviewRequired)), "#5")
    }
}
