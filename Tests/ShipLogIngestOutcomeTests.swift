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

    func testHookRunningThenScanIdleMergesToRunning() {
        // hookStatus=running (higher priority than idle) must survive a later scan idle.
        // Set onOutcome first; skip first event (sessionStarted), capture the second (screenObserved).
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
                                  commandLine: nil, agentType: .claudeCode)))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.newStatus, .running)  // highestPriority(scan=idle, hook=running)
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
