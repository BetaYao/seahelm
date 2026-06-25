import XCTest
@testable import seahelm

final class ShipLogIngestTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ShipLog.shared.onOutcome = nil
        for agent in ShipLog.shared.allSailors() {
            ShipLog.shared.unregister(terminalID: agent.id)
        }
    }

    override func tearDown() {
        // Drain pending main-queue async blocks before clearing the callback,
        // so they don't fire into the next test's onOutcome handler.
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        ShipLog.shared.onOutcome = nil
        for agent in ShipLog.shared.allSailors() {
            ShipLog.shared.unregister(terminalID: agent.id)
        }
        super.tearDown()
    }

    func testIngestUpdatesStatus() {
        ShipLog.shared.registerForTesting(
            terminalID: "t-ingest-1",
            worktreePath: "/tmp/ingest-test",
            branch: "main",
            project: "IngestTest"
        )
        ShipLog.shared.ingest(NormalizedEvent(
            terminalID: "t-ingest-1", source: .scan,
            kind: .screenObserved(status: .waiting, message: "need input",
                                  activity: [], commandLine: nil, agentType: .unknown)))
        XCTAssertEqual(ShipLog.shared.sailor(for: "t-ingest-1")?.status, .waiting)
    }

    func testIngestUpdatesLastMessage() {
        ShipLog.shared.registerForTesting(
            terminalID: "t-ingest-2",
            worktreePath: "/tmp/ingest-test2",
            branch: "main",
            project: "IngestTest"
        )
        ShipLog.shared.ingest(NormalizedEvent(
            terminalID: "t-ingest-2", source: .scan,
            kind: .screenObserved(status: .running, message: "doing stuff",
                                  activity: [], commandLine: nil, agentType: .unknown)))
        XCTAssertEqual(ShipLog.shared.sailor(for: "t-ingest-2")?.lastMessage, "doing stuff")
    }

    func testIngestForUnknownTerminalIsNoop() {
        // Should not crash for unregistered terminal
        ShipLog.shared.ingest(NormalizedEvent(
            terminalID: "t-nonexistent-99", source: .scan,
            kind: .screenObserved(status: .waiting, message: "hello",
                                  activity: [], commandLine: nil, agentType: .unknown)))
        XCTAssertNil(ShipLog.shared.sailor(for: "t-nonexistent-99"))
    }

    func testIngestLastUserPrompt() {
        ShipLog.shared.registerForTesting(
            terminalID: "t-ingest-3",
            worktreePath: "/tmp/ingest-test3",
            branch: "main",
            project: "IngestTest"
        )
        ShipLog.shared.ingest(NormalizedEvent(
            terminalID: "t-ingest-3", source: .hook("claude-code"),
            kind: .userPrompt("user asked something")))
        XCTAssertEqual(ShipLog.shared.sailor(for: "t-ingest-3")?.lastUserPrompt, "user asked something")
    }
}
