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
        XCTAssertTrue(body!.contains("seahelm-suggest"))
    }

    /// Regression: the reason named `seahelm-suggest` bare. The installers write the
    /// CLIs to ~/.local/bin but nothing puts that on PATH — not seahelm (panes get
    /// SEAHELM_ENV/SEAHELM_SOCKET_PATH and nothing more), not macOS by default — so
    /// on a clean install every agent was told to run a command it could not find.
    /// It only ever worked on machines whose shell profile had added the directory.
    func testBlockBodyNamesTheScriptByAbsolutePath() {
        let path = SeahelmSuggestInstaller.scriptPath()
        XCTAssertTrue(path.hasPrefix("/"), "installer path must be absolute: \(path)")

        let body = StopHookResponder.blockBody(for: stop(active: false), suggestOnStop: true)
        XCTAssertNotNil(body)
        XCTAssertTrue(body!.contains(path),
                      "block reason must carry the absolute script path, not a bare name: \(body!)")
        // A bare invocation must not survive: `run \`seahelm-suggest '...'\`` is
        // exactly what a shell can't resolve without PATH.
        XCTAssertFalse(body!.contains("`seahelm-suggest "),
                       "block reason still invokes the bare name: \(body!)")
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
