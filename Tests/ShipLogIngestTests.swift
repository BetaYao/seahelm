import XCTest
@testable import seahelm

final class ShipLogIngestTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ShipLog.shared.onStatusTransition = nil
        for agent in ShipLog.shared.allSailors() {
            ShipLog.shared.unregister(terminalID: agent.id)
        }
    }

    override func tearDown() {
        // Drain pending main-queue async blocks (status transitions) before clearing the callback,
        // so they don't fire into the next test's onStatusTransition handler.
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        ShipLog.shared.onStatusTransition = nil
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
        let report = StatusReport(status: .waiting, lastMessage: "need input", activityEvents: [])
        ShipLog.shared.ingest(terminalID: "t-ingest-1", report: report, lastUserPrompt: "")
        XCTAssertEqual(ShipLog.shared.sailor(for: "t-ingest-1")?.status, .waiting)
    }

    func testIngestUpdatesLastMessage() {
        ShipLog.shared.registerForTesting(
            terminalID: "t-ingest-2",
            worktreePath: "/tmp/ingest-test2",
            branch: "main",
            project: "IngestTest"
        )
        let report = StatusReport(status: .running, lastMessage: "doing stuff", activityEvents: [])
        ShipLog.shared.ingest(terminalID: "t-ingest-2", report: report, lastUserPrompt: "")
        XCTAssertEqual(ShipLog.shared.sailor(for: "t-ingest-2")?.lastMessage, "doing stuff")
    }

    func testIngestForUnknownTerminalIsNoop() {
        // Should not crash for unregistered terminal
        let report = StatusReport(status: .waiting, lastMessage: "hello", activityEvents: [])
        ShipLog.shared.ingest(terminalID: "t-nonexistent-99", report: report, lastUserPrompt: "")
        XCTAssertNil(ShipLog.shared.sailor(for: "t-nonexistent-99"))
    }

    func testIngestLastUserPrompt() {
        ShipLog.shared.registerForTesting(
            terminalID: "t-ingest-3",
            worktreePath: "/tmp/ingest-test3",
            branch: "main",
            project: "IngestTest"
        )
        let report = StatusReport(status: .waiting, lastMessage: "waiting", activityEvents: [])
        ShipLog.shared.ingest(terminalID: "t-ingest-3", report: report, lastUserPrompt: "user asked something")
        XCTAssertEqual(ShipLog.shared.sailor(for: "t-ingest-3")?.lastUserPrompt, "user asked something")
    }
}
