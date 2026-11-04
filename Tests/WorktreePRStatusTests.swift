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

    func testReadsTheCoresPR() {
        let pr = WorktreePRStatus(dict: ["number": 12, "url": "u", "state": "open", "checks": "failing",
                                         "review": "changes_requested"])
        XCTAssertEqual(pr?.number, 12)
        XCTAssertEqual(pr?.checks, .failing)
        XCTAssertEqual(pr?.review, .changesRequested)
        XCTAssertNil(WorktreePRStatus(dict: ["number": 1, "state": "weird"]))
    }
}
