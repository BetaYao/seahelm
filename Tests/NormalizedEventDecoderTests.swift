import XCTest
@testable import seahelm

final class NormalizedEventDecoderTests: XCTestCase {
    private func event(_ type: WebhookEventType, data: [String: Any]? = nil) -> WebhookEvent {
        WebhookEvent(source: "claude-code", sessionId: "s", event: type,
                     cwd: "/wt", timestamp: nil, data: data)
    }

    func testAgentStopMapsToCompletionSuccess() {
        let kind = HookDecoder.kind(for: event(.agentStop))
        guard case .agentStopped(let success)? = kind else { return XCTFail("wrong kind") }
        XCTAssertTrue(success)
    }

    func testStopFailureMapsToCompletionFailure() {
        let kind = HookDecoder.kind(for: event(.stopFailure))
        guard case .agentStopped(let success)? = kind else { return XCTFail("wrong kind") }
        XCTAssertFalse(success)
    }

    func testPromptMapsToAwaitingInput() {
        let kind = HookDecoder.kind(for: event(.prompt, data: ["message": "need input"]))
        guard case .awaitingInput(let text)? = kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(text, "need input")
    }

    func testErrorFoldsIntoNotificationErrorLevel() {
        let kind = HookDecoder.kind(for: event(.error, data: ["message": "boom"]))
        guard case .notification(let level, let text)? = kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(level, "error")
        XCTAssertEqual(text, "boom")
    }

    func testToolUseStartMapsToToolUse() {
        let kind = HookDecoder.kind(for: event(.toolUseStart, data: ["tool_name": "Bash"]))
        guard case .toolUse? = kind else { return XCTFail("wrong kind") }
    }

    func testSessionStartMapsToSessionStartedWithLabel() {
        let kind = HookDecoder.kind(for: event(.sessionStart))
        guard case .sessionStarted(let label)? = kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(label, "Session started")
    }

    func testCwdChangedProducesNoKind() {
        XCTAssertNil(HookDecoder.kind(for: event(.cwdChanged)))
    }

    func testSuggestMapsToSuggestOptions() {
        let kind = HookDecoder.kind(for: event(.suggest, data: ["options": ["a", "b"]]))
        guard case .suggest(let options)? = kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(options, ["a", "b"])
    }
}
