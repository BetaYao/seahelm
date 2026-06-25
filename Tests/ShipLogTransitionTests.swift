import XCTest
@testable import seahelm

final class ShipLogTransitionTests: XCTestCase {
    func testStatusChangeFiresTransitionObserver() {
        let head = ShipLog.shared
        let exp = expectation(description: "transition fired")
        var captured: StatusTransition?
        head.onStatusTransition = { t in
            if captured == nil { captured = t; exp.fulfill() }
        }
        head.registerForTesting(terminalID: "tt", worktreePath: "/wt/z",
                                branch: "feat-z", project: "repoz")
        head.updateStatus(terminalID: "tt", status: .waiting,
                          lastMessage: "?", roundDuration: 0)
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.newStatus, .waiting)
        XCTAssertEqual(captured?.worktreePath, "/wt/z")
        XCTAssertFalse(captured?.isCompletionSignal ?? true)
        head.onStatusTransition = nil
        head.unregister(terminalID: "tt")
    }
}
