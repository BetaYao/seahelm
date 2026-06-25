// Tests/ActivityFeedRendererTests.swift
import XCTest
@testable import seahelm

final class ActivityFeedRendererTests: XCTestCase {
    func testEmptyEventsReturnsEmpty() {
        let lines = ActivityFeedRenderer.render(events: [], maxLines: 10)
        XCTAssertTrue(lines.isEmpty)
    }

    func testNormalEventFormat() {
        let event = ActivityEvent(tool: "Read", detail: "main.swift", isError: false, timestamp: Date())
        let lines = ActivityFeedRenderer.render(events: [event], maxLines: 10)
        XCTAssertEqual(lines.count, 1)
        let text = lines[0].string
        XCTAssertTrue(text.contains("▸"), "Normal marker expected")
        XCTAssertTrue(text.contains("Read"), "Tool name expected")
        XCTAssertTrue(text.contains("main.swift"), "Detail expected")
    }

    func testErrorEventFormat() {
        let event = ActivityEvent(tool: "Bash", detail: "test failed", isError: true, timestamp: Date())
        let lines = ActivityFeedRenderer.render(events: [event], maxLines: 10)
        XCTAssertEqual(lines.count, 1)
        let text = lines[0].string
        XCTAssertTrue(text.contains("✗"), "Error marker expected")
        XCTAssertTrue(text.contains("Bash"), "Tool name expected")
    }

    func testNewestFirstOrdering() {
        let old = ActivityEvent(tool: "Read", detail: "old.swift", isError: false, timestamp: Date(timeIntervalSinceNow: -10))
        let new = ActivityEvent(tool: "Edit", detail: "new.swift", isError: false, timestamp: Date())
        // Events passed in newest-first order (caller is responsible for ordering)
        let lines = ActivityFeedRenderer.render(events: [new, old], maxLines: 10)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].string.contains("Edit"), "Newest should be first")
        XCTAssertTrue(lines[1].string.contains("Read"), "Oldest should be second")
    }

    func testMaxLinesTruncation() {
        let events = (0..<5).map { i in
            ActivityEvent(tool: "Read", detail: "file\(i).swift", isError: false, timestamp: Date())
        }
        let lines = ActivityFeedRenderer.render(events: events, maxLines: 3)
        XCTAssertEqual(lines.count, 3)
    }

    func testOpacityDecreases() {
        let events = (0..<4).map { i in
            ActivityEvent(tool: "Read", detail: "file\(i).swift", isError: false, timestamp: Date())
        }
        let lines = ActivityFeedRenderer.render(events: events, maxLines: 10)
        // Check that opacity metadata decreases for later entries
        for i in 1..<lines.count {
            let prevOpacity = ActivityFeedRenderer.opacity(forIndex: i - 1, total: lines.count)
            let curOpacity = ActivityFeedRenderer.opacity(forIndex: i, total: lines.count)
            XCTAssertLessThanOrEqual(curOpacity, prevOpacity, "Opacity should decrease for older entries")
        }
    }
}
