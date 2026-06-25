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

    func testAgentStopMapsToIdle() {
        let event = makeEvent(type: .agentStop, data: ["stop_reason": "end_turn"])
        let report = HookDecoder(event: event).decode()
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.status, .idle)
        XCTAssertEqual(report?.lastMessage, "Stopped: end_turn")
    }

    func testAgentStopWithoutReasonHasEmptyMessage() {
        let event = makeEvent(type: .agentStop)
        let report = HookDecoder(event: event).decode()
        XCTAssertEqual(report?.status, .idle)
        XCTAssertEqual(report?.lastMessage, "")
    }

    func testToolUseStartMapsToRunning() {
        let event = makeEvent(type: .toolUseStart, data: ["tool_name": "Bash"])
        let report = HookDecoder(event: event).decode()
        XCTAssertEqual(report?.status, .running)
        XCTAssertEqual(report?.lastMessage, "Using Bash")
        XCTAssertEqual(report?.activityEvents.count, 1)
        XCTAssertEqual(report?.activityEvents.first?.tool, "Bash")
    }

    func testPromptMapsToWaiting() {
        let event = makeEvent(type: .prompt, data: ["message": "Continue?"])
        let report = HookDecoder(event: event).decode()
        XCTAssertEqual(report?.status, .waiting)
        XCTAssertEqual(report?.lastMessage, "Continue?")
    }

    func testErrorMapsToError() {
        let event = makeEvent(type: .error, data: ["message": "Something went wrong"])
        let report = HookDecoder(event: event).decode()
        XCTAssertEqual(report?.status, .error)
        XCTAssertEqual(report?.lastMessage, "Something went wrong")
    }

    func testSessionStartMapsToRunning() {
        let event = makeEvent(type: .sessionStart)
        let report = HookDecoder(event: event).decode()
        XCTAssertEqual(report?.status, .running)
        XCTAssertEqual(report?.lastMessage, "Session started")
    }

    func testToolUseEndProducesActivityEvent() {
        let event = makeEvent(type: .toolUseEnd, data: ["tool_name": "Read"])
        let report = HookDecoder(event: event).decode()
        XCTAssertEqual(report?.activityEvents.count, 1)
        XCTAssertEqual(report?.lastMessage, "Done: Read")
    }

    func testCwdChangedProducesEmptyMessage() {
        let event = makeEvent(type: .cwdChanged)
        let report = HookDecoder(event: event).decode()
        // cwdChanged → .running, empty message
        XCTAssertEqual(report?.status, .running)
        XCTAssertEqual(report?.lastMessage, "")
    }
}
