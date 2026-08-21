import XCTest
@testable import seahelm

/// The two axes a pane reports on, and the one place they are recombined.
///
/// `status` answers "what is the agent doing" — it drives edges, First Mate and
/// notifications. `backgroundBusy` answers "does this session have work of its
/// own running" — a shell it launched, a monitor it watches. Folding the second
/// into the first is what pinned a pane parked at an empty prompt on `running`
/// for the life of its monitor, costing it every completion notification.
/// `displayStatus` puts them back together for the dashboard only.
final class PaneInfoDisplayStatusTests: XCTestCase {
    private func pane(status: AgentStatus, backgroundBusy: Bool) -> PaneInfo {
        var info = PaneInfo(id: "t1", worktreePath: "/wt", agentType: .claudeCode,
                            project: "proj", branch: "main", status: status,
                            lastMessage: "", commandLine: nil, roundDuration: 0,
                            startedAt: nil, station: nil, channel: nil,
                            taskProgress: TaskProgress())
        info.backgroundBusy = backgroundBusy
        return info
    }

    func testIdleWithBackgroundWorkStillDrawsAsBusy() {
        XCTAssertEqual(pane(status: .idle, backgroundBusy: true).displayStatus, .running,
                       "a worktree watching CI is not done")
    }

    func testTheStatusAxisItselfStaysHonest() {
        XCTAssertEqual(pane(status: .idle, backgroundBusy: true).status, .idle,
                       "this is the value the running -> idle edge is computed from")
    }

    func testIdleWithoutBackgroundWorkDrawsAsIdle() {
        XCTAssertEqual(pane(status: .idle, backgroundBusy: false).displayStatus, .idle)
    }

    /// Background work never upgrades or masks a state that needs the user.
    func testUrgentStatesAreUntouched() {
        XCTAssertEqual(pane(status: .waiting, backgroundBusy: true).displayStatus, .waiting)
        XCTAssertEqual(pane(status: .error, backgroundBusy: true).displayStatus, .error)
        XCTAssertEqual(pane(status: .exited, backgroundBusy: true).displayStatus, .exited)
    }

    func testPaneStatusMirrorsTheSameRule() {
        var ps = PaneStatus(paneIndex: 1, terminalID: "t1", status: .idle, lastMessage: "",
                            lastUserPrompt: "", lastUpdated: Date(), statusChangedAt: Date())
        ps.backgroundBusy = true
        XCTAssertEqual(ps.displayStatus, .running)
        XCTAssertEqual(ps.status, .idle)
    }

    /// The worktree badge follows the same rule as its panes, so the card and the
    /// dots can never disagree.
    func testWorktreeRollupUsesDisplayStatus() {
        var ps = PaneStatus(paneIndex: 1, terminalID: "t1", status: .idle, lastMessage: "",
                            lastUserPrompt: "", lastUpdated: Date(), statusChangedAt: Date())
        ps.backgroundBusy = true
        let ws = WorktreeStatus(worktreePath: "/wt", panes: [ps], mostRecentPaneIndex: 1,
                                mostRecentMessage: "", mostRecentUserPrompt: "")
        XCTAssertEqual(ws.rolledUpStatus, .running)
    }
}
