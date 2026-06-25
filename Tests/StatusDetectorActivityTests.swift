// Tests/StatusDetectorActivityTests.swift
import XCTest
@testable import seahelm

final class StatusDetectorActivityTests: XCTestCase {
    let detector = StatusDetector()

    func testExtractClaudeCodeToolLines() {
        let text = """
        ⏺ Read(src/main.swift)
        ⏺ Edit(src/auth/login.swift)
        ⏺ Bash(swift test --filter Auth)
        """
        let events = detector.extractActivityEvents(from: text)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].tool, "Bash")
        XCTAssertEqual(events[0].detail, "swift test --filter Auth")
        XCTAssertEqual(events[1].tool, "Edit")
        XCTAssertEqual(events[2].tool, "Read")
    }

    func testExtractWithErrorMarker() {
        let text = """
        ⏺ Read(config.json)
        ✗ Bash(swift build) — error
        """
        let events = detector.extractActivityEvents(from: text)
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0].isError)
        XCTAssertFalse(events[1].isError)
    }

    func testExtractEmptyTextReturnsEmpty() {
        let events = detector.extractActivityEvents(from: "")
        XCTAssertTrue(events.isEmpty)
    }

    func testExtractNoToolLinesReturnsEmpty() {
        let text = "$ echo hello\nhello\n$ "
        let events = detector.extractActivityEvents(from: text)
        XCTAssertTrue(events.isEmpty)
    }

    func testExtractTriangleMarkerLines() {
        let text = """
        ▸ Read   src/main.swift
        ▸ Grep   "pattern"
        """
        let events = detector.extractActivityEvents(from: text)
        XCTAssertEqual(events.count, 2)
    }

    func testMaxEventsFromText() {
        var lines = ""
        for i in 0..<30 {
            lines += "⏺ Read(file\(i).swift)\n"
        }
        let events = detector.extractActivityEvents(from: lines)
        XCTAssertLessThanOrEqual(events.count, 20)
    }
}
