import XCTest
@testable import seahelm

final class ActivityFeedIntegrationTests: XCTestCase {
    func testCardConfigureWithActivityEvents() {
        let card = AgentCardView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let events = [
            ActivityEvent(tool: "Read", detail: "main.swift", isError: false, timestamp: Date()),
            ActivityEvent(tool: "Bash", detail: "test failed", isError: true, timestamp: Date(timeIntervalSinceNow: -5)),
        ]

        card.configure(
            id: "test-1",
            project: "myproject",
            thread: "main",
            status: "running",
            lastMessage: "some message",
            totalDuration: "00:05:00",
            roundDuration: "00:01:00",
            activityEvents: events
        )

        // messageLabel should be hidden when feed is active
        let allLabels = card.terminalContainer.subviews.compactMap { $0 as? NSTextField }
        let visibleLabels = allLabels.filter { !$0.isHidden }

        // Feed renders one label per event, and messageLabel is hidden
        XCTAssertGreaterThanOrEqual(allLabels.count, 3, "terminalContainer should have messageLabel + 2 feed labels")
        XCTAssertGreaterThanOrEqual(visibleLabels.count, 2, "Should have visible feed labels for each event")

        // messageLabel itself should be hidden
        let hiddenLabels = allLabels.filter { $0.isHidden }
        XCTAssertEqual(hiddenLabels.count, 1, "messageLabel should be the one hidden label")
    }

    func testTasksTakePriorityOverFeed() {
        let card = AgentCardView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let events = [
            ActivityEvent(tool: "Read", detail: "main.swift", isError: false, timestamp: Date()),
        ]
        let tasks = [
            TaskItem(id: "1", subject: "Do something", status: .inProgress),
        ]

        card.configure(
            id: "test-1",
            project: "myproject",
            thread: "main",
            status: "running",
            lastMessage: "",
            totalDuration: "00:05:00",
            roundDuration: "00:01:00",
            tasks: tasks,
            activityEvents: events
        )

        // When tasks exist, feed labels are cleared and only messageLabel remains
        let allLabels = card.terminalContainer.subviews.compactMap { $0 as? NSTextField }
        XCTAssertEqual(allLabels.count, 1, "Only messageLabel should be present when tasks exist")

        // messageLabel should be visible (not hidden) and show the task content
        let messageLabel = allLabels.first
        XCTAssertNotNil(messageLabel)
        XCTAssertFalse(messageLabel!.isHidden, "messageLabel should be visible when tasks are shown")
        XCTAssertTrue(messageLabel!.attributedStringValue.string.contains("Do something"),
                      "messageLabel should display the task subject")
    }

    func testLastMessageShownWhenNoTasksOrEvents() {
        let card = AgentCardView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        card.configure(
            id: "test-1",
            project: "myproject",
            thread: "main",
            status: "idle",
            lastMessage: "Waiting for input",
            totalDuration: "00:01:00",
            roundDuration: "00:00:30"
        )

        let allLabels = card.terminalContainer.subviews.compactMap { $0 as? NSTextField }
        XCTAssertEqual(allLabels.count, 1, "Only messageLabel should be present for plain last message")

        let messageLabel = allLabels.first
        XCTAssertNotNil(messageLabel)
        XCTAssertFalse(messageLabel!.isHidden, "messageLabel should be visible for last message")
        XCTAssertEqual(messageLabel!.attributedStringValue.string, "Waiting for input")
    }

    func testEmptyActivityEventsShowsLastMessage() {
        let card = AgentCardView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        card.configure(
            id: "test-1",
            project: "myproject",
            thread: "main",
            status: "idle",
            lastMessage: "No events yet",
            totalDuration: "00:00:10",
            roundDuration: "00:00:05",
            activityEvents: []
        )

        let allLabels = card.terminalContainer.subviews.compactMap { $0 as? NSTextField }
        XCTAssertEqual(allLabels.count, 1, "Only messageLabel when activity events are empty")

        let messageLabel = allLabels.first
        XCTAssertNotNil(messageLabel)
        XCTAssertFalse(messageLabel!.isHidden)
        XCTAssertEqual(messageLabel!.attributedStringValue.string, "No events yet")
    }
}
