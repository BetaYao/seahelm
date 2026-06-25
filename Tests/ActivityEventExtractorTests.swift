// Tests/ActivityEventExtractorTests.swift
import XCTest
@testable import seahelm

final class ActivityEventExtractorTests: XCTestCase {

    func testReadToolExtractsBasename() {
        let event = makeWebhookEvent(tool: "Read", input: ["file_path": "/Users/dev/project/src/auth/login.swift"])
        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertEqual(activity.tool, "Read")
        XCTAssertEqual(activity.detail, "auth/login.swift")
        XCTAssertFalse(activity.isError)
    }

    func testEditToolExtractsPathAndLine() {
        let event = makeWebhookEvent(tool: "Edit", input: [
            "file_path": "/Users/dev/project/src/main.swift",
            "old_string": "let x = 1",
            "new_string": "let x = 2",
        ])
        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertEqual(activity.tool, "Edit")
        XCTAssertTrue(activity.detail.contains("main.swift"))
    }

    func testBashToolExtractsCommand() {
        let event = makeWebhookEvent(tool: "Bash", input: ["command": "swift test --filter AuthTests"])
        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertEqual(activity.tool, "Bash")
        XCTAssertEqual(activity.detail, "swift test --filter AuthTests")
    }

    func testBashToolTruncatesLongCommand() {
        let longCmd = String(repeating: "a", count: 100)
        let event = makeWebhookEvent(tool: "Bash", input: ["command": longCmd])
        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertTrue(activity.detail.count <= 63)
    }

    func testGrepToolExtractsPattern() {
        let event = makeWebhookEvent(tool: "Grep", input: ["pattern": "validateToken"])
        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertEqual(activity.detail, "\"validateToken\"")
    }

    func testGlobToolExtractsPattern() {
        let event = makeWebhookEvent(tool: "Glob", input: ["pattern": "**/*.swift"])
        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertEqual(activity.detail, "**/*.swift")
    }

    func testWriteToolExtractsPath() {
        let event = makeWebhookEvent(tool: "Write", input: ["file_path": "/tmp/project/config.json"])
        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertEqual(activity.detail, "project/config.json")
    }

    func testAgentToolExtractsPrompt() {
        let event = makeWebhookEvent(tool: "Agent", input: ["prompt": "Explore the grid card UI code and find all rendering logic"])
        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertTrue(activity.detail.count <= 43)
    }

    func testUnknownToolUsesToolName() {
        let event = makeWebhookEvent(tool: "TaskCreate", input: ["subject": "Do something"])
        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertEqual(activity.tool, "TaskCreate")
        XCTAssertEqual(activity.detail, "TaskCreate")
    }

    func testToolUseFailedIsError() {
        let event = makeWebhookEvent(tool: "Bash", input: [:], eventType: .toolUseFailed)
        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertTrue(activity.isError)
    }

    func testToolUseEndIsNotError() {
        let event = makeWebhookEvent(tool: "Read", input: ["file_path": "test.swift"])
        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertFalse(activity.isError)
    }

    func testBashWithNonZeroExitIsError() {
        let event = makeWebhookEvent(tool: "Bash", input: ["command": "swift test"], result: "Exit code: 1\nTest failed")
        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertTrue(activity.isError)
    }

    func testBashWithZeroExitIsNotError() {
        let event = makeWebhookEvent(tool: "Bash", input: ["command": "swift test"], result: "Exit code: 0\nAll tests passed")
        let activity = ActivityEventExtractor.extract(from: event)
        XCTAssertFalse(activity.isError)
    }

    func testShortPathLastTwoComponents() {
        XCTAssertEqual(ActivityEventExtractor.shortPath("/a/b/c/d/e.swift"), "d/e.swift")
    }

    func testShortPathSingleComponent() {
        XCTAssertEqual(ActivityEventExtractor.shortPath("file.swift"), "file.swift")
    }

    func testShortPathTwoComponents() {
        XCTAssertEqual(ActivityEventExtractor.shortPath("/a/b.swift"), "a/b.swift")
    }

    func testSummaryIncludesToolAndDetail() {
        let summary = ActivityEventExtractor.summary(
            toolName: "Bash",
            toolInput: ["command": "swift test --filter AuthTests"]
        )
        XCTAssertEqual(summary, "Bash swift test --filter AuthTests")
    }

    func testSummaryIncludesFailurePrefix() {
        let summary = ActivityEventExtractor.summary(
            toolName: "Read",
            toolInput: ["file_path": "/tmp/project/file.swift"],
            isError: true
        )
        XCTAssertEqual(summary, "Failed Read project/file.swift")
    }

    private func makeWebhookEvent(tool: String, input: [String: Any], eventType: WebhookEventType = .toolUseEnd, result: String? = nil) -> WebhookEvent {
        var data: [String: Any] = ["tool_name": tool, "tool_input": input]
        if let result { data["tool_result"] = result }
        return WebhookEvent(
            source: "claude-code",
            sessionId: "test-session",
            event: eventType,
            cwd: "/tmp/test",
            timestamp: nil,
            data: data
        )
    }
}
