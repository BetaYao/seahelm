import XCTest
@testable import seahelm

final class StopHookResponderTests: XCTestCase {
    func testParseSuggestions() {
        let msg = "Done.\nHere are next steps:\n\(StopHookResponder.sentinel) build | run tests | ship it"
        XCTAssertEqual(StopHookResponder.parseSuggestions(from: msg), ["build", "run tests", "ship it"])
    }

    func testParseSuggestionsTolerantOfBackticks() {
        let msg = "`\(StopHookResponder.sentinel) alpha | beta`"
        XCTAssertEqual(StopHookResponder.parseSuggestions(from: msg), ["alpha", "beta"])
    }

    func testParseSuggestionsCapsAtFive() {
        let msg = "\(StopHookResponder.sentinel) a | b | c | d | e | f | g"
        XCTAssertEqual(StopHookResponder.parseSuggestions(from: msg)?.count, 5)
    }

    func testParseSuggestionsAbsentReturnsNil() {
        XCTAssertNil(StopHookResponder.parseSuggestions(from: "Just a normal answer with no options."))
    }

    func testStripSentinelRemovesMarkerLine() {
        let msg = "The answer is 42.\n\(StopHookResponder.sentinel) a | b"
        XCTAssertEqual(StopHookResponder.stripSentinel(from: msg), "The answer is 42.")
    }

    func testRunningBackgroundTaskIsDetected() {
        let data: [String: Any] = [
            "background_tasks": [
                ["id": "b1", "type": "shell", "status": "running"]
            ],
        ]
        XCTAssertTrue(StopHookResponder.hasRunningBackgroundTask(data))
    }

    func testCompletedBackgroundTaskIsNotRunning() {
        let data: [String: Any] = [
            "background_tasks": [
                ["id": "b1", "type": "shell", "status": "completed"]
            ],
        ]
        XCTAssertFalse(StopHookResponder.hasRunningBackgroundTask(data))
    }
}
