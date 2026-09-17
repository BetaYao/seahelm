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

    func testUnchangedFrameSkipsWhenScanStateIsSynchronized() {
        XCTAssertTrue(StatusPublisher.shouldSkipUnchangedFrame(
            lastHash: 42,
            contentHash: 42,
            committedScanStatus: .idle,
            publishedScanStatus: .idle,
            forceRecheck: false))
    }

    func testUnchangedFrameDoesNotSkipStalePublishedScanState() {
        XCTAssertFalse(StatusPublisher.shouldSkipUnchangedFrame(
            lastHash: 42,
            contentHash: 42,
            committedScanStatus: .idle,
            publishedScanStatus: .running,
            forceRecheck: false))
    }

    func testPeriodicRecheckDoesNotSkipSynchronizedFrame() {
        XCTAssertFalse(StatusPublisher.shouldSkipUnchangedFrame(
            lastHash: 42,
            contentHash: 42,
            committedScanStatus: .idle,
            publishedScanStatus: .idle,
            forceRecheck: true))
    }

    /// Stop reported, scan still holding Running: an unchanged frame must be
    /// looked at again or the hold outlives the turn until the next forced recheck.
    func testUnchangedFrameIsRecheckedWhileAStoppedTurnIsHeldRunning() {
        XCTAssertFalse(StatusPublisher.shouldSkipUnchangedFrame(
            lastHash: 42, contentHash: 42, committedScanStatus: .running,
            publishedScanStatus: .running, forceRecheck: false, hookStatus: .idle))
        XCTAssertTrue(StatusPublisher.shouldSkipUnchangedFrame(
            lastHash: 42, contentHash: 42, committedScanStatus: .idle,
            publishedScanStatus: .idle, forceRecheck: false, hookStatus: .idle))
        XCTAssertTrue(StatusPublisher.shouldSkipUnchangedFrame(
            lastHash: 42, contentHash: 42, committedScanStatus: .running,
            publishedScanStatus: .running, forceRecheck: false, hookStatus: .running),
            "mid-turn frames still skip as before")
    }

    func testDefaultedIdleIsHeldMidTurnButCommitsOnceTheHookStopped() {
        let blank = Detection(state: .idle, isDefaulted: true)
        let midTurn = DebouncedStatusTracker()
        midTurn.update(status: .running)
        for _ in 0..<5 {
            let idle = StatusPublisher.idleObservation(blank, hookStatus: .running)
            XCTAssertFalse(midTurn.update(status: .idle, visibleIdle: idle.visibleIdle, defaulted: idle.defaulted))
        }
        XCTAssertEqual(midTurn.currentStatus, .running, "a thinking gap is not the end of a turn")

        let stopped = DebouncedStatusTracker()
        stopped.update(status: .running)
        let idle = StatusPublisher.idleObservation(blank, hookStatus: .idle)
        XCTAssertTrue(stopped.update(status: .idle, visibleIdle: idle.visibleIdle, defaulted: idle.defaulted))
        XCTAssertEqual(stopped.currentStatus, .idle)
    }

    func testRoundCountsFromTheLaterOfScanStartAndPrompt() {
        let scan = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(StatusPublisher.roundStart(scanRunningSince: nil, turnStarted: scan),
                     "not running on screen, no round")
        XCTAssertEqual(StatusPublisher.roundStart(scanRunningSince: scan, turnStarted: nil), scan)
        XCTAssertEqual(StatusPublisher.roundStart(scanRunningSince: scan,
                                                  turnStarted: Date(timeIntervalSince1970: 1074)),
                       Date(timeIntervalSince1970: 1074),
                       "a prompt after the scan's start is a new round")
        XCTAssertEqual(StatusPublisher.roundStart(scanRunningSince: scan,
                                                  turnStarted: Date(timeIntervalSince1970: 990)), scan)
    }

    func testAgentDefSelectionUsesExistingCodexType() {
        let content = "Would you like to run the following command?"
        let candidates = AgentDetectConfig.default.agents.map { ($0.name.lowercased(), $0) }

        let agentDef = StatusPublisher.findAgentDef(
            inLowercased: content.lowercased(),
            existingAgentType: .codex,
            candidates: candidates
        )

        XCTAssertEqual(agentDef?.name, "codex")
    }
}
