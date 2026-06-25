import XCTest
@testable import seahelm

final class WebhookTaskParsingTests: XCTestCase {

    private func makeProvider() -> WebhookStatusProvider {
        let provider = WebhookStatusProvider()
        provider.updateWorktrees(["/tmp/project"])
        return provider
    }

    private func taskCreateEvent(sessionId: String = "sess1", subject: String) -> WebhookEvent {
        let toolInput: [String: Any] = ["subject": subject, "description": "test"]
        return WebhookEvent(
            source: "claude-code",
            sessionId: sessionId,
            event: .toolUseEnd,
            cwd: "/tmp/project",
            timestamp: nil,
            data: ["tool_name": "TaskCreate", "tool_input": toolInput]
        )
    }

    private func taskUpdateEvent(sessionId: String = "sess1", taskId: String, status: String) -> WebhookEvent {
        WebhookEvent(
            source: "claude-code",
            sessionId: sessionId,
            event: .toolUseEnd,
            cwd: "/tmp/project",
            timestamp: nil,
            data: ["tool_name": "TaskUpdate", "tool_input": ["taskId": taskId, "status": status]]
        )
    }

    private func agentStopEvent(sessionId: String = "sess1") -> WebhookEvent {
        WebhookEvent(
            source: "claude-code",
            sessionId: sessionId,
            event: .agentStop,
            cwd: "/tmp/project",
            timestamp: nil,
            data: ["stop_reason": "end_turn"]
        )
    }

    func testTaskCreateAddsItem() {
        let provider = makeProvider()
        provider.handleEvent(taskCreateEvent(subject: "Add tests"))
        let tasks = provider.tasks(for: "/tmp/project")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].subject, "Add tests")
        XCTAssertEqual(tasks[0].status, .pending)
        XCTAssertEqual(tasks[0].id, "1")
    }

    func testMultipleTasksGetIncrementingIds() {
        let provider = makeProvider()
        provider.handleEvent(taskCreateEvent(subject: "Task A"))
        provider.handleEvent(taskCreateEvent(subject: "Task B"))
        provider.handleEvent(taskCreateEvent(subject: "Task C"))
        let tasks = provider.tasks(for: "/tmp/project")
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks.map(\.id), ["1", "2", "3"])
    }

    func testTaskUpdateChangesStatus() {
        let provider = makeProvider()
        provider.handleEvent(taskCreateEvent(subject: "Write code"))
        provider.handleEvent(taskUpdateEvent(taskId: "1", status: "in_progress"))
        let tasks = provider.tasks(for: "/tmp/project")
        XCTAssertEqual(tasks[0].status, .inProgress)
    }

    func testTaskUpdateToCompleted() {
        let provider = makeProvider()
        provider.handleEvent(taskCreateEvent(subject: "Write code"))
        provider.handleEvent(taskUpdateEvent(taskId: "1", status: "completed"))
        let tasks = provider.tasks(for: "/tmp/project")
        XCTAssertEqual(tasks[0].status, .completed)
    }

    func testAgentStopClearsTasks() {
        let provider = makeProvider()
        provider.handleEvent(taskCreateEvent(subject: "Write code"))
        provider.handleEvent(agentStopEvent())
        let tasks = provider.tasks(for: "/tmp/project")
        XCTAssertTrue(tasks.isEmpty)
    }

    func testNoTasksForUnknownWorktree() {
        let provider = makeProvider()
        provider.handleEvent(taskCreateEvent(subject: "Write code"))
        let tasks = provider.tasks(for: "/tmp/other")
        XCTAssertTrue(tasks.isEmpty)
    }

    func testNonTaskToolUseIgnored() {
        let provider = makeProvider()
        let event = WebhookEvent(
            source: "claude-code",
            sessionId: "sess1",
            event: .toolUseEnd,
            cwd: "/tmp/project",
            timestamp: nil,
            data: ["tool_name": "Bash", "tool_input": ["command": "ls"]]
        )
        provider.handleEvent(event)
        let tasks = provider.tasks(for: "/tmp/project")
        XCTAssertTrue(tasks.isEmpty)
    }
}
