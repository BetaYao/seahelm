import XCTest
@testable import seahelm

final class WorktreeStatusAggregatorTests: XCTestCase {

    class MockDelegate: CabinStatusDelegate {
        var lastUpdatedStatus: CabinStatus?
        var paneChanges: [(worktreePath: String, paneIndex: Int, oldStatus: SailorStatus, newStatus: SailorStatus, lastMessage: String)] = []

        func worktreeStatusDidUpdate(_ status: CabinStatus) {
            lastUpdatedStatus = status
        }

        func paneStatusDidChange(worktreePath: String, paneIndex: Int, oldStatus: SailorStatus, newStatus: SailorStatus, lastMessage: String) {
            paneChanges.append((worktreePath, paneIndex, oldStatus, newStatus, lastMessage))
        }
    }

    func testSinglePaneUpdate() {
        let aggregator = CabinStatusAggregator()
        let mockDelegate = MockDelegate()
        aggregator.delegate = mockDelegate

        aggregator.registerTerminal("t1", worktreePath: "/repo/main", leafIndex: 0)

        aggregator.agentDidUpdate(
            terminalID: "t1",
            status: .running,
            lastMessage: "building..."
        )

        XCTAssertNotNil(mockDelegate.lastUpdatedStatus)
        XCTAssertEqual(mockDelegate.lastUpdatedStatus?.panes.count, 1)
        XCTAssertEqual(mockDelegate.lastUpdatedStatus?.panes[0].status, .running)
        XCTAssertEqual(mockDelegate.lastUpdatedStatus?.panes[0].paneIndex, 1)
        XCTAssertEqual(mockDelegate.lastUpdatedStatus?.mostRecentMessage, "building...")
    }

    func testMultiPaneUpdate() {
        let aggregator = CabinStatusAggregator()
        let mockDelegate = MockDelegate()
        aggregator.delegate = mockDelegate

        aggregator.registerTerminal("t1", worktreePath: "/repo/main", leafIndex: 0)
        aggregator.registerTerminal("t2", worktreePath: "/repo/main", leafIndex: 1)

        aggregator.agentDidUpdate(terminalID: "t1", status: .running, lastMessage: "building")
        aggregator.agentDidUpdate(terminalID: "t2", status: .idle, lastMessage: "done")

        let ws = mockDelegate.lastUpdatedStatus!
        XCTAssertEqual(ws.panes.count, 2)
        XCTAssertEqual(ws.statuses, [.running, .idle])
        // Representative pane = highest rollup rank (running t1 beats idle t2),
        // so status/message/index all describe that pane.
        XCTAssertEqual(ws.mostRecentMessage, "building")
        XCTAssertEqual(ws.mostRecentPaneIndex, 1)
    }

    func testStatusChangeFiresPaneCallback() {
        let aggregator = CabinStatusAggregator()
        let mockDelegate = MockDelegate()
        aggregator.delegate = mockDelegate

        aggregator.registerTerminal("t1", worktreePath: "/repo/main", leafIndex: 0)
        aggregator.agentDidUpdate(terminalID: "t1", status: .running, lastMessage: "")

        mockDelegate.paneChanges.removeAll()
        aggregator.agentDidUpdate(terminalID: "t1", status: .waiting, lastMessage: "need input")

        XCTAssertEqual(mockDelegate.paneChanges.count, 1)
        XCTAssertEqual(mockDelegate.paneChanges[0].paneIndex, 1)
        XCTAssertEqual(mockDelegate.paneChanges[0].oldStatus, .running)
        XCTAssertEqual(mockDelegate.paneChanges[0].newStatus, .waiting)
    }

    func testNoChangeDoesNotFireCallbacks() {
        let aggregator = CabinStatusAggregator()
        let mockDelegate = MockDelegate()
        aggregator.delegate = mockDelegate

        aggregator.registerTerminal("t1", worktreePath: "/repo/main", leafIndex: 0)
        aggregator.agentDidUpdate(terminalID: "t1", status: .running, lastMessage: "building")

        mockDelegate.lastUpdatedStatus = nil
        mockDelegate.paneChanges.removeAll()

        aggregator.agentDidUpdate(terminalID: "t1", status: .running, lastMessage: "building")

        XCTAssertNil(mockDelegate.lastUpdatedStatus)
        XCTAssertTrue(mockDelegate.paneChanges.isEmpty)
    }

    func testReindexOnPaneRemoval() {
        let aggregator = CabinStatusAggregator()
        let mockDelegate = MockDelegate()
        aggregator.delegate = mockDelegate

        aggregator.registerTerminal("t1", worktreePath: "/repo/main", leafIndex: 0)
        aggregator.registerTerminal("t2", worktreePath: "/repo/main", leafIndex: 1)
        aggregator.registerTerminal("t3", worktreePath: "/repo/main", leafIndex: 2)

        aggregator.agentDidUpdate(terminalID: "t1", status: .running, lastMessage: "a")
        aggregator.agentDidUpdate(terminalID: "t2", status: .idle, lastMessage: "b")
        aggregator.agentDidUpdate(terminalID: "t3", status: .waiting, lastMessage: "c")

        aggregator.unregisterTerminal("t2", worktreePath: "/repo/main")
        aggregator.updateLeafOrder(worktreePath: "/repo/main", terminalIDs: ["t1", "t3"])

        let ws = aggregator.status(for: "/repo/main")!
        XCTAssertEqual(ws.panes.count, 2)
        XCTAssertEqual(ws.panes[0].paneIndex, 1)
        XCTAssertEqual(ws.panes[1].paneIndex, 2)
    }
}
