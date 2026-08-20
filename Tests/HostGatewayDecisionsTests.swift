import XCTest
@testable import seahelm

final class HostGatewayDecisionsTests: XCTestCase {
    private func questionEvent(key: String = "k1", seq: Int = 1) -> [String: Any] {
        ["pane_session_key": key, "pane_id": "p1", "seq": seq,
         "question": ["prompt": "delete the branch?", "options": ["yes", "no"]]]
    }
    private func suggestEvent(key: String = "k1", seq: Int = 2) -> [String: Any] {
        ["pane_session_key": key, "pane_id": "p1", "seq": seq,
         "suggest": ["options": ["run tests", "commit"]]]
    }

    func testQuestionOpensAndCarriesItsOptions() {
        let d = HostGatewayDecisions()
        guard case .opened(let open) = d.apply(event: questionEvent()) else { return XCTFail() }
        XCTAssertEqual(open.kind, "question")
        XCTAssertEqual(open.options, ["yes", "no"])
        XCTAssertEqual(d.options(forPaneSessionKey: "k1"), ["yes", "no"])
    }

    func testLeavingWaitingClearsIt() {
        let d = HostGatewayDecisions()
        _ = d.apply(event: questionEvent())
        let change = d.apply(event: ["pane_session_key": "k1", "status": AgentStatus.running.rawValue])
        XCTAssertEqual(change, .cleared(paneSessionKey: "k1"))
        XCTAssertTrue(d.options(forPaneSessionKey: "k1").isEmpty)
    }

    func testStillWaitingDoesNotClearALivePrompt() {
        // A status event that is *still* waiting must not cancel the question it
        // belongs to — that would drop the prompt the moment it was raised.
        let d = HostGatewayDecisions()
        _ = d.apply(event: questionEvent())
        XCTAssertEqual(d.apply(event: ["pane_session_key": "k1", "status": AgentStatus.waiting.rawValue]), .none)
        XCTAssertEqual(d.options(forPaneSessionKey: "k1"), ["yes", "no"])
    }

    func testClearingSomethingAlreadyClosedIsNotAnEvent() {
        let d = HostGatewayDecisions()
        XCTAssertEqual(d.apply(event: ["pane_session_key": "k1", "status": AgentStatus.idle.rawValue]), .none)
    }

    func testEventsWithoutAPaneAreIgnored() {
        XCTAssertEqual(HostGatewayDecisions().apply(event: ["status": "Waiting"]), .none)
    }

    func testPendingReplaysInSequenceOrder() {
        // Replay is what a socket has instead of retained topics, so its order is
        // the order the decisions were raised.
        let d = HostGatewayDecisions()
        _ = d.apply(event: suggestEvent(key: "b", seq: 9))
        _ = d.apply(event: questionEvent(key: "a", seq: 3))
        XCTAssertEqual(d.pending().map(\.paneSessionKey), ["a", "b"])
    }

    func testLaterDecisionReplacesTheEarlierOneForAPane() {
        let d = HostGatewayDecisions()
        _ = d.apply(event: questionEvent(key: "k1"))
        _ = d.apply(event: suggestEvent(key: "k1"))
        XCTAssertEqual(d.pending().count, 1)
        XCTAssertEqual(d.options(forPaneSessionKey: "k1"), ["run tests", "commit"])
    }

    func testWireShapeMatchesWhatTheWebClientRenders() {
        let d = HostGatewayDecisions()
        guard case .opened(let open) = d.apply(event: questionEvent()) else { return XCTFail() }
        let p = HostGatewayDecisions.notifyParams(for: open)
        XCTAssertEqual(p["type"] as? String, "question")
        XCTAssertEqual(p["pane_session_key"] as? String, "k1")
        XCTAssertEqual(p["prompt"] as? String, "delete the branch?")
        XCTAssertEqual(p["options"] as? [String], ["yes", "no"])
        XCTAssertEqual(p["danger"] as? Bool, true, "'delete' should read as dangerous")

        let cleared = HostGatewayDecisions.clearedParams(paneSessionKey: "k1")
        XCTAssertEqual(cleared["cleared"] as? Bool, true)
    }

    func testSuggestCarriesNoPromptOrDanger() {
        let d = HostGatewayDecisions()
        guard case .opened(let open) = d.apply(event: suggestEvent()) else { return XCTFail() }
        let p = HostGatewayDecisions.notifyParams(for: open)
        XCTAssertNil(p["prompt"])
        XCTAssertNil(p["danger"])
    }
}

extension HostGatewayDecisionsTests {
    /// The bug this file exists to prevent recurring: `::seahelm-suggest::` fires
    /// from the Stop hook, so the pane is idle the moment the options arrive.
    /// Treating "not waiting" as expiry deleted every suggestion one poll later.
    func testSuggestSurvivesAnIdlePane() {
        let d = HostGatewayDecisions()
        _ = d.apply(event: ["pane_session_key": "k1", "pane_id": "p1", "seq": 1,
                            "suggest": ["options": ["a", "b"]]])
        XCTAssertEqual(d.apply(event: ["pane_session_key": "k1", "status": AgentStatus.idle.rawValue]), .none)
        XCTAssertEqual(d.options(forPaneSessionKey: "k1"), ["a", "b"],
                       "an idle pane is where a suggestion lives, not where it dies")
    }

    func testSuggestEndsWhenThePaneGoesBackToWork() {
        let d = HostGatewayDecisions()
        _ = d.apply(event: ["pane_session_key": "k1", "pane_id": "p1", "seq": 1,
                            "suggest": ["options": ["a"]]])
        XCTAssertEqual(d.apply(event: ["pane_session_key": "k1", "status": AgentStatus.running.rawValue]),
                       .cleared(paneSessionKey: "k1"))
    }

    func testQuestionStillDiesWithItsPrompt() {
        let d = HostGatewayDecisions()
        _ = d.apply(event: ["pane_session_key": "k1", "pane_id": "p1", "seq": 1,
                            "question": ["prompt": "?", "options": ["y", "n"]]])
        XCTAssertEqual(d.apply(event: ["pane_session_key": "k1", "status": AgentStatus.idle.rawValue]),
                       .cleared(paneSessionKey: "k1"))
    }
}
