import XCTest
@testable import seahelm

final class AgentRegistryTransitionTests: XCTestCase {
    func testStatusChangeFiresOutcomeObserver() {
        let head = AgentRegistry.shared
        let exp = expectation(description: "outcome fired")
        var captured: IngestOutcome?
        head.registerForTesting(terminalID: "tt", worktreePath: "/wt/z",
                                branch: "feat-z", project: "repoz")
        head.onOutcome = { o in
            if o.statusChanged && captured == nil { captured = o; exp.fulfill() }
        }
        head.ingest(NormalizedEvent(terminalID: "tt", source: .scan,
            kind: .screenObserved(status: .waiting, message: "?",
                                  activity: [], commandLine: nil, agentType: .unknown,
                                  roundDuration: 0, tasks: [])))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.newStatus, .waiting)
        XCTAssertEqual(captured?.info.worktreePath, "/wt/z")
        XCTAssertFalse(captured?.isCompletionSignal ?? true)
        head.onOutcome = nil
        head.unregister(terminalID: "tt")
    }
}
