import XCTest
@testable import seahelm

final class AgentRegistryIngestTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AgentRegistry.shared.onOutcome = nil
        for agent in AgentRegistry.shared.allPanes() {
            AgentRegistry.shared.unregister(terminalID: agent.id)
        }
    }

    override func tearDown() {
        // Drain pending main-queue async blocks before clearing the callback,
        // so they don't fire into the next test's onOutcome handler.
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        AgentRegistry.shared.onOutcome = nil
        for agent in AgentRegistry.shared.allPanes() {
            AgentRegistry.shared.unregister(terminalID: agent.id)
        }
        super.tearDown()
    }

    func testIngestUpdatesStatus() {
        AgentRegistry.shared.registerForTesting(
            terminalID: "t-ingest-1",
            worktreePath: "/tmp/ingest-test",
            branch: "main",
            project: "IngestTest"
        )
        AgentRegistry.shared.ingest(NormalizedEvent(
            terminalID: "t-ingest-1", source: .scan,
            kind: .screenObserved(status: .waiting, message: "need input",
                                  activity: [], commandLine: nil, agentType: .unknown,
                                  roundDuration: 0, tasks: [])))
        XCTAssertEqual(AgentRegistry.shared.pane(for: "t-ingest-1")?.status, .waiting)
    }

    func testIngestUpdatesLastMessage() {
        AgentRegistry.shared.registerForTesting(
            terminalID: "t-ingest-2",
            worktreePath: "/tmp/ingest-test2",
            branch: "main",
            project: "IngestTest"
        )
        AgentRegistry.shared.ingest(NormalizedEvent(
            terminalID: "t-ingest-2", source: .scan,
            kind: .screenObserved(status: .running, message: "doing stuff",
                                  activity: [], commandLine: nil, agentType: .unknown,
                                  roundDuration: 0, tasks: [])))
        XCTAssertEqual(AgentRegistry.shared.pane(for: "t-ingest-2")?.lastMessage, "doing stuff")
    }

    func testIngestForUnknownTerminalIsNoop() {
        // Should not crash for unregistered terminal
        AgentRegistry.shared.ingest(NormalizedEvent(
            terminalID: "t-nonexistent-99", source: .scan,
            kind: .screenObserved(status: .waiting, message: "hello",
                                  activity: [], commandLine: nil, agentType: .unknown,
                                  roundDuration: 0, tasks: [])))
        XCTAssertNil(AgentRegistry.shared.pane(for: "t-nonexistent-99"))
    }

    func testIngestLastUserPrompt() {
        AgentRegistry.shared.registerForTesting(
            terminalID: "t-ingest-3",
            worktreePath: "/tmp/ingest-test3",
            branch: "main",
            project: "IngestTest"
        )
        AgentRegistry.shared.ingest(NormalizedEvent(
            terminalID: "t-ingest-3", source: .hook("claude-code"),
            kind: .userPrompt("user asked something")))
        XCTAssertEqual(AgentRegistry.shared.pane(for: "t-ingest-3")?.lastUserPrompt, "user asked something")
    }
}
