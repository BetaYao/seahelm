import XCTest
@testable import seahelm

final class SuggestionFeedTests: XCTestCase {
    func testSetAddsItemAndFiresChange() {
        let feed = SuggestionFeed()
        var changes = 0
        feed.onChange = { changes += 1 }
        feed.set(worktreePath: "/w", branch: "feat-x", terminalID: "t1", options: ["a", "b"])
        XCTAssertEqual(feed.all().count, 1)
        XCTAssertEqual(feed.all().first?.options, ["a", "b"])
        XCTAssertEqual(feed.all().first?.terminalID, "t1")
        XCTAssertEqual(changes, 1)
    }

    func testSetSameOptionsDoesNotFireChange() {
        let feed = SuggestionFeed()
        feed.set(worktreePath: "/w", branch: "b", terminalID: "t", options: ["a"])
        var changes = 0
        feed.onChange = { changes += 1 }
        feed.set(worktreePath: "/w", branch: "b", terminalID: "t", options: ["a"])
        XCTAssertEqual(changes, 0)
    }

    func testEmptyOptionsRemoves() {
        let feed = SuggestionFeed()
        feed.set(worktreePath: "/w", branch: "b", terminalID: "t", options: ["a"])
        feed.set(worktreePath: "/w", branch: "b", terminalID: "t", options: [])
        XCTAssertTrue(feed.all().isEmpty)
    }

    func testClearRemovesAndFires() {
        let feed = SuggestionFeed()
        feed.set(worktreePath: "/w", branch: "b", terminalID: "t", options: ["a"])
        var changes = 0
        feed.onChange = { changes += 1 }
        feed.clear(worktreePath: "/w")
        XCTAssertTrue(feed.all().isEmpty)
        XCTAssertEqual(changes, 1)
    }

    func testAllIsNewestFirst() {
        let feed = SuggestionFeed()
        feed.set(worktreePath: "/w1", branch: "b1", terminalID: "t1", options: ["a"])
        feed.set(worktreePath: "/w2", branch: "b2", terminalID: "t2", options: ["b"])
        XCTAssertEqual(feed.all().map { $0.worktreePath }, ["/w2", "/w1"])
    }
}
