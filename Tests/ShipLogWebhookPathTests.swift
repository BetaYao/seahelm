import XCTest
@testable import seahelm

/// Integration tests verifying the passive webhook path is status-neutral.
/// Webhook events must NOT reset tasks/roundDuration set by the poll path,
/// must NOT trigger an external-channel broadcast on their own, and the
/// agentStop completion transition must still fire.
final class ShipLogWebhookPathTests: XCTestCase {

    private let tid = "webhook-path-test-tid"
    private let worktreePath = "/tmp/webhook-path-test-repo"
    private var mockChannel: MockExternalChannel!

    override func setUp() {
        super.setUp()
        mockChannel = MockExternalChannel(channelId: "webhook-test-ch")
        ShipLog.shared.registerForTesting(
            terminalID: tid,
            worktreePath: worktreePath,
            branch: "feat-test",
            project: "WebhookTestProject"
        )
        ShipLog.shared.registerChannel(mockChannel)
        ShipLog.shared.onStatusTransition = nil
    }

    override func tearDown() {
        ShipLog.shared.onStatusTransition = nil
        ShipLog.shared.unregister(terminalID: tid)
        ShipLog.shared.unregisterAllExternalChannels()
        super.tearDown()
    }

    private func makeEvent(_ type: WebhookEventType) -> WebhookEvent {
        WebhookEvent(
            source: "claude-code",
            sessionId: "sess-1",
            event: type,
            cwd: worktreePath,
            timestamp: nil,
            data: nil
        )
    }

    // MARK: - Passive path: no tasks/roundDuration clobber

    func testToolUseEventDoesNotResetTasksOrRoundDuration() {
        // Simulate what the poll path sets
        ShipLog.shared.updateStatus(
            terminalID: tid,
            status: .running,
            lastMessage: "doing stuff",
            roundDuration: 42.0,
            tasks: [TaskItem(id: "t1", subject: "task-A", status: .pending)]
        )

        // Feed a webhook tool-use event (passive path)
        ShipLog.shared.handleWebhookEvent(makeEvent(.toolUseStart))

        let info = ShipLog.shared.sailor(for: tid)
        XCTAssertEqual(info?.roundDuration, 42.0,
            "webhook toolUseStart must not reset roundDuration set by poll")
        XCTAssertEqual(info?.tasks.count, 1,
            "webhook toolUseStart must not reset tasks set by poll")
        XCTAssertEqual(info?.tasks.first?.subject, "task-A",
            "webhook toolUseStart must not clobber task content")
    }

    func testPromptEventDoesNotResetTasksOrRoundDuration() {
        ShipLog.shared.updateStatus(
            terminalID: tid,
            status: .running,
            lastMessage: "processing",
            roundDuration: 99.5,
            tasks: [TaskItem(id: "t2", subject: "task-B", status: .pending),
                    TaskItem(id: "t3", subject: "task-C", status: .completed)]
        )

        ShipLog.shared.handleWebhookEvent(makeEvent(.prompt))

        let info = ShipLog.shared.sailor(for: tid)
        XCTAssertEqual(info?.roundDuration, 99.5,
            "webhook prompt must not reset roundDuration set by poll")
        XCTAssertEqual(info?.tasks.count, 2,
            "webhook prompt must not reset tasks set by poll")
    }

    // MARK: - Passive path: no external broadcast

    func testToolUseEventDoesNotBroadcastToExternalChannel() {
        ShipLog.shared.updateStatus(
            terminalID: tid,
            status: .running,
            lastMessage: "running",
            roundDuration: 0
        )
        // Clear any messages from the updateStatus call above
        mockChannel.sentMessages.removeAll()

        ShipLog.shared.handleWebhookEvent(makeEvent(.toolUseStart))

        XCTAssertEqual(mockChannel.sentMessages.count, 0,
            "webhook toolUseStart must not trigger an external broadcast")
    }

    func testPromptEventDoesNotBroadcastToExternalChannel() {
        ShipLog.shared.updateStatus(
            terminalID: tid,
            status: .running,
            lastMessage: "running",
            roundDuration: 0
        )
        mockChannel.sentMessages.removeAll()

        ShipLog.shared.handleWebhookEvent(makeEvent(.prompt))

        XCTAssertEqual(mockChannel.sentMessages.count, 0,
            "webhook prompt must not trigger an external broadcast")
    }

    // MARK: - agentStop: completion transition fires

    func testAgentStopFiresCompletionTransition() {
        ShipLog.shared.updateStatus(
            terminalID: tid,
            status: .running,
            lastMessage: "was running",
            roundDuration: 5.0
        )

        let exp = expectation(description: "agentStop completion transition")
        var captured: StatusTransition?
        ShipLog.shared.onStatusTransition = { t in
            if t.isCompletionSignal && captured == nil {
                captured = t
                exp.fulfill()
            }
        }

        ShipLog.shared.handleWebhookEvent(makeEvent(.agentStop))

        wait(for: [exp], timeout: 2)
        XCTAssertTrue(captured?.isCompletionSignal == true,
            "agentStop must fire a completion StatusTransition")
        XCTAssertEqual(captured?.terminalID, tid)
    }

    func testAgentStopUsesPolledStatusAsOldStatus() {
        // Poll sets status to .running
        ShipLog.shared.updateStatus(
            terminalID: tid,
            status: .running,
            lastMessage: "was running",
            roundDuration: 5.0
        )

        let exp = expectation(description: "agentStop transition with correct oldStatus")
        var captured: StatusTransition?
        ShipLog.shared.onStatusTransition = { t in
            if t.isCompletionSignal && captured == nil {
                captured = t
                exp.fulfill()
            }
        }

        ShipLog.shared.handleWebhookEvent(makeEvent(.agentStop))

        wait(for: [exp], timeout: 2)
        // oldStatus must be what the poll set (.running), NOT a freshly-written .idle
        XCTAssertEqual(captured?.oldStatus, .running,
            "agentStop completion transition oldStatus must reflect poll-set status, not .idle")
    }
}
