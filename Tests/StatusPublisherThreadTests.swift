import XCTest
@testable import seahelm

class StatusPublisherThreadTests: XCTestCase {
    func testConcurrentUpdateAndPollDoesNotCrash() {
        let publisher = StatusPublisher()
        let expectation = expectation(description: "concurrent access")
        expectation.expectedFulfillmentCount = 10

        for _ in 0..<10 {
            DispatchQueue.global().async {
                publisher.updateSurfaces([String: SplitTree]())
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testBackendCaptureRunsEveryStrideCycle() {
        // offset 0: fires on cycles that are multiples of the stride, nothing between.
        XCTAssertTrue(StatusPublisher.shouldBackendCapture(pollCycle: 0, offset: 0, stride: 3))
        XCTAssertFalse(StatusPublisher.shouldBackendCapture(pollCycle: 1, offset: 0, stride: 3))
        XCTAssertFalse(StatusPublisher.shouldBackendCapture(pollCycle: 2, offset: 0, stride: 3))
        XCTAssertTrue(StatusPublisher.shouldBackendCapture(pollCycle: 3, offset: 0, stride: 3))
    }

    func testBackendCaptureStaggersByOffset() {
        // Two panes with different offsets fire on different cycles (spread load),
        // and each still fires exactly once per stride window.
        let stride = 3
        let firesA = (0..<3).filter { StatusPublisher.shouldBackendCapture(pollCycle: $0, offset: 0, stride: stride) }
        let firesB = (0..<3).filter { StatusPublisher.shouldBackendCapture(pollCycle: $0, offset: 1, stride: stride) }
        XCTAssertEqual(firesA.count, 1)
        XCTAssertEqual(firesB.count, 1)
        XCTAssertNotEqual(firesA, firesB)
    }

    func testBackendCaptureHandlesNegativeOffset() {
        // stableHash-derived offsets can be negative after truncation; the helper
        // must never trap or skew the modulo. Every cycle window still fires once.
        let stride = 4
        let fires = (0..<4).filter { StatusPublisher.shouldBackendCapture(pollCycle: $0, offset: -7, stride: stride) }
        XCTAssertEqual(fires.count, 1)
    }

    func testAgentDefSelectionUsesExistingCodexType() {
        let content = "Would you like to run the following command?"
        let candidates = SailorDetectConfig.default.agents.map { ($0.name.lowercased(), $0) }

        let agentDef = StatusPublisher.findSailorDef(
            inLowercased: content.lowercased(),
            existingSailorType: .codex,
            candidates: candidates
        )

        XCTAssertEqual(agentDef?.name, "codex")
    }
}
