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

    /// Regression: Claude Code's common payload base carries `agent_id`/`agent_type`
    /// and PostToolUse adds `duration_ms`. Those used to be treated as Codex-only,
    /// so every Claude tool hook retyped the pane to Codex.
    func testClaudeToolHookWithExecutionMetadataIsNotCodex() throws {
        let json = """
        {"hook_event_name":"PostToolUse","session_id":"sess_abc","cwd":"/tmp/project",
         "tool_name":"Bash","agent_id":"a1","agent_type":"general-purpose","duration_ms":42,
         "model":"claude-opus-5"}
        """.data(using: .utf8)!
        let event = try WebhookEvent.parse(from: json)
        XCTAssertEqual(event.source, "claude-code")
    }

    /// An explicit tag from the bridge beats any key sniffing.
    func testExplicitSeahelmSourceWins() throws {
        let codexShaped = """
        {"seahelm_source":"claude-code","hook_event_name":"PostToolUse","session_id":"s",
         "cwd":"/p","turn_id":"t1","call_id":"c1"}
        """.data(using: .utf8)!
        XCTAssertEqual(try WebhookEvent.parse(from: codexShaped).source, "claude-code")

        let claudeShaped = """
        {"seahelm_source":"codex","hook_event_name":"SubagentStop","session_id":"s","cwd":"/p"}
        """.data(using: .utf8)!
        XCTAssertEqual(try WebhookEvent.parse(from: claudeShaped).source, "codex")
    }

    /// The tag is routing metadata, not agent data.
    func testSeahelmSourceIsNotLeakedIntoData() throws {
        let json = """
        {"seahelm_source":"codex","hook_event_name":"PostToolUse","session_id":"s","cwd":"/p","tool_name":"Bash"}
        """.data(using: .utf8)!
        let event = try WebhookEvent.parse(from: json)
        XCTAssertNil(event.data?["seahelm_source"])
        XCTAssertEqual(event.data?["tool_name"] as? String, "Bash")
    }

    func testHookSourceMapsToAgentType() {
        XCTAssertEqual(AgentType.fromHookSource("claude-code"), .claudeCode)
        XCTAssertEqual(AgentType.fromHookSource("codex"), .codex)
        XCTAssertEqual(AgentType.fromHookSource("opencode"), .openCode)
        XCTAssertEqual(AgentType.fromHookSource("pi"), .pi)
        XCTAssertEqual(AgentType.fromHookSource("cursor"), .cursor)
        XCTAssertEqual(AgentType.fromHookSource("nope"), .unknown)
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

    func testParseCursorAfterAgentResponseHarvestsText() throws {
        let json = """
        {"hook_event_name":"afterAgentResponse","conversation_id":"conv_9",
         "cursor_version":"1.7.2","workspace_roots":["/tmp/wt"],
         "text":"Done.\\n::seahelm-suggest:: run tests | open PR"}
        """.data(using: .utf8)!
        let event = try WebhookEvent.parse(from: json)
        XCTAssertEqual(event.source, "cursor")
        XCTAssertEqual(event.event, .assistantResponse)
        XCTAssertEqual(event.sessionId, "conv_9")
        XCTAssertEqual(event.cwd, "/tmp/wt")
        XCTAssertEqual(
            event.data?["text"] as? String,
            "Done.\n::seahelm-suggest:: run tests | open PR")
        XCTAssertEqual(WebhookEventType.assistantResponse.agentStatus(data: nil), .unknown)
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

    func testParseCursorSessionStartYieldsResumableSessionRef() throws {
        // Shape the seahelm-hook bridge actually delivers for Cursor: declared
        // source, pane id, camelCase event, conversation_id + workspace_roots.
        let json = """
        {"seahelm_pane_id":"pane-7","seahelm_source":"cursor","hook_event_name":"sessionStart",
         "conversation_id":"15264009-b835-46b6-90fe-6ec5c818da81","workspace_roots":["/repo"]}
        """.data(using: .utf8)!
        let event = try WebhookEvent.parse(from: json)
        XCTAssertEqual(event.source, "cursor")
        XCTAssertEqual(event.event, .sessionStart)
        XCTAssertEqual(event.paneId, "pane-7")

        // The conversation id doubles as the Cursor chat directory name, so the
        // ref built here is what unlocks the per-session title lookup.
        let ref = try XCTUnwrap(AgentSessionRef(source: event.source, sessionId: event.sessionId))
        XCTAssertEqual(ref.agent, "cursor")
        XCTAssertEqual(ref.kind, .id)
        XCTAssertEqual(ref.sessionId, "15264009-b835-46b6-90fe-6ec5c818da81")
    }

    // MARK: - Event → AgentStatus mapping

    func testEventToAgentStatus() {
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
