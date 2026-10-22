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
        guard case .question(let prompt, let options, _, _)? = normalized?.kind else { return XCTFail("wrong kind") }
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
        guard case .question(let prompt, _, _, _)? = normalized?.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(prompt, "Q1? (1/2)")
    }

    /// Which questions end on the review page decides whether the last answer
    /// needs a confirming Return; a lone single-select question submits at once.
    func testAskUserQuestionFlagsMultiSelectAndReviewPage() {
        func flags(_ questions: [[String: Any]]) -> (QuestionFlags, [QuestionFlags])? {
            let event = makeEvent(type: .toolUseStart, data: [
                "tool_name": "AskUserQuestion", "tool_input": ["questions": questions],
            ])
            guard case .question(_, _, let followups, let first)? =
                    HookDecoder(terminalID: "t1", event: event).decode()?.kind else { return nil }
            // askId is per call; the shape is what's under test.
            func shape(_ f: QuestionFlags) -> QuestionFlags {
                QuestionFlags(multiSelect: f.multiSelect, reviewAfter: f.reviewAfter)
            }
            return (shape(first), followups.map { shape($0.flags) })
        }
        let single = flags([["question": "Q?", "options": [["label": "A"], ["label": "B"]]]])
        XCTAssertEqual(single?.0, QuestionFlags(multiSelect: false, reviewAfter: false))

        let multi = flags([["question": "Q?", "multiSelect": true, "options": [["label": "A"], ["label": "B"]]]])
        XCTAssertEqual(multi?.0, QuestionFlags(multiSelect: true, reviewAfter: true))

        let two = flags([
            ["question": "Q1?", "multiSelect": true, "options": [["label": "A"], ["label": "B"]]],
            ["question": "Q2?", "options": [["label": "C"], ["label": "D"]]],
        ])
        XCTAssertEqual(two?.0, QuestionFlags(multiSelect: true, reviewAfter: false))
        XCTAssertEqual(two?.1, [QuestionFlags(multiSelect: false, reviewAfter: true)])
    }

    func testQuestionsOfOneAskShareItsToolUseId() {
        let event = makeEvent(type: .toolUseStart, data: [
            "tool_name": "AskUserQuestion", "tool_use_id": "toolu_1",
            "tool_input": ["questions": [
                ["question": "Q1?", "options": [["label": "A"], ["label": "B"]]],
                ["question": "Q2?", "options": [["label": "C"], ["label": "D"]]],
            ]],
        ])
        guard case .question(_, _, let followups, let flags)? =
                HookDecoder(terminalID: "t1", event: event).decode()?.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(flags.askId, "toolu_1")
        XCTAssertEqual(followups.map(\.flags.askId), ["toolu_1"])
    }

    func testMultiSelectCardTicksItsOptionsAndOffersDone() {
        var flags = QuestionFlags(multiSelect: true, reviewAfter: true)
        flags.checked = [1]
        let action = FirstMateAction(kind: .suggestNextOrder, zone: .red, worktreePath: "/wt", branch: "b",
                                     project: "p", terminalID: "t1", message: "Pick fruits",
                                     payload: FirstMateAction.askUserQuestionPayload,
                                     options: ["Apple", "Banana"], questionFlags: flags)
        XCTAssertEqual(action.answerLabels, ["☐ Apple", "☑ Banana", FirstMateAction.questionDoneLabel])
        XCTAssertEqual(action.with(questionFlags: QuestionFlags()).answerLabels, ["Apple", "Banana"])
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
