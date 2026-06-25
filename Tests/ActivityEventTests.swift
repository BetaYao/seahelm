import XCTest
@testable import seahelm

final class ActivityEventTests: XCTestCase {
    func testActivityEventProperties() {
        let date = Date()
        let event = ActivityEvent(tool: "Read", detail: "src/main.swift", isError: false, timestamp: date)
        XCTAssertEqual(event.tool, "Read")
        XCTAssertEqual(event.detail, "src/main.swift")
        XCTAssertFalse(event.isError)
        XCTAssertEqual(event.timestamp, date)
    }

    func testErrorEvent() {
        let event = ActivityEvent(tool: "Bash", detail: "swift test — 2 failures", isError: true, timestamp: Date())
        XCTAssertTrue(event.isError)
        XCTAssertEqual(event.tool, "Bash")
    }
}
