import XCTest
@testable import seahelm

final class PaneStatusTests: XCTestCase {

    func testWorktreeStatusStatuses() {
        let ws = CabinStatus(
            worktreePath: "/repo/main",
            panes: [
                PaneStatus(paneIndex: 1, terminalID: "t1", status: .running, lastMessage: "building", lastUserPrompt: "", lastUpdated: Date()),
                PaneStatus(paneIndex: 2, terminalID: "t2", status: .idle, lastMessage: "done", lastUserPrompt: "", lastUpdated: Date()),
            ],
            mostRecentPaneIndex: 1,
            mostRecentMessage: "building",
            mostRecentUserPrompt: ""
        )
        XCTAssertEqual(ws.statuses, [.running, .idle])
    }

    func testRepresentativeIsAgentOverBusyShell() {
        // Shell pane (npm) running forever must not mask a blocked AI agent.
        let ws = CabinStatus(
            worktreePath: "/repo/main",
            panes: [
                PaneStatus(paneIndex: 1, terminalID: "shell", status: .running, lastMessage: "webpack…",
                           lastUserPrompt: "", lastUpdated: Date(), agentType: .npm),
                PaneStatus(paneIndex: 2, terminalID: "agent", status: .waiting, lastMessage: "approve?",
                           lastUserPrompt: "", lastUpdated: Date(), agentType: .claudeCode),
            ],
            mostRecentPaneIndex: 1, mostRecentMessage: "webpack…", mostRecentUserPrompt: ""
        )
        XCTAssertEqual(ws.highestPriority, .waiting)
        XCTAssertEqual(ws.representative?.paneIndex, 2)
    }

    func testRepresentativeStatusAndMessageSamePane() {
        // Higher-priority pane owns both the badge status and the message.
        let ws = CabinStatus(
            worktreePath: "/repo/main",
            panes: [
                PaneStatus(paneIndex: 1, terminalID: "a", status: .idle, lastMessage: "idle msg",
                           lastUserPrompt: "", lastUpdated: Date(), agentType: .claudeCode),
                PaneStatus(paneIndex: 2, terminalID: "b", status: .error, lastMessage: "boom",
                           lastUserPrompt: "", lastUpdated: Date(), agentType: .claudeCode),
            ],
            mostRecentPaneIndex: 1, mostRecentMessage: "idle msg", mostRecentUserPrompt: ""
        )
        XCTAssertEqual(ws.representative?.status, .error)
        XCTAssertEqual(ws.representative?.lastMessage, "boom")
    }

    func testWorktreeStatusHasUrgent() {
        let ws = CabinStatus(
            worktreePath: "/repo/main",
            panes: [
                PaneStatus(paneIndex: 1, terminalID: "t1", status: .running, lastMessage: "", lastUserPrompt: "", lastUpdated: Date()),
                PaneStatus(paneIndex: 2, terminalID: "t2", status: .error, lastMessage: "failed", lastUserPrompt: "", lastUpdated: Date()),
            ],
            mostRecentPaneIndex: 2,
            mostRecentMessage: "failed",
            mostRecentUserPrompt: ""
        )
        XCTAssertTrue(ws.hasUrgent)
    }

    func testWorktreeStatusNotUrgent() {
        let ws = CabinStatus(
            worktreePath: "/repo/main",
            panes: [
                PaneStatus(paneIndex: 1, terminalID: "t1", status: .running, lastMessage: "", lastUserPrompt: "", lastUpdated: Date()),
            ],
            mostRecentPaneIndex: 1,
            mostRecentMessage: "",
            mostRecentUserPrompt: ""
        )
        XCTAssertFalse(ws.hasUrgent)
    }

    func testWorktreeStatusHighestPriority() {
        let ws = CabinStatus(
            worktreePath: "/repo/main",
            panes: [
                PaneStatus(paneIndex: 1, terminalID: "t1", status: .idle, lastMessage: "", lastUserPrompt: "", lastUpdated: Date()),
                PaneStatus(paneIndex: 2, terminalID: "t2", status: .waiting, lastMessage: "?", lastUserPrompt: "", lastUpdated: Date()),
                PaneStatus(paneIndex: 3, terminalID: "t3", status: .running, lastMessage: "", lastUserPrompt: "", lastUpdated: Date()),
            ],
            mostRecentPaneIndex: 2,
            mostRecentMessage: "?",
            mostRecentUserPrompt: ""
        )
        XCTAssertEqual(ws.highestPriority, .waiting)
    }

    func testSinglePaneWorktreeStatus() {
        let ws = CabinStatus(
            worktreePath: "/repo/main",
            panes: [
                PaneStatus(paneIndex: 1, terminalID: "t1", status: .running, lastMessage: "working", lastUserPrompt: "", lastUpdated: Date()),
            ],
            mostRecentPaneIndex: 1,
            mostRecentMessage: "working",
            mostRecentUserPrompt: ""
        )
        XCTAssertEqual(ws.statuses.count, 1)
        XCTAssertEqual(ws.highestPriority, .running)
        XCTAssertFalse(ws.hasUrgent)
    }
}
