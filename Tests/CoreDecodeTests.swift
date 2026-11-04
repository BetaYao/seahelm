import XCTest
@testable import seahelm

/// seahelm-core's pane detail read into the app's types, in the shape the
/// core's tests pin (core-registry tests/unseen_and_events.rs).
final class CoreDecodeTests: XCTestCase {
    func testPaneInfoLaysOverTheAppsSnapshot() {
        var p = PaneInfo(id: "t1", worktreePath: "/wt", agentType: .unknown, project: "p", branch: "b",
                         status: .idle, lastMessage: "", commandLine: "old", roundDuration: 0,
                         startedAt: nil, station: nil, channel: nil, taskProgress: TaskProgress())
        CoreDecode.apply([
            "status": "Running", "agent_type": "claudeCode", "last_message": "Bash ls",
            "last_user_prompt": "go", "last_user_prompt_at": 5.0, "command_line": NSNull(),
            "round_duration": 3.5, "tasks": [["id": "1", "subject": "x", "status": "in_progress"]],
            "activity_events": [], "scan_status": "Idle", "hook_status": "Running",
            "program_status": "Unknown", "program_state": NSNull(), "background_busy": true,
        ], to: &p)
        XCTAssertEqual(p.status, .running)
        XCTAssertEqual(p.agentType, .claudeCode)
        XCTAssertEqual(p.lastUserPrompt, "go")
        XCTAssertEqual(p.lastUserPromptAt, Date(timeIntervalSince1970: 5))
        XCTAssertNil(p.commandLine)
        XCTAssertEqual(p.tasks.first?.status, .inProgress)
        XCTAssertEqual(p.hookStatus, .running)
        XCTAssertTrue(p.backgroundBusy)
        // The app's own: identity and where it is filed.
        XCTAssertEqual(p.id, "t1")
        XCTAssertEqual(p.worktreePath, "/wt")
    }

    /// `pane.unseen_changed` carries one field: the rest stays as it was.
    func testOnlyTheGivenFieldsChange() {
        var p = PaneInfo(id: "t1", worktreePath: "/wt", agentType: .claudeCode, project: "p", branch: "b",
                         status: .running, lastMessage: "Bash ls", commandLine: "ls", roundDuration: 4,
                         startedAt: nil, station: nil, channel: nil, taskProgress: TaskProgress())
        CoreDecode.apply(["unseen": true], to: &p)
        XCTAssertTrue(p.unseenCompletion)
        XCTAssertEqual(p.status, .running)
        XCTAssertEqual(p.commandLine, "ls")
        XCTAssertEqual(p.lastMessage, "Bash ls")
    }
}
