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
