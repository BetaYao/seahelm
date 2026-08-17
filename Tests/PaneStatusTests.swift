import XCTest
@testable import seahelm

final class PaneStatusTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func pane(_ index: Int, _ id: String, _ status: AgentStatus,
                      message: String = "", changedAt: Date,
                      agentType: AgentType = .unknown) -> PaneStatus {
        PaneStatus(paneIndex: index, terminalID: id, status: status, lastMessage: message,
                   lastUserPrompt: "", lastUpdated: changedAt, statusChangedAt: changedAt,
                   agentType: agentType)
    }

    private func worktree(_ panes: [PaneStatus]) -> WorktreeStatus {
        WorktreeStatus(worktreePath: "/repo/main", panes: panes, mostRecentPaneIndex: 1,
                    mostRecentMessage: "", mostRecentUserPrompt: "")
    }

    func testStatusesFollowLeafOrder() {
        let ws = worktree([
            pane(1, "t1", .running, changedAt: t0),
            pane(2, "t2", .idle, changedAt: t0),
        ])
        XCTAssertEqual(ws.statuses, [.running, .idle])
    }

    // MARK: - Rollup: most recently changed pane

    func testRepresentativeIsTheMostRecentlyChangedPane() {
        let ws = worktree([
            pane(1, "old", .waiting, changedAt: t0),
            pane(2, "new", .running, changedAt: t0.addingTimeInterval(60)),
        ])
        XCTAssertEqual(ws.representative?.paneIndex, 2)
        XCTAssertEqual(ws.rolledUpStatus, .running)
    }

    /// Deliberate change of behaviour: the rollup used to rank an AI agent's
    /// state above a shell task's, so a blocked agent held the badge against a
    /// long-running `npm run dev`. Recency replaced that — the shell pane wins
    /// here purely because it changed later.
    func testABusyShellCanNowOutrankAWaitingAgent() {
        let ws = worktree([
            pane(1, "agent", .waiting, changedAt: t0, agentType: .claudeCode),
            pane(2, "shell", .running, changedAt: t0.addingTimeInterval(1), agentType: .npm),
        ])
        XCTAssertEqual(ws.rolledUpStatus, .running)
    }

    /// The badge and the text must describe the same pane, or the row reads as
    /// one pane's status next to another pane's output.
    func testStatusAndMessageComeFromTheSamePane() {
        let ws = worktree([
            pane(1, "a", .idle, message: "idle msg", changedAt: t0),
            pane(2, "b", .error, message: "boom", changedAt: t0.addingTimeInterval(5)),
        ])
        XCTAssertEqual(ws.representative?.status, .error)
        XCTAssertEqual(ws.representative?.lastMessage, "boom")
    }

    /// `statusChangedAt` exists so output churn cannot steal the badge: pane 1
    /// is printing constantly (`lastUpdated` is newest) but its status has not
    /// moved since t0, so pane 2's later status change still speaks.
    func testMessageOnlyUpdatesDoNotStealTheBadge() {
        let chatty = PaneStatus(paneIndex: 1, terminalID: "chatty", status: .running,
                                lastMessage: "line 900", lastUserPrompt: "",
                                lastUpdated: t0.addingTimeInterval(300),
                                statusChangedAt: t0)
        let ws = worktree([chatty, pane(2, "b", .waiting, changedAt: t0.addingTimeInterval(10))])
        XCTAssertEqual(ws.rolledUpStatus, .waiting)
        XCTAssertEqual(ws.representative?.paneIndex, 2)
    }

    func testEmptyWorktreeHasUnknownStatus() {
        XCTAssertEqual(worktree([]).rolledUpStatus, .unknown)
    }

    // MARK: - Urgency is independent of the rollup

    /// `hasUrgent` still scans every pane, so an error stays visible even when a
    /// later-changed pane owns the badge.
    func testHasUrgentSeesAPaneTheRollupDidNotPick() {
        let ws = worktree([
            pane(1, "t1", .error, message: "failed", changedAt: t0),
            pane(2, "t2", .running, changedAt: t0.addingTimeInterval(60)),
        ])
        XCTAssertEqual(ws.rolledUpStatus, .running)
        XCTAssertTrue(ws.hasUrgent)
    }

    func testNotUrgentWhenNoPaneIs() {
        XCTAssertFalse(worktree([pane(1, "t1", .running, changedAt: t0)]).hasUrgent)
    }

    func testSinglePaneWorktree() {
        let ws = worktree([pane(1, "t1", .running, message: "working", changedAt: t0)])
        XCTAssertEqual(ws.statuses.count, 1)
        XCTAssertEqual(ws.rolledUpStatus, .running)
        XCTAssertFalse(ws.hasUrgent)
    }
}
