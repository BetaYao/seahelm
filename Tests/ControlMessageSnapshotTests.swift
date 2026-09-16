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
}
