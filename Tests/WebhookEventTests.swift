import XCTest
@testable import seahelm

final class WebhookEventTests: XCTestCase {

    // MARK: - Generic protocol parsing

    func testParseGenericEvent() throws {
        let json = """
        {"source":"claude-code","session_id":"sess_1","event":"tool_use_start","cwd":"/tmp/project","timestamp":"2026-03-20T12:00:00Z","data":{"tool":"Bash"}}
        """.data(using: .utf8)!
        let event = try WebhookEvent.parse(from: json)
        XCTAssertEqual(event.source, "claude-code")
        XCTAssertEqual(event.sessionId, "sess_1")
        XCTAssertEqual(event.event, .toolUseStart)
        XCTAssertEqual(event.cwd, "/tmp/project")
    }

    func testParsesSeahelmPaneId() throws {
        // Generic payload with the injected pane id.
        let generic = """
        {"seahelm_pane_id":"seahelm-repo-main","source":"claude-code","session_id":"s","event":"worktree_create","cwd":"/p","data":{}}
        """.data(using: .utf8)!
        XCTAssertEqual(try WebhookEvent.parse(from: generic).paneId, "seahelm-repo-main")

        // Native Claude hook payload: pane id must be lifted out of `data`.
        let native = """
        {"seahelm_pane_id":"seahelm-repo-main","hook_event_name":"PreToolUse","session_id":"s","cwd":"/p"}
        """.data(using: .utf8)!
        let ev = try WebhookEvent.parse(from: native)
        XCTAssertEqual(ev.paneId, "seahelm-repo-main")
        XCTAssertNil(ev.data?["seahelm_pane_id"])   // not leaked into data
    }

    func testParseGenericEventAllTypes() throws {
        let types: [(String, WebhookEventType)] = [
            ("session_start", .sessionStart),
            ("tool_use_start", .toolUseStart),
            ("tool_use_end", .toolUseEnd),
            ("agent_stop", .agentStop),
            ("notification", .notification),
            ("error", .error),
            ("prompt", .prompt),
        ]
        for (raw, expected) in types {
            let json = """
            {"source":"test","session_id":"s","event":"\(raw)","cwd":"/tmp"}
            """.data(using: .utf8)!
            let event = try WebhookEvent.parse(from: json)
            XCTAssertEqual(event.event, expected, "Failed for \(raw)")
        }
    }

    func testParseMissingRequiredFieldThrows() {
        let json = """
        {"source":"test","event":"agent_stop","cwd":"/tmp"}
        """.data(using: .utf8)!  // missing session_id
        XCTAssertThrowsError(try WebhookEvent.parse(from: json))
    }

    // MARK: - Claude Code native payload adapter

    func testParseClaudeCodePreToolUse() throws {
        let json = """
        {"hook_event_name":"PreToolUse","session_id":"sess_abc","cwd":"/tmp/project","tool_name":"Bash","tool_input":{"command":"ls"}}
        """.data(using: .utf8)!
        let event = try WebhookEvent.parse(from: json)
        XCTAssertEqual(event.source, "claude-code")
        XCTAssertEqual(event.sessionId, "sess_abc")
        XCTAssertEqual(event.event, .toolUseStart)
        XCTAssertEqual(event.cwd, "/tmp/project")
    }

    func testParseClaudeCodeStop() throws {
        let json = """
        {"hook_event_name":"Stop","session_id":"sess_abc","cwd":"/tmp/project","stop_reason":"end_turn"}
        """.data(using: .utf8)!
        let event = try WebhookEvent.parse(from: json)
        XCTAssertEqual(event.event, .agentStop)
    }

    func testParseClaudeCodeNotification() throws {
        let json = """
        {"hook_event_name":"Notification","session_id":"sess_abc","cwd":"/tmp/project","title":"Done","message":"All tests pass","level":"info"}
        """.data(using: .utf8)!
        let event = try WebhookEvent.parse(from: json)
        XCTAssertEqual(event.event, .notification)
        XCTAssertEqual(event.data?["level"] as? String, "info")
        XCTAssertEqual(event.data?["message"] as? String, "All tests pass")
    }

    func testParseClaudeCodeSessionStart() throws {
        let json = """
        {"hook_event_name":"SessionStart","session_id":"sess_new","cwd":"/tmp/project"}
        """.data(using: .utf8)!
        let event = try WebhookEvent.parse(from: json)
        XCTAssertEqual(event.event, .sessionStart)
        XCTAssertEqual(event.source, "claude-code")
    }

    func testParseClaudeCodePostToolUse() throws {
        let json = """
        {"hook_event_name":"PostToolUse","session_id":"sess_abc","cwd":"/tmp/project","tool_name":"Read"}
        """.data(using: .utf8)!
        let event = try WebhookEvent.parse(from: json)
        XCTAssertEqual(event.event, .toolUseEnd)
    }

    func testParseCodexNativeSessionStart() throws {
        let json = """
        {"hook_event_name":"SessionStart","session_id":"sess_codex","cwd":"/tmp/project","model":"gpt-5.4","turn_id":"turn_123"}
        """.data(using: .utf8)!
        let event = try WebhookEvent.parse(from: json)
        XCTAssertEqual(event.event, .sessionStart)
        XCTAssertEqual(event.source, "codex")
        XCTAssertEqual(event.data?["model"] as? String, "gpt-5.4")
    }

    // MARK: - Cursor native payload adapter

    func testParseCursorStopMapsLoopCountToStopHookActive() throws {
        let first = """
        {"hook_event_name":"stop","conversation_id":"conv_1","cursor_version":"1.7.2",
         "workspace_roots":["/tmp/wt"],"status":"completed","loop_count":0}
        """.data(using: .utf8)!
        let e1 = try WebhookEvent.parse(from: first)
        XCTAssertEqual(e1.source, "cursor")
        XCTAssertEqual(e1.event, .agentStop)
        XCTAssertEqual(e1.sessionId, "conv_1")
        XCTAssertEqual(e1.cwd, "/tmp/wt")
        XCTAssertEqual(e1.data?["stop_hook_active"] as? Bool, false)
        XCTAssertEqual(e1.data?["status"] as? String, "completed")

        let second = """
        {"hook_event_name":"stop","conversation_id":"conv_1","cursor_version":"1.7.2",
         "workspace_roots":["/tmp/wt"],"status":"completed","loop_count":1}
        """.data(using: .utf8)!
        let e2 = try WebhookEvent.parse(from: second)
        XCTAssertEqual(e2.data?["stop_hook_active"] as? Bool, true)
    }

    func testParseCursorBeforeSubmitPrompt() throws {
        let json = """
        {"hook_event_name":"beforeSubmitPrompt","conversation_id":"c","cursor_version":"1.7.2",
         "workspace_roots":["/repo"],"prompt":"hello"}
        """.data(using: .utf8)!
        let event = try WebhookEvent.parse(from: json)
        XCTAssertEqual(event.source, "cursor")
        XCTAssertEqual(event.event, .userPrompt)
        XCTAssertEqual(event.cwd, "/repo")
    }

    // MARK: - Event → SailorStatus mapping

    func testEventToSailorStatus() {
        XCTAssertEqual(WebhookEventType.sessionStart.agentStatus(data: nil), .running)
        XCTAssertEqual(WebhookEventType.toolUseStart.agentStatus(data: nil), .running)
        XCTAssertEqual(WebhookEventType.toolUseEnd.agentStatus(data: nil), .running)
        XCTAssertEqual(WebhookEventType.toolUseFailed.agentStatus(data: nil), .running)
        XCTAssertEqual(WebhookEventType.agentStop.agentStatus(data: nil), .idle)
        XCTAssertEqual(WebhookEventType.error.agentStatus(data: nil), .error)
        XCTAssertEqual(WebhookEventType.stopFailure.agentStatus(data: nil), .error)
        XCTAssertEqual(WebhookEventType.prompt.agentStatus(data: nil), .waiting)
    }

    func testNotificationLevelMapping() {
        XCTAssertEqual(WebhookEventType.notification.agentStatus(data: ["level": "error"]), .error)
        XCTAssertEqual(WebhookEventType.notification.agentStatus(data: ["level": "warning"]), .waiting)
        XCTAssertEqual(WebhookEventType.notification.agentStatus(data: ["level": "info"]), .unknown)
        XCTAssertEqual(WebhookEventType.notification.agentStatus(data: nil), .unknown)
    }

    func testParseClaudeCodeSubagentStop() throws {
        let json = """
        {"hook_event_name":"SubagentStop","session_id":"sess_abc","cwd":"/tmp/project"}
        """.data(using: .utf8)!
        let event = try WebhookEvent.parse(from: json)
        XCTAssertEqual(event.event, .subagentStop)
        XCTAssertEqual(event.source, "claude-code")
    }

    // MARK: - Invalid JSON

    func testParseInvalidJSON() {
        let json = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try WebhookEvent.parse(from: json))
    }

    func testParseUnknownEventType() throws {
        let json = """
        {"source":"test","session_id":"s","event":"unknown_event","cwd":"/tmp"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try WebhookEvent.parse(from: json))
    }

    func testParseUnknownClaudeHookType() throws {
        let json = """
        {"hook_event_name":"UnknownHook","session_id":"s","cwd":"/tmp"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try WebhookEvent.parse(from: json))
    }
}
