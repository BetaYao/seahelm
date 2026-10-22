import XCTest
@testable import seahelm

final class PaneForkTests: XCTestCase {
    func testExplicitWorktreeWins() {
        XCTAssertEqual(PaneFork.target(explicit: "/r/other", filedWorktree: "/r/main", hookWorktree: "/r/wt"),
                       "/r/other")
    }

    func testDefaultsToWhereTheAgentWent() {
        XCTAssertEqual(PaneFork.target(explicit: nil, filedWorktree: "/r/main", hookWorktree: "/r/wt"), "/r/wt")
    }

    func testNoTargetWhileTheAgentIsHome() {
        XCTAssertNil(PaneFork.target(explicit: nil, filedWorktree: "/r/main", hookWorktree: "/r/main"))
        XCTAssertNil(PaneFork.target(explicit: nil, filedWorktree: "/r/main", hookWorktree: "/r/main/"))
    }

    func testNoTargetWhenTheAgentIsOutsideAnyWorktree() {
        // A cwd that matches no tracked worktree arrives as a nil hook worktree.
        XCTAssertNil(PaneFork.target(explicit: nil, filedWorktree: "/r/main", hookWorktree: nil))
        XCTAssertNil(PaneFork.target(explicit: "", filedWorktree: "/r/main", hookWorktree: ""))
    }

    func testRouterRequiresPaneId() {
        let router = ControlRouter(dataSource: nil)
        guard case .error(let code, _) = router.handle(method: "pane.fork", params: [:]) else {
            return XCTFail("expected an error")
        }
        XCTAssertEqual(code, ControlError.invalidParams)
    }

    func testHeaderShowsForkOnlyWithATarget() {
        let header = TerminalHeaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 38))
        XCTAssertFalse(header.forkButtonIsVisibleForTesting)
        header.setForkTarget("@feature")
        XCTAssertTrue(header.forkButtonIsVisibleForTesting)
        header.setForkTarget(nil)
        XCTAssertFalse(header.forkButtonIsVisibleForTesting)
    }
}
