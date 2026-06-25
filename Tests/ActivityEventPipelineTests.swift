import XCTest
@testable import seahelm

final class ActivityEventPipelineTests: XCTestCase {

    func testExtractorProducesValidEvents() {
        let data: [String: Any] = [
            "tool_name": "Read",
            "tool_input": ["file_path": "/Users/dev/project/Sources/Core/ShipLog.swift"],
        ]
        let event = WebhookEvent(
            source: "claude-code",
            sessionId: "s1",
            event: .toolUseEnd,
            cwd: "/Users/dev/project",
            timestamp: nil,
            data: data
        )

        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertEqual(activity.tool, "Read")
        XCTAssertEqual(activity.detail, "Core/ShipLog.swift")
        XCTAssertFalse(activity.isError)
    }

    func testExtractorHandlesBashError() {
        let data: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": "swift test"],
            "tool_result": "Test Suite 'All tests' failed.\nExit code: 1",
        ]
        let event = WebhookEvent(
            source: "claude-code",
            sessionId: "s1",
            event: .toolUseEnd,
            cwd: "/tmp",
            timestamp: nil,
            data: data
        )

        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertEqual(activity.tool, "Bash")
        XCTAssertTrue(activity.isError)
    }

    func testRingBufferMaintainsOrder() {
        var buffer: [ActivityEvent] = []
        let tools = ["Read", "Edit", "Bash", "Grep", "Write"]
        for tool in tools {
            let event = ActivityEvent(tool: tool, detail: "test", isError: false, timestamp: Date())
            ShipLog.appendToRingBuffer(&buffer, event: event, maxSize: 20)
        }
        XCTAssertEqual(buffer[0].tool, "Write")
        XCTAssertEqual(buffer[4].tool, "Read")
    }

    func testTextExtractionNewestFirst() {
        let detector = StatusDetector()
        let text = """
        ⏺ Read(first.swift)
        ⏺ Edit(second.swift)
        ⏺ Bash(third command)
        """
        let events = detector.extractActivityEvents(from: text)
        XCTAssertEqual(events[0].tool, "Bash")
        XCTAssertEqual(events[2].tool, "Read")
    }
}
