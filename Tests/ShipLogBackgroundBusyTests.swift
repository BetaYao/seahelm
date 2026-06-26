import XCTest
@testable import seahelm

final class ShipLogBackgroundBusyTests: XCTestCase {
    private let wt = "/wt-bg"

    override func setUp() {
        super.setUp()
        ShipLog.shared.registerForTesting(terminalID: "tbg", worktreePath: wt,
                                          branch: "main", project: "proj")
    }
    override func tearDown() {
        // Clear busy by sending a Stop with no running background tasks.
        ShipLog.shared.updateBackgroundBusy(from: event(.agentStop, data: ["background_tasks": []]))
        ShipLog.shared.unregister(terminalID: "tbg")
        super.tearDown()
    }

    private func event(_ type: WebhookEventType, data: [String: Any]? = nil) -> WebhookEvent {
        WebhookEvent(source: "claude-code", sessionId: "s", event: type, cwd: wt, timestamp: nil, data: data)
    }

    func testSubagentStartMarksBusy() {
        XCTAssertFalse(ShipLog.shared.isBackgroundBusy(cwd: wt))
        ShipLog.shared.updateBackgroundBusy(from: event(.subagentStart))
        XCTAssertTrue(ShipLog.shared.isBackgroundBusy(cwd: wt))
    }

    func testStopWithRunningBackgroundTaskStaysBusy() {
        let data: [String: Any] = ["background_tasks": [["id": "b1", "status": "running"]]]
        ShipLog.shared.updateBackgroundBusy(from: event(.agentStop, data: data))
        XCTAssertTrue(ShipLog.shared.isBackgroundBusy(cwd: wt))
    }

    func testStopWithNoRunningBackgroundClearsBusy() {
        ShipLog.shared.updateBackgroundBusy(from: event(.subagentStart))
        XCTAssertTrue(ShipLog.shared.isBackgroundBusy(cwd: wt))
        let data: [String: Any] = ["background_tasks": [["id": "b1", "status": "completed"]]]
        ShipLog.shared.updateBackgroundBusy(from: event(.subagentStop, data: data))
        XCTAssertFalse(ShipLog.shared.isBackgroundBusy(cwd: wt))
    }

    func testCwdInsideWorktreeResolves() {
        ShipLog.shared.updateBackgroundBusy(from: event(.subagentStart))
        XCTAssertTrue(ShipLog.shared.isBackgroundBusy(cwd: wt + "/sub/dir"))
    }
}
