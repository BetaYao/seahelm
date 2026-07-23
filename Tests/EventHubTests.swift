import XCTest
@testable import seahelm

final class EventHubTests: XCTestCase {

    override func setUp() { super.setUp(); EventHub.shared.resetForTesting() }
    override func tearDown() { EventHub.shared.resetForTesting(); super.tearDown() }

    func testSubscriberReceivesPublishedEvents() {
        var got: [[String: Any]] = []
        let token = EventHub.shared.subscribe { _, e in got.append(e) }
        EventHub.shared.publish(seq: 1, event: ["type": "pane.updated", "pane_id": "t1"])
        EventHub.shared.unsubscribe(token)
        EventHub.shared.publish(seq: 2, event: ["type": "pane.updated", "pane_id": "t1"])
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0]["pane_id"] as? String, "t1")
    }

    func testEventsAfterReplaysBufferedTail() {
        for i in 1...5 { EventHub.shared.publish(seq: UInt64(i), event: ["type": "x", "seq": i]) }
        let after = EventHub.shared.eventsAfter(3)
        XCTAssertEqual(after.map { Int($0.seq) }, [4, 5])
        XCTAssertEqual(EventHub.shared.currentSeq, 5)
    }

    func testFilterByType() {
        let a: [String: Any] = ["type": "pane.status_changed", "pane_id": "t1"]
        let b: [String: Any] = ["type": "pane.updated", "pane_id": "t1"]
        XCTAssertTrue(ControlRouter.eventPasses(a, types: ["pane.status_changed"], paneId: nil))
        XCTAssertFalse(ControlRouter.eventPasses(b, types: ["pane.status_changed"], paneId: nil))
    }

    func testFilterByPaneMatchesIdOrSessionName() {
        let e: [String: Any] = ["type": "x", "pane_id": "STATION-UUID", "pane_session_key": "seahelm-repo-main"]
        XCTAssertTrue(ControlRouter.eventPasses(e, types: nil, paneId: "STATION-UUID"))
        XCTAssertTrue(ControlRouter.eventPasses(e, types: nil, paneId: "seahelm-repo-main"))
        XCTAssertFalse(ControlRouter.eventPasses(e, types: nil, paneId: "other"))
    }

    func testEncodeEventEnvelope() {
        let line = ControlRouter.encodeEvent(["type": "pane.updated", "seq": 7])
        XCTAssertTrue(line.hasSuffix("\n"))
        let obj = try! JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as! [String: Any]
        let ev = obj["event"] as? [String: Any]
        XCTAssertEqual(ev?["type"] as? String, "pane.updated")
        XCTAssertEqual(ev?["seq"] as? Int, 7)
    }
}
