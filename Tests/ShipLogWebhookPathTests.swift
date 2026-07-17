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
        ShipLog.shared.onOutcome = nil
    }

    override func tearDown() {
        ShipLog.shared.onOutcome = nil
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
        // Drain any pending main-queue async blocks from prior tests (e.g. a .waiting broadcast
        // queued by testPromptEventDoesNotResetTasksOrRoundDuration which doesn't await outcomes).
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        ShipLog.shared.updateStatus(
            terminalID: tid,
            status: .running,
            lastMessage: "running",
            roundDuration: 0
        )
        // Clear any messages from prior-test async or the updateStatus call above
        mockChannel.sentMessages.removeAll()

        ShipLog.shared.handleWebhookEvent(makeEvent(.toolUseStart))

        // Wait for any async notifyObservers to complete via onOutcome.
        // A single webhook event may produce more than one outcome (e.g. per
        // activity-event upsert), so tolerate over-fulfillment — we only need
        // to know the async work has settled before asserting no broadcast.
        let exp = expectation(description: "ingest outcome for toolUseStart")
        exp.assertForOverFulfill = false
        ShipLog.shared.onOutcome = { _ in exp.fulfill() }
        wait(for: [exp], timeout: 2)

        // broadcast only fires for .waiting or .error — toolUse sets hookStatus=.running, no broadcast
        XCTAssertEqual(mockChannel.sentMessages.count, 0,
            "webhook toolUseStart must not trigger an external broadcast")
    }

    /// ShipLog used to fan out to chat itself on `statusChanged && (waiting || error)`.
    /// That was a second, cruder notification path: no running→X edge check, no
    /// cooldown, no stability delay — so it re-sent on every flicker — and it never
    /// fired on completion, the one thing you want to hear from your phone.
    ///
    /// The fan-out now hangs off NotificationManager's delivery, mirroring the
    /// desktop banner and inheriting its gating. ShipLog must stay out of it: two
    /// paths meant two sets of rules.
    func testStatusChangeDoesNotFanOutToChatFromShipLog() {
        ShipLog.shared.updateStatus(
            terminalID: tid,
            status: .running,
            lastMessage: "running",
            roundDuration: 0
        )
        mockChannel.sentMessages.removeAll()

        let exp = expectation(description: "status reaches waiting")
        ShipLog.shared.onOutcome = { o in
            if o.newStatus == .waiting { exp.fulfill() }
        }

        ShipLog.shared.handleWebhookEvent(makeEvent(.prompt))

        wait(for: [exp], timeout: 2)
        XCTAssertTrue(mockChannel.sentMessages.isEmpty,
            "ShipLog must not broadcast; the phone mirrors the desktop banner via NotificationManager.onDeliverExternal")
    }

    // MARK: - agentStop: completion transition fires

    func testAgentStopFiresCompletionTransition() {
        ShipLog.shared.updateStatus(
            terminalID: tid,
            status: .running,
            lastMessage: "was running",
            roundDuration: 5.0
        )

        let exp = expectation(description: "agentStop completion outcome")
        var captured: IngestOutcome?
        ShipLog.shared.onOutcome = { o in
            if o.isCompletionSignal && captured == nil {
                captured = o
                exp.fulfill()
            }
        }

        ShipLog.shared.handleWebhookEvent(makeEvent(.agentStop))

        wait(for: [exp], timeout: 2)
        XCTAssertTrue(captured?.isCompletionSignal == true,
            "agentStop must fire a completion IngestOutcome")
        XCTAssertEqual(captured?.info.id, tid)
    }

    func testAgentStopUsesPolledStatusAsOldStatus() {
        // Poll sets status to .running
        ShipLog.shared.updateStatus(
            terminalID: tid,
            status: .running,
            lastMessage: "was running",
            roundDuration: 5.0
        )

        let exp = expectation(description: "agentStop outcome with correct oldStatus")
        var captured: IngestOutcome?
        ShipLog.shared.onOutcome = { o in
            if o.isCompletionSignal && captured == nil {
                captured = o
                exp.fulfill()
            }
        }

        ShipLog.shared.handleWebhookEvent(makeEvent(.agentStop))

        wait(for: [exp], timeout: 2)
        // oldStatus must be what the poll set (.running), NOT a freshly-written .idle
        XCTAssertEqual(captured?.oldStatus, .running,
            "agentStop completion outcome oldStatus must reflect poll-set status, not .idle")
    }
}
