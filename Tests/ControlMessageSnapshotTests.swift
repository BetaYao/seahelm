import XCTest
@testable import seahelm

private final class MessageSnapshotFakeDS: ControlDataSource {
    var panes: [PaneSnapshot] = []
    func snapshotPanes() -> [PaneSnapshot] { panes }
    func liveLayouts() -> [String: [String: Any]]? { nil }
    func worktreeGroups(mode: String) -> [[String: Any]]? { nil }
    func dismissDecision(paneId: String) -> Bool { false }
    func readPane(paneId: String, source: String, lines: Int) -> String? { nil }
    func ingestHook(json: [String: Any]) {}
    func messageSnapshot(paneId: String?) -> [[String: Any]] {
        [[
            "seq": UInt64(1),
            "pane_id": "p1",
            "kind": "user",
            "text": "hi",
        ]]
    }
    var historyCall: (paneId: String, beforeSeq: UInt64, limit: Int)?
    func messageHistory(paneId: String, beforeSeq: UInt64, limit: Int) -> [String: Any] {
        historyCall = (paneId, beforeSeq, limit)
        return ["messages": [["seq": UInt64(3), "kind": "tool"]], "has_more": true]
    }
}

final class ControlMessageSnapshotTests: XCTestCase {
    func testMessageSnapshotRouter() {
        let router = ControlRouter(dataSource: MessageSnapshotFakeDS())
        guard case .ok(let d) = router.handle(method: "message.snapshot", params: [:]),
              let messages = d["messages"] as? [[String: Any]] else {
            return XCTFail("expected ok with messages")
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["kind"] as? String, "user")
        XCTAssertEqual(messages[0]["text"] as? String, "hi")
    }

    func testMessageHistoryRouter() {
        let ds = MessageSnapshotFakeDS()
        let router = ControlRouter(dataSource: ds)
        guard case .ok(let d) = router.handle(method: "message.history",
                                              params: ["pane_session_key": "k", "before_seq": 42, "limit": 500]) else {
            return XCTFail("expected ok")
        }
        XCTAssertEqual(ds.historyCall?.paneId, "k")
        XCTAssertEqual(ds.historyCall?.beforeSeq, 42)
        XCTAssertEqual(ds.historyCall?.limit, 200, "a page is capped")
        XCTAssertEqual((d["messages"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(d["has_more"] as? Bool, true)
    }

    func testMessageHistoryRequiresPaneAndCursor() {
        let router = ControlRouter(dataSource: MessageSnapshotFakeDS())
        guard case .error = router.handle(method: "message.history", params: ["before_seq": 1]) else {
            return XCTFail("pane is required")
        }
        guard case .error = router.handle(method: "message.history", params: ["pane_id": "p"]) else {
            return XCTFail("before_seq is required")
        }
    }
}
