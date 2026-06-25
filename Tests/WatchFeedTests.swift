import XCTest
@testable import seahelm

final class WatchFeedTests: XCTestCase {

    private func makeAction(worktreePath: String = "/repo/feat",
                            kind: FirstMateActionKind = .watchWaiting,
                            branch: String = "feat",
                            message: String = "waiting") -> FirstMateAction {
        FirstMateAction(kind: kind, zone: .green, worktreePath: worktreePath,
                        branch: branch, project: "proj", terminalID: "t1", message: message)
    }

    func testRecordAddsItem() {
        let feed = WatchFeed()
        feed.record(makeAction())
        XCTAssertEqual(feed.all().count, 1)
    }

    func testSameWorktreeKindUpserts() {
        let feed = WatchFeed()
        feed.record(makeAction(message: "first"))
        feed.record(makeAction(message: "second"))
        XCTAssertEqual(feed.all().count, 1)
        XCTAssertEqual(feed.all().first?.message, "second")
    }

    func testDifferentWorktreesCoexist() {
        let feed = WatchFeed()
        feed.record(makeAction(worktreePath: "/repo/a"))
        feed.record(makeAction(worktreePath: "/repo/b"))
        XCTAssertEqual(feed.all().count, 2)
    }

    func testDifferentKindsCoexist() {
        let feed = WatchFeed()
        feed.record(makeAction(kind: .watchWaiting))
        feed.record(makeAction(kind: .watchError))
        XCTAssertEqual(feed.all().count, 2)
    }

    func testCapAt20DropsOldest() {
        let feed = WatchFeed()
        for i in 0..<22 {
            feed.record(makeAction(worktreePath: "/repo/\(i)", message: "m\(i)"))
        }
        XCTAssertEqual(feed.all().count, 20)
        // oldest (seq 0 and 1) are dropped; newest (/repo/21) survives
        XCTAssertTrue(feed.all().contains(where: { $0.worktreePath == "/repo/21" }))
        XCTAssertFalse(feed.all().contains(where: { $0.worktreePath == "/repo/0" }))
        XCTAssertFalse(feed.all().contains(where: { $0.worktreePath == "/repo/1" }))
    }

    func testClearRemovesItem() {
        let feed = WatchFeed()
        feed.record(makeAction())
        let id = feed.all().first!.id
        feed.clear(id: id)
        XCTAssertEqual(feed.all().count, 0)
    }

    func testClearFiresOnChange() {
        let feed = WatchFeed()
        feed.record(makeAction())
        let id = feed.all().first!.id
        var fired = false
        feed.onChange = { fired = true }
        feed.clear(id: id)
        XCTAssertTrue(fired)
    }

    func testClearNonExistentDoesNotFireOnChange() {
        let feed = WatchFeed()
        var fired = false
        feed.onChange = { fired = true }
        feed.clear(id: "nonexistent#watchWaiting")
        XCTAssertFalse(fired)
    }

    func testRecordFiresOnChange() {
        let feed = WatchFeed()
        var count = 0
        feed.onChange = { count += 1 }
        feed.record(makeAction())
        XCTAssertEqual(count, 1)
    }

    func testNewestFirstOrdering() {
        let feed = WatchFeed()
        feed.record(makeAction(worktreePath: "/repo/a", message: "first"))
        feed.record(makeAction(worktreePath: "/repo/b", message: "second"))
        feed.record(makeAction(worktreePath: "/repo/c", message: "third"))
        let all = feed.all()
        XCTAssertEqual(all[0].message, "third")
        XCTAssertEqual(all[1].message, "second")
        XCTAssertEqual(all[2].message, "first")
    }

    func testUpsertPreservesNewestOrder() {
        let feed = WatchFeed()
        feed.record(makeAction(worktreePath: "/repo/a", message: "a-first"))
        feed.record(makeAction(worktreePath: "/repo/b", message: "b"))
        // upsert /repo/a — should now appear at front (newest seq)
        feed.record(makeAction(worktreePath: "/repo/a", message: "a-updated"))
        let all = feed.all()
        XCTAssertEqual(all[0].message, "a-updated")
        XCTAssertEqual(all[1].message, "b")
    }
}
