import XCTest
@testable import seahelm

/// seahelm-core's pane events read back into the app's types, from the
/// shapes the core's tests pin (core-registry tests/unseen_and_events.rs).
final class CoreDecodeTests: XCTestCase {
    func testSourcesAndKinds() {
        guard case .hook("claude-code") = CoreDecode.source(["type": "hook", "name": "claude-code"]) else {
            return XCTFail("hook source")
        }
        guard case .osc7501 = CoreDecode.source(["type": "osc7501"]) else { return XCTFail("7501 source") }

        guard case .userPrompt("fix it") = CoreDecode.kind(["kind": "user_prompt", "text": "fix it"]) else {
            return XCTFail("prompt")
        }
        let q: [String: Any] = ["kind": "question", "prompt": "which?", "options": ["a", "b"],
                                "followups": [["prompt": "(2/2) and?", "options": ["c"],
                                               "flags": ["multi_select": true]]],
                                "flags": ["multi_select": false, "review_after": true, "checked": [1],
                                          "cursor": 2, "ask_id": "toolu_1"]]
        guard case .question(let prompt, let options, let followups, let flags) = CoreDecode.kind(q) else {
            return XCTFail("question")
        }
        XCTAssertEqual(prompt, "which?")
        XCTAssertEqual(options, ["a", "b"])
        XCTAssertEqual(followups.first?.flags.multiSelect, true)
        XCTAssertTrue(flags.reviewAfter)
        XCTAssertEqual(flags.checked, [1])
        XCTAssertEqual(flags.askId, "toolu_1")

        guard case .agentStopped(success: false) = CoreDecode.kind(["kind": "agent_stopped", "success": false]) else {
            return XCTFail("stop")
        }
        guard case .toolUse(let a) = CoreDecode.kind(["kind": "tool_use", "activity":
                ["tool": "Bash", "detail": "ls", "is_error": false, "timestamp": 10.0]]) else {
            return XCTFail("tool")
        }
        XCTAssertEqual(a.tool, "Bash")
        XCTAssertEqual(a.timestamp, Date(timeIntervalSince1970: 10))
        guard case .programStatus(let record) = CoreDecode.kind(["kind": "program_status", "record":
                ["state": "done", "kind": NSNull(), "progress": NSNull(), "app": "claude-code", "title": "", "msg": "ok"]]) else {
            return XCTFail("7501")
        }
        XCTAssertEqual(record?.state, .done)
        XCTAssertNil(CoreDecode.kind(["kind": "something_new"]))
    }

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
}
