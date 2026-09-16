import XCTest
@testable import seahelm

final class MessageStreamHubTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MessageStreamHub.shared.resetForTesting()
    }

    func testAppendSnapshotAndClear() {
        let hub = MessageStreamHub.shared
        hub.append([
            MessageEvent(seq: 0, paneId: "a", paneSessionKey: "k",
                         kind: .user, ts: Date(), text: "hi")
        ])
        XCTAssertEqual(hub.snapshot(paneId: "a").count, 1)
        XCTAssertEqual(hub.snapshot(paneId: "a").first?.seq, 1)
        hub.clear(paneId: "a")
        XCTAssertTrue(hub.snapshot(paneId: "a").isEmpty)
    }

    func testSubscribeReceivesAppend() {
        let hub = MessageStreamHub.shared
        var got: [MessageEvent] = []
        let token = hub.subscribe { got.append($0) }
        hub.append([
            MessageEvent(seq: 0, paneId: "a", paneSessionKey: "",
                         kind: .notice, ts: Date(), text: "n")
        ])
        hub.unsubscribe(token)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.text, "n")
    }

    func testEventsAfterReplay() {
        let hub = MessageStreamHub.shared
        hub.append([
            MessageEvent(seq: 0, paneId: "a", paneSessionKey: "", kind: .user, ts: Date(), text: "1"),
            MessageEvent(seq: 0, paneId: "a", paneSessionKey: "", kind: .user, ts: Date(), text: "2"),
        ])
        let after = hub.eventsAfter(1)
        XCTAssertEqual(after.map(\.text), ["2"])
    }
}
