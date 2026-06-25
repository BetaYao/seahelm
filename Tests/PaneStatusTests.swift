import XCTest
@testable import seahelm

final class PaneStatusTests: XCTestCase {

    func testWorktreeStatusStatuses() {
        let ws = WorktreeStatus(
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

    func testWorktreeStatusHasUrgent() {
        let ws = WorktreeStatus(
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
        let ws = WorktreeStatus(
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
        let ws = WorktreeStatus(
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
        let ws = WorktreeStatus(
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
