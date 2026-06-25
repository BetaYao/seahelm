// Tests/ShipLogActivityEventTests.swift
import XCTest
@testable import seahelm

final class ShipLogActivityEventTests: XCTestCase {

    func testAppendActivityEventAddsToFront() {
        var events: [ActivityEvent] = []
        let event1 = ActivityEvent(tool: "Read", detail: "a.swift", isError: false, timestamp: Date())
        let event2 = ActivityEvent(tool: "Edit", detail: "b.swift", isError: false, timestamp: Date())

        ShipLog.appendToRingBuffer(&events, event: event1, maxSize: 20)
        ShipLog.appendToRingBuffer(&events, event: event2, maxSize: 20)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].tool, "Edit")
        XCTAssertEqual(events[1].tool, "Read")
    }

    func testRingBufferCapsAtMaxSize() {
        var events: [ActivityEvent] = []
        for i in 0..<25 {
            let event = ActivityEvent(tool: "Read", detail: "file\(i).swift", isError: false, timestamp: Date())
            ShipLog.appendToRingBuffer(&events, event: event, maxSize: 20)
        }
        XCTAssertEqual(events.count, 20)
        XCTAssertEqual(events[0].detail, "file24.swift")
    }

    func testClearActivityEventsEmptiesBuffer() {
        var events: [ActivityEvent] = []
        let event = ActivityEvent(tool: "Read", detail: "a.swift", isError: false, timestamp: Date())
        ShipLog.appendToRingBuffer(&events, event: event, maxSize: 20)
        XCTAssertEqual(events.count, 1)
        events.removeAll()
        XCTAssertTrue(events.isEmpty)
    }

    func testUpsertLatestActivityEventReplacesMatchingNewestEvent() {
        let head = ShipLog.shared
        let surface = Station()
        head.register(station: surface, worktreePath: "/tmp/project", branch: "main", project: "project", startedAt: nil)
        defer { head.unregister(terminalID: surface.id) }

        let first = ActivityEvent(tool: "Bash", detail: "swift test", isError: false, timestamp: Date())
        let second = ActivityEvent(tool: "Bash", detail: "swift test", isError: true, timestamp: Date())

        head.upsertLatestActivityEvent(first, forTerminalID: surface.id)
        head.upsertLatestActivityEvent(second, forTerminalID: surface.id)

        let events = head.agent(for: surface.id)?.activityEvents ?? []
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].tool, "Bash")
        XCTAssertTrue(events[0].isError)
    }
}
