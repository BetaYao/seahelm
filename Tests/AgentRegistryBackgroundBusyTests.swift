import XCTest
@testable import seahelm

final class AgentRegistryBackgroundBusyTests: XCTestCase {
    private let wt = "/wt-bg"

    override func setUp() {
        super.setUp()
        AgentRegistry.shared.registerForTesting(terminalID: "tbg", worktreePath: wt,
                                          branch: "main", project: "proj")
    }
    override func tearDown() {
        // Clear busy by sending a Stop with no running background tasks.
        AgentRegistry.shared.updateBackgroundBusy(from: event(.agentStop, data: ["background_tasks": []]))
        AgentRegistry.shared.unregister(terminalID: "tbg")
        super.tearDown()
    }

    private func event(_ type: WebhookEventType, data: [String: Any]? = nil) -> WebhookEvent {
        WebhookEvent(source: "claude-code", sessionId: "s", event: type, cwd: wt, timestamp: nil, data: data)
    }

    func testSubagentStartMarksBusy() {
        XCTAssertFalse(AgentRegistry.shared.isBackgroundBusy(cwd: wt))
        AgentRegistry.shared.updateBackgroundBusy(from: event(.subagentStart))
        XCTAssertTrue(AgentRegistry.shared.isBackgroundBusy(cwd: wt))
    }

    func testStopWithRunningBackgroundTaskStaysBusy() {
        let data: [String: Any] = ["background_tasks": [["id": "b1", "status": "running"]]]
        AgentRegistry.shared.updateBackgroundBusy(from: event(.agentStop, data: data))
        XCTAssertTrue(AgentRegistry.shared.isBackgroundBusy(cwd: wt))
    }

    func testStopWithNoRunningBackgroundClearsBusy() {
        AgentRegistry.shared.updateBackgroundBusy(from: event(.subagentStart))
        XCTAssertTrue(AgentRegistry.shared.isBackgroundBusy(cwd: wt))
        let data: [String: Any] = ["background_tasks": [["id": "b1", "status": "completed"]]]
        AgentRegistry.shared.updateBackgroundBusy(from: event(.subagentStop, data: data))
        XCTAssertFalse(AgentRegistry.shared.isBackgroundBusy(cwd: wt))
    }

    func testCwdInsideWorktreeResolves() {
        AgentRegistry.shared.updateBackgroundBusy(from: event(.subagentStart))
        XCTAssertTrue(AgentRegistry.shared.isBackgroundBusy(cwd: wt + "/sub/dir"))
    }
}
