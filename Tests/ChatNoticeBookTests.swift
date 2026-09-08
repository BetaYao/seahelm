import XCTest
@testable import seahelm

/// Where an agent's next-step options get attached.
final class ChatNoticeBookTests: XCTestCase {
    private let now = Date()

    func testNewestNoticePerChatReplacesTheLast() {
        var book = ChatNoticeBook()
        book.record(pane: "t1", chatId: "c1", messageId: "10", at: now.addingTimeInterval(-30))
        book.record(pane: "t1", chatId: "c1", messageId: "11", at: now)
        // Options belong under the turn that just finished, not the one before it.
        XCTAssertEqual(book.recent(pane: "t1", now: now).map(\.messageId), ["11"])
    }

    func testEveryChatToldAboutThePaneGetsItsOwnAnchor() {
        var book = ChatNoticeBook()
        book.record(pane: "t1", chatId: "c1", messageId: "10", at: now)
        book.record(pane: "t1", chatId: "c2", messageId: "77", at: now)
        XCTAssertEqual(Set(book.recent(pane: "t1", now: now).map(\.messageId)), ["10", "77"])
    }

    /// Panes do not share an anchor: a suggestion from one must not hang its
    /// options under another's completion notice.
    func testNoticesAreScopedToOnePane() {
        var book = ChatNoticeBook()
        book.record(pane: "t1", chatId: "c1", messageId: "10", at: now)
        XCTAssertTrue(book.recent(pane: "t2", now: now).isEmpty)
        XCTAssertTrue(book.recent(pane: "", now: now).isEmpty)
    }

    /// Past the window the chat has moved on, and buttons under a message the
    /// reader has scrolled away from offer a next step for a finished turn.
    func testANoticeStopsBeingAnAnchorOnceItIsOld() {
        var book = ChatNoticeBook()
        book.record(pane: "t1", chatId: "c1", messageId: "10",
                    at: now.addingTimeInterval(-ChatNoticeBook.window - 1))
        XCTAssertTrue(book.recent(pane: "t1", now: now).isEmpty)
        // Still held until pruned — `recent` is the gate, `prune` is the cleanup.
        XCTAssertFalse(book.isEmpty)
        book.prune(now: now)
        XCTAssertTrue(book.isEmpty)
    }

    /// A pane still being talked about survives the sweep.
    func testPruneKeepsWhatIsStillAttachable() {
        var book = ChatNoticeBook()
        book.record(pane: "old", chatId: "c1", messageId: "1",
                    at: now.addingTimeInterval(-ChatNoticeBook.window - 1))
        book.record(pane: "new", chatId: "c1", messageId: "2", at: now)
        book.prune(now: now)
        XCTAssertTrue(book.recent(pane: "old", now: now).isEmpty)
        XCTAssertEqual(book.recent(pane: "new", now: now).map(\.messageId), ["2"])
    }
}
