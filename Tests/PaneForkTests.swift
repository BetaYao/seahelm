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

    // MARK: - Auto-fork

    func testAutoForksIntoAWorktreeElsewhere() {
        XCTAssertTrue(PaneFork.shouldAutoFork(enabled: true, filedWorktree: "/r/repo",
                                              destination: "/r/repo-feature", alreadyForked: false))
    }

    func testDoesNotAutoForkIntoItsOwnWorktreeTwiceOrWhenDisabled() {
        XCTAssertFalse(PaneFork.shouldAutoFork(enabled: true, filedWorktree: "/r/repo-feature/",
                                               destination: "/r/repo-feature", alreadyForked: false))
        XCTAssertFalse(PaneFork.shouldAutoFork(enabled: true, filedWorktree: "/r/repo",
                                               destination: "/r/repo-feature", alreadyForked: true))
        XCTAssertFalse(PaneFork.shouldAutoFork(enabled: false, filedWorktree: "/r/repo",
                                               destination: "/r/repo-feature", alreadyForked: false))
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

    func testForkIsNamedAfterItsDestination() {
        XCTAssertEqual(PaneFork.sessionName(branch: "task/issue-12-fix", worktreePath: "/r/wt2"),
                       "task/issue-12-fix")
        // Detached HEAD: no branch, so the directory names it.
        XCTAssertEqual(PaneFork.sessionName(branch: " ", worktreePath: "/r/wt2"), "wt2")
        XCTAssertEqual(PaneFork.sessionName(branch: String(repeating: "x", count: 200),
                                            worktreePath: "/r/wt2").count, 80)
    }

    // MARK: - Telling the original pane

    func testOriginNoticeNamesTheForkAndSaysTheUserDidNotStopIt() {
        let notice = PaneFork.originNotice(handle: 12, destinationName: "@feat/x",
                                           destinationPath: "/r/repo-x")
        XCTAssertTrue(notice.hasPrefix("[seahelm] "), notice)
        XCTAssertTrue(notice.contains("pane #12"), notice)
        XCTAssertTrue(notice.contains("@feat/x"), notice)
        XCTAssertTrue(notice.contains("/r/repo-x"), notice)
        XCTAssertTrue(notice.contains("not by the user"), notice)
        XCTAssertTrue(notice.contains("Do not continue"), notice)
        // Typed into a TUI and submitted with Return: one line.
        XCTAssertFalse(notice.contains("\n"), notice)
    }

    /// seahelm-core numbers a pane only once it has listed it; a fork that new
    /// is named by its worktree instead.
    func testOriginNoticeWithoutAHandleNamesTheWorktree() {
        let notice = PaneFork.originNotice(handle: nil, destinationName: "@feat/x",
                                           destinationPath: "/r/repo-x")
        XCTAssertFalse(notice.contains("#"), notice)
        XCTAssertTrue(notice.contains("the pane in @feat/x"), notice)
        XCTAssertEqual(PaneFork.badgeTitle(handle: nil), "")
        XCTAssertFalse(PaneFork.badgeToolTip(handle: nil, destinationName: "@feat/x").contains("#"))
    }

    /// The notice waits for the fork to be up and the interrupted turn to end,
    /// then goes anyway.
    func testNoticeWaitsForTheForkAndTheTurnButNotForever() {
        XCTAssertFalse(PaneFork.noticeIsDue(originStatus: .running, forkReady: true, waited: 0))
        XCTAssertFalse(PaneFork.noticeIsDue(originStatus: nil, forkReady: true, waited: 1))
        // Origin idle but the fork has not read its transcript yet: hold, or
        // the notice is copied into the fork's own history.
        XCTAssertFalse(PaneFork.noticeIsDue(originStatus: .idle, forkReady: false, waited: 0))
        XCTAssertTrue(PaneFork.noticeIsDue(originStatus: .idle, forkReady: true, waited: 0))
        XCTAssertTrue(PaneFork.noticeIsDue(originStatus: .waiting, forkReady: true, waited: 0))
        XCTAssertTrue(PaneFork.noticeIsDue(originStatus: .running, forkReady: true, waited: PaneFork.noticeMaxWait))
        XCTAssertTrue(PaneFork.noticeIsDue(originStatus: nil, forkReady: true, waited: PaneFork.noticeMaxWait))
        // A fork that has not started is waited on much longer than the turn.
        XCTAssertFalse(PaneFork.noticeIsDue(originStatus: .idle, forkReady: false, waited: PaneFork.noticeMaxWait))
        XCTAssertTrue(PaneFork.noticeIsDue(originStatus: .idle, forkReady: false, waited: PaneFork.forkReadyMaxWait))
    }

    func testForkIsReadyOnceCoreSeesClaudeAndNumbersIt() {
        XCTAssertTrue(PaneFork.forkIsReady(agentType: .claudeCode, status: .idle, handle: 4))
        XCTAssertTrue(PaneFork.forkIsReady(agentType: .claudeCode, status: .running, handle: 4))
        XCTAssertFalse(PaneFork.forkIsReady(agentType: .claudeCode, status: .idle, handle: nil))
        XCTAssertFalse(PaneFork.forkIsReady(agentType: .claudeCode, status: .unknown, handle: 4))
        XCTAssertFalse(PaneFork.forkIsReady(agentType: .unknown, status: .idle, handle: 4))
        XCTAssertFalse(PaneFork.forkIsReady(agentType: nil, status: nil, handle: nil))
    }

    func testHeaderShowsForkedBadgeOnlyWhileSet() {
        let header = TerminalHeaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 38))
        XCTAssertFalse(header.forkedBadgeIsVisibleForTesting)
        header.setForkedInto(title: PaneFork.badgeTitle(handle: 7),
                             toolTip: PaneFork.badgeToolTip(handle: 7, destinationName: "@feat/x"))
        XCTAssertTrue(header.forkedBadgeIsVisibleForTesting)
        XCTAssertEqual(header.forkedBadgeTitleForTesting, "#7")
        header.setFirstMateMode(true)
        XCTAssertFalse(header.forkedBadgeIsVisibleForTesting, "First Mate's header has no pane to badge")
        header.setFirstMateMode(false)
        header.setForkedInto(title: nil, toolTip: nil)
        XCTAssertFalse(header.forkedBadgeIsVisibleForTesting)
    }
}
