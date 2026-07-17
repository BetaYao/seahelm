import XCTest
@testable import seahelm

final class HookDecoderTests: XCTestCase {

    // Helper: build a WebhookEvent directly using its memberwise initializer
    private func makeEvent(
        type: WebhookEventType,
        data: [String: Any]? = nil
    ) -> WebhookEvent {
        WebhookEvent(
            source: "claude-code",
            sessionId: "test-session",
            event: type,
            cwd: "/tmp/test-worktree",
            timestamp: nil,
            data: data
        )
    }

    func testAgentStopMapsToAgentStopped() {
        let event = makeEvent(type: .agentStop, data: ["stop_reason": "end_turn"])
        let normalized = HookDecoder(terminalID: "t1", event: event).decode()
        guard case .agentStopped(let success)? = normalized?.kind else { return XCTFail("wrong kind") }
        XCTAssertTrue(success)
    }

    func testStopFailureMapsToAgentStoppedFailure() {
        let event = makeEvent(type: .stopFailure)
        let normalized = HookDecoder(terminalID: "t1", event: event).decode()
        guard case .agentStopped(let success)? = normalized?.kind else { return XCTFail("wrong kind") }
        XCTAssertFalse(success)
    }

    func testToolUseStartMapsToToolUse() {
        let event = makeEvent(type: .toolUseStart, data: ["tool_name": "Bash"])
        let normalized = HookDecoder(terminalID: "t1", event: event).decode()
        guard case .toolUse(let ae)? = normalized?.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(ae.tool, "Bash")
    }

    func testAskUserQuestionMapsToQuestion() {
        let event = makeEvent(type: .toolUseStart, data: [
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [[
                    "question": "Where should daily check-in happen?",
                    "options": [["label": "Gate face scan"], ["label": "Front desk kiosk"]],
                ]],
            ],
        ])
        let normalized = HookDecoder(terminalID: "t1", event: event).decode()
        guard case .question(let prompt, let options, _)? = normalized?.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(prompt, "Where should daily check-in happen?")
        XCTAssertEqual(options, ["Gate face scan", "Front desk kiosk"])
    }

    func testAskUserQuestionMultiQuestionTagsCount() {
        let event = makeEvent(type: .toolUseStart, data: [
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [
                    ["question": "Q1?", "options": [["label": "A"], ["label": "B"]]],
                    ["question": "Q2?", "options": [["label": "C"]]],
                ],
            ],
        ])
        let normalized = HookDecoder(terminalID: "t1", event: event).decode()
        guard case .question(let prompt, _, _)? = normalized?.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(prompt, "Q1? (1/2)")
    }

    func testAskUserQuestionWithBadPayloadDegradesToToolUse() {
        let event = makeEvent(type: .toolUseStart, data: ["tool_name": "AskUserQuestion"])
        let normalized = HookDecoder(terminalID: "t1", event: event).decode()
        guard case .toolUse? = normalized?.kind else { return XCTFail("wrong kind") }
    }

    func testPromptMapsToAwaitingInput() {
        let event = makeEvent(type: .prompt, data: ["message": "Continue?"])
        let normalized = HookDecoder(terminalID: "t1", event: event).decode()
        guard case .awaitingInput(let text)? = normalized?.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(text, "Continue?")
    }

    func testErrorMapsToNotificationError() {
        let event = makeEvent(type: .error, data: ["message": "Something went wrong"])
        let normalized = HookDecoder(terminalID: "t1", event: event).decode()
        guard case .notification(let level, let text)? = normalized?.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(level, "error")
        XCTAssertEqual(text, "Something went wrong")
    }

    func testSessionStartMapsToSessionStarted() {
        let event = makeEvent(type: .sessionStart)
        let normalized = HookDecoder(terminalID: "t1", event: event).decode()
        guard case .sessionStarted(let label)? = normalized?.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(label, "Session started")
    }

    func testToolUseEndProducesToolUseActivity() {
        let event = makeEvent(type: .toolUseEnd, data: ["tool_name": "Read"])
        let normalized = HookDecoder(terminalID: "t1", event: event).decode()
        guard case .toolUse(let ae)? = normalized?.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(ae.tool, "Read")
    }

    func testCwdChangedProducesNil() {
        let event = makeEvent(type: .cwdChanged)
        let normalized = HookDecoder(terminalID: "t1", event: event).decode()
        XCTAssertNil(normalized)
    }
}
