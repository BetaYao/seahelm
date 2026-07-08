import XCTest
@testable import seahelm

final class ShipLogIngestOutcomeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ShipLog.shared.registerForTesting(terminalID: "t1", worktreePath: "/wt",
                                          branch: "main", project: "proj")
    }
    override func tearDown() {
        // Stop receiving, then drain any async outcomes still queued on main so they
        // cannot leak into the next test's onOutcome handler (ShipLog.shared is a singleton
        // and notifyObservers delivers via DispatchQueue.main.async).
        ShipLog.shared.onOutcome = nil
        let drain = expectation(description: "drain main queue")
        DispatchQueue.main.async { drain.fulfill() }
        wait(for: [drain], timeout: 1)
        ShipLog.shared.unregister(terminalID: "t1")
        super.tearDown()
    }

    func testSessionOnlyScreenIdleOverridesStaleHookRunning() {
        // claude is session_only → screen is authoritative. A (debounced) scan
        // idle overrides a stale hook=running, instead of the old
        // highestPriority merge that pinned it to running forever.
        var callCount = 0
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        exp.assertForOverFulfill = false
        ShipLog.shared.onOutcome = { o in
            callCount += 1
            if callCount == 2 { captured = o; exp.fulfill() }
        }
        ShipLog.shared.ingest(NormalizedEvent(terminalID: "t1", source: .hook("claude-code"),
                                              kind: .sessionStarted(label: "Session started")))
        ShipLog.shared.ingest(NormalizedEvent(terminalID: "t1", source: .scan,
            kind: .screenObserved(status: .idle, message: "", activity: [],
                                  commandLine: nil, agentType: .claudeCode,
                                  roundDuration: 0, tasks: [])))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.newStatus, .idle)
    }

    func testUrgentHookSurfacesEvenWhenScreenAuthoritative() {
        // A hook waiting/error must never be hidden by the authority rule.
        var callCount = 0
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        exp.assertForOverFulfill = false
        ShipLog.shared.onOutcome = { o in
            callCount += 1
            if callCount == 2 { captured = o; exp.fulfill() }
        }
        ShipLog.shared.ingest(NormalizedEvent(terminalID: "t1", source: .scan,
            kind: .screenObserved(status: .idle, message: "", activity: [],
                                  commandLine: nil, agentType: .claudeCode,
                                  roundDuration: 0, tasks: [])))
        ShipLog.shared.ingest(NormalizedEvent(terminalID: "t1", source: .hook("claude-code"),
                                              kind: .awaitingInput("approve?")))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.newStatus, .waiting)
    }

    func testScreenObservedCarriesRoundDurationAndTasks() {
        // Regression test for C1/C2: roundDuration and tasks must flow through ingest(.screenObserved)
        let stubTask = TaskItem(id: "t-1", subject: "Write tests", status: .inProgress)
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        ShipLog.shared.onOutcome = { o in captured = o; exp.fulfill() }
        ShipLog.shared.ingest(NormalizedEvent(
            terminalID: "t1", source: .scan,
            kind: .screenObserved(status: .running, message: "", activity: [],
                                  commandLine: nil, agentType: .claudeCode,
                                  roundDuration: 42.5, tasks: [stubTask])))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.info.roundDuration, 42.5)
        XCTAssertEqual(captured?.info.tasks.count, 1)
        XCTAssertEqual(captured?.info.tasks.first?.id, "t-1")
    }

    func testAgentStoppedFailureIsCompletionWithError() {
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        ShipLog.shared.onOutcome = { o in captured = o; exp.fulfill() }
        ShipLog.shared.ingest(NormalizedEvent(terminalID: "t1", source: .hook("claude-code"),
                                              kind: .agentStopped(success: false)))
        wait(for: [exp], timeout: 2)
        XCTAssertTrue(captured?.isCompletionSignal ?? false)
        XCTAssertEqual(captured?.newStatus, .error)
    }
}
