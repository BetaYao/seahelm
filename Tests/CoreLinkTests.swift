import XCTest
@testable import seahelm

/// The app follows seahelm-core for handles and for sessions the core started.
final class CoreLinkTests: XCTestCase {
    func testReadsHandlesAndSessionsTheAppHasNoPaneOn() {
        let rows: [[String: Any]] = [
            ["pane_session_key": "seahelm-repo-main", "worktree_path": "/r", "handle": 3],
            ["pane_session_key": "gpui-add-a-readme-1234", "worktree_path": "/r-wt/task/add-a-readme", "handle": 9],
            ["pane_session_key": "seahelm-first-mate", "worktree_path": "/fm"],
        ]
        let (handles, adoptable) = CoreLink.read(rows, appSessions: ["seahelm-repo-main"])
        XCTAssertEqual(handles, ["seahelm-repo-main": 3, "gpui-add-a-readme-1234": 9])
        XCTAssertEqual(adoptable["/r-wt/task/add-a-readme"], "gpui-add-a-readme-1234")
        XCTAssertNil(adoptable["/r"], "the app's own pane is not up for adoption")
    }

    func testThePresencePillNamesTheCoresHandle() {
        XCTAssertEqual(SeahelmControlDataSource.actorName(agent: "Claude Code", handle: 7), "Claude Code #7")
        XCTAssertEqual(SeahelmControlDataSource.actorName(agent: nil, handle: 3), "Pane #3")
        XCTAssertEqual(SeahelmControlDataSource.actorName(agent: "Codex", handle: nil), "Codex",
                       "a pane the core has not numbered yet goes without")
        XCTAssertNil(CoreLink.shared.handle(forSession: ""))
        XCTAssertNil(CoreLink.shared.handle(forSession: nil))
    }
}
