import XCTest
@testable import seahelm

final class StopHookResponderTests: XCTestCase {
    private func stop(active: Bool?) -> WebhookEvent {
        var data: [String: Any] = [:]
        if let active { data["stop_hook_active"] = active }
        return WebhookEvent(source: "claude-code", sessionId: "s", event: .agentStop,
                            cwd: "/wt", timestamp: nil, data: data.isEmpty ? nil : data)
    }

    func testFirstStopBlocks() {
        let body = StopHookResponder.blockBody(for: stop(active: false), suggestOnStop: true)
        XCTAssertNotNil(body)
        XCTAssertTrue(body!.contains("\"decision\":\"block\""))
        XCTAssertTrue(body!.contains(StopHookResponder.sentinel))
    }

    /// The block reason must ask for an inline PLAIN-TEXT line, never a tool/shell
    /// call. A trailing tool_use is exactly what left the answer prose sitting
    /// "between tool calls" for Claude Code's TUI to swallow; direction 3 removes it.
    func testBlockReasonAsksForInlineTextNotAToolCall() {
        let body = StopHookResponder.blockBody(for: stop(active: false), suggestOnStop: true)
        XCTAssertNotNil(body)
        XCTAssertTrue(body!.contains(StopHookResponder.sentinel),
                      "reason must name the sentinel token: \(body!)")
        XCTAssertTrue(body!.lowercased().contains("plain text"),
                      "reason must ask for plain text: \(body!)")
        // Must not resurrect the old "run the script via Bash" instruction.
        XCTAssertFalse(body!.contains("via Bash"), "reason must not tell the agent to run Bash: \(body!)")
        XCTAssertFalse(body!.contains(SeahelmSuggestInstaller.scriptPath()),
                       "reason must not invoke the suggest script: \(body!)")
    }

    /// Options declared inline ride last_assistant_message — no block, no round-trip.
    func testInlineSuggestionsDoNotBlock() {
        let msg = "Fixed it, all tests pass.\n\(StopHookResponder.sentinel) run tests | open PR"
        XCTAssertNil(StopHookResponder.blockBody(for: stop(active: false, lastMessage: msg), suggestOnStop: true))
    }

    func testParseSuggestions() {
        let msg = "Done.\nHere are next steps:\n\(StopHookResponder.sentinel) build | run tests | ship it"
        XCTAssertEqual(StopHookResponder.parseSuggestions(from: msg), ["build", "run tests", "ship it"])
    }

    func testParseSuggestionsTolerantOfBackticks() {
        let msg = "`\(StopHookResponder.sentinel) alpha | beta`"
        XCTAssertEqual(StopHookResponder.parseSuggestions(from: msg), ["alpha", "beta"])
    }

    func testParseSuggestionsCapsAtFive() {
        let msg = "\(StopHookResponder.sentinel) a | b | c | d | e | f | g"
        XCTAssertEqual(StopHookResponder.parseSuggestions(from: msg)?.count, 5)
    }

    func testParseSuggestionsAbsentReturnsNil() {
        XCTAssertNil(StopHookResponder.parseSuggestions(from: "Just a normal answer with no options."))
    }

    func testStripSentinelRemovesMarkerLine() {
        let msg = "The answer is 42.\n\(StopHookResponder.sentinel) a | b"
        XCTAssertEqual(StopHookResponder.stripSentinel(from: msg), "The answer is 42.")
    }

    func testSecondStopDoesNotBlock() {
        XCTAssertNil(StopHookResponder.blockBody(for: stop(active: true), suggestOnStop: true))
    }

    func testMissingFlagTreatedAsFirstStop() {
        XCTAssertNotNil(StopHookResponder.blockBody(for: stop(active: nil), suggestOnStop: true))
    }

    func testDisabledNeverBlocks() {
        XCTAssertNil(StopHookResponder.blockBody(for: stop(active: false), suggestOnStop: false))
    }

    func testNonStopEventNeverBlocks() {
        let e = WebhookEvent(source: "claude-code", sessionId: "s", event: .toolUseStart,
                             cwd: "/wt", timestamp: nil, data: nil)
        XCTAssertNil(StopHookResponder.blockBody(for: e, suggestOnStop: true))
    }

    func testSubagentStopNeverBlocks() {
        // SubagentStop is now a distinct event and must not trigger a suggestion block.
        let e = WebhookEvent(source: "claude-code", sessionId: "s", event: .subagentStop,
                             cwd: "/wt", timestamp: nil, data: ["stop_hook_active": false])
        XCTAssertNil(StopHookResponder.blockBody(for: e, suggestOnStop: true))
    }

    func testRunningBackgroundTaskSkipsBlock() {
        // Main Stop fired while a background shell task is still running → do not suggest.
        let data: [String: Any] = [
            "stop_hook_active": false,
            "background_tasks": [
                ["id": "b1", "type": "shell", "status": "running", "description": "sleep 75"]
            ],
        ]
        let e = WebhookEvent(source: "claude-code", sessionId: "s", event: .agentStop,
                             cwd: "/wt", timestamp: nil, data: data)
        XCTAssertNil(StopHookResponder.blockBody(for: e, suggestOnStop: true))
    }

    func testCompletedBackgroundTasksStillBlock() {
        // No running background tasks → genuine idle → block/suggest as normal.
        let data: [String: Any] = [
            "stop_hook_active": false,
            "background_tasks": [
                ["id": "b1", "type": "shell", "status": "completed", "description": "done"]
            ],
        ]
        let e = WebhookEvent(source: "claude-code", sessionId: "s", event: .agentStop,
                             cwd: "/wt", timestamp: nil, data: data)
        XCTAssertNotNil(StopHookResponder.blockBody(for: e, suggestOnStop: true))
    }

    private func stop(active: Bool?, lastMessage: String) -> WebhookEvent {
        var data: [String: Any] = ["last_assistant_message": lastMessage]
        if let active { data["stop_hook_active"] = active }
        return WebhookEvent(source: "claude-code", sessionId: "s", event: .agentStop,
                            cwd: "/wt", timestamp: nil, data: data)
    }

    func testQuestionEnglishDoesNotBlock() {
        XCTAssertNil(StopHookResponder.blockBody(
            for: stop(active: false, lastMessage: "Did the deployment finish?"), suggestOnStop: true))
    }

    func testQuestionChineseDoesNotBlock() {
        XCTAssertNil(StopHookResponder.blockBody(
            for: stop(active: false, lastMessage: "部署完了吗？能贴一下终端输出吗？"), suggestOnStop: true))
    }

    func testStatementStillBlocks() {
        XCTAssertNotNil(StopHookResponder.blockBody(
            for: stop(active: false, lastMessage: "I've fixed the bug and all tests pass."), suggestOnStop: true))
    }

    func testIsAskingQuestionTrimming() {
        XCTAssertTrue(StopHookResponder.isAskingQuestion(["last_assistant_message": "Ready?\n"]))
        XCTAssertFalse(StopHookResponder.isAskingQuestion(["last_assistant_message": "Done."]))
        XCTAssertFalse(StopHookResponder.isAskingQuestion(nil))
    }

    func testCursorAbortedStopDoesNotBlock() {
        let e = WebhookEvent(
            source: "cursor", sessionId: "c", event: .agentStop, cwd: "/wt", timestamp: nil,
            data: ["stop_hook_active": false, "status": "aborted"])
        XCTAssertNil(StopHookResponder.blockBody(for: e, suggestOnStop: true))
    }

    func testCursorCompletedStopBlocks() {
        let e = WebhookEvent(
            source: "cursor", sessionId: "c", event: .agentStop, cwd: "/wt", timestamp: nil,
            data: ["stop_hook_active": false, "status": "completed"])
        XCTAssertNotNil(StopHookResponder.blockBody(for: e, suggestOnStop: true))
    }
}
