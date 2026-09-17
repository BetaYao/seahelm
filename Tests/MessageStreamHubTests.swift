import XCTest
@testable import seahelm

final class MessageStreamHubTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-stream-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func event(_ text: String, pane: String = "a", key: String = "k",
                       ts: TimeInterval = 100) -> MessageEvent {
        MessageEvent(seq: 0, paneId: pane, paneSessionKey: key, kind: .user,
                     ts: Date(timeIntervalSince1970: ts), text: text)
    }

    func testAppendSnapshotAndClear() {
        let hub = MessageStreamHub()
        hub.append([event("hi")])
        XCTAssertEqual(hub.snapshot(paneId: "a").count, 1)
        XCTAssertEqual(hub.snapshot(paneId: "k").first?.seq, 1)
        hub.clear(paneId: "a")
        XCTAssertTrue(hub.snapshot(paneId: "a").isEmpty)
    }

    func testSubscribeReceivesAppend() {
        let hub = MessageStreamHub()
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
        let hub = MessageStreamHub()
        hub.append([event("1"), event("2")])
        let after = hub.eventsAfter(1)
        XCTAssertEqual(after.map(\.text), ["2"])
    }

    func testHistorySurvivesRelaunch() {
        let store = MessageStreamStore(directory: dir)
        let first = MessageStreamHub(store: store)
        first.append([event("one", ts: 100), event("two", ts: 101)])
        first.append([event("other", pane: "b", key: "k2", ts: 102)])
        var tool = event("", ts: 103)
        tool.kind = .tool
        tool.text = nil
        tool.tool = "Read"
        tool.detail = "a.swift"
        tool.isError = false
        first.append([tool])
        store.waitForWrites()

        let relaunched = MessageStreamHub(store: MessageStreamStore(directory: dir))
        let ring = relaunched.snapshot(paneId: "k")
        XCTAssertEqual(ring.map(\.kind), [.user, .user, .tool])
        XCTAssertEqual(ring.map(\.text), ["one", "two", nil])
        XCTAssertEqual(ring.last?.tool, "Read")
        XCTAssertEqual(ring.last?.isError, false)
        XCTAssertEqual(relaunched.snapshot(paneId: "k2").map(\.text), ["other"])
        let all = relaunched.snapshot(paneId: nil)
        XCTAssertEqual(all.map(\.seq), [1, 2, 3, 4], "numbers survive, so history pages by them")
        XCTAssertEqual(all.map(\.text), ["one", "two", "other", nil])

        var next: [MessageEvent] = []
        let token = relaunched.subscribe { next.append($0) }
        relaunched.append([event("three", ts: 104)])
        relaunched.unsubscribe(token)
        XCTAssertEqual(next.first?.seq, 5, "carries on from the highest number on disk")
    }

    func testHistoryPagesOlderThanMemory() {
        let store = MessageStreamStore(directory: dir)
        let hub = MessageStreamHub(store: store, perPaneCap: 5)
        for i in 1...12 { hub.append([event("m\(i)", ts: TimeInterval(i))]) }
        hub.append([event("elsewhere", pane: "b", key: "k2", ts: 13)])

        XCTAssertEqual(hub.snapshot(paneId: "k").map(\.text), ["m8", "m9", "m10", "m11", "m12"])
        let page = hub.history(paneId: "k", beforeSeq: 8, limit: 4)
        XCTAssertEqual(page.events.map(\.text), ["m4", "m5", "m6", "m7"])
        XCTAssertTrue(page.hasMore)
        let last = hub.history(paneId: "a", beforeSeq: 4, limit: 4)
        XCTAssertEqual(last.events.map(\.text), ["m1", "m2", "m3"], "station id resolves to the ring")
        XCTAssertFalse(last.hasMore)

        let relaunched = MessageStreamHub(store: MessageStreamStore(directory: dir), perPaneCap: 5)
        XCTAssertEqual(relaunched.history(paneId: "k", beforeSeq: 8, limit: 100).events.count, 7)
    }

    func testHistoryWithoutStoreComesFromMemory() {
        let hub = MessageStreamHub(perPaneCap: 5)
        for i in 1...5 { hub.append([event("m\(i)")]) }
        let page = hub.history(paneId: "k", beforeSeq: 4, limit: 2)
        XCTAssertEqual(page.events.map(\.text), ["m2", "m3"])
        XCTAssertTrue(page.hasMore)
    }

    func testClosedPaneHistoryIsDeleted() {
        let store = MessageStreamStore(directory: dir)
        let hub = MessageStreamHub(store: store)
        hub.append([event("gone")])
        hub.clear(paneId: "a", paneSessionKey: "k")
        store.waitForWrites()

        let relaunched = MessageStreamHub(store: MessageStreamStore(directory: dir))
        XCTAssertTrue(relaunched.snapshot(paneId: nil).isEmpty)
    }

    func testFileStaysBoundedAndReloadsNewest() throws {
        let store = MessageStreamStore(directory: dir, keep: 10)
        let hub = MessageStreamHub(store: store, perPaneCap: 5)
        for i in 0..<40 {
            hub.append([event("m\(i)", ts: 100 + TimeInterval(i))])
        }
        store.waitForWrites()

        let text = try String(contentsOf: dir.appendingPathComponent("k.jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n").count
        XCTAssertGreaterThanOrEqual(lines, 10)
        XCTAssertLessThanOrEqual(lines, 15)

        let relaunched = MessageStreamHub(store: MessageStreamStore(directory: dir, keep: 10), perPaneCap: 5)
        XCTAssertEqual(relaunched.snapshot(paneId: "k").map(\.text),
                       ["m35", "m36", "m37", "m38", "m39"])
        let older = relaunched.history(paneId: "k", beforeSeq: 36, limit: 100)
        XCTAssertEqual(older.events.last?.text, "m34")
        XCTAssertEqual(older.events.count, lines - 5)
        XCTAssertFalse(older.hasMore)
    }

    func testUnreadableLineIsSkipped() throws {
        let store = MessageStreamStore(directory: dir)
        let hub = MessageStreamHub(store: store)
        hub.append([event("kept")])
        store.waitForWrites()
        let url = dir.appendingPathComponent("k.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()

        let relaunched = MessageStreamHub(store: MessageStreamStore(directory: dir))
        XCTAssertEqual(relaunched.snapshot(paneId: "k").map(\.text), ["kept"])
    }

    /// A turn's last message arrives from the transcript and again from the Stop
    /// hook, in either order; the timeline shows it once.
    func testFinalMessageArrivingTwiceIsShownOnce() {
        let hub = MessageStreamHub()
        func prose(_ text: String) -> MessageEvent {
            MessageEvent(seq: 0, paneId: "a", paneSessionKey: "k", kind: .assistant, ts: Date(), text: text)
        }
        hub.append([prose("looking"), prose("done")])
        hub.append([prose("done")])
        XCTAssertEqual(hub.snapshot(paneId: "k").map(\.text), ["looking", "done"])
        hub.append([event("next turn"), prose("done")])
        XCTAssertEqual(hub.snapshot(paneId: "k").filter { $0.kind == .assistant }.count, 2,
                       "a recent identical reply is the same message, even across the prompt it raced")
    }
}
