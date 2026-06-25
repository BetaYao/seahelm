import XCTest
@testable import seahelm

class NotificationHistoryTests: XCTestCase {
    var history: NotificationHistory!

    override func setUp() {
        super.setUp()
        history = NotificationHistory.shared
        history.clear()
    }

    func testAddEntry() {
        let entry = NotificationEntry(workspaceName: "repo", branch: "main", worktreePath: "/repo/main", status: .idle, message: "Task done")
        history.add(entry)

        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.workspaceName, "repo")
        XCTAssertEqual(history.entries.first?.branch, "main")
        XCTAssertEqual(history.entries.first?.message, "Task done")
        XCTAssertEqual(history.entries.first?.status, .idle)
        XCTAssertFalse(history.entries.first!.isRead)
    }

    func testNewestFirst() {
        history.add(NotificationEntry(branch: "a", worktreePath: "/a", status: .idle, message: "first"))
        history.add(NotificationEntry(branch: "b", worktreePath: "/b", status: .error, message: "second"))

        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.entries[0].branch, "b")
        XCTAssertEqual(history.entries[1].branch, "a")
    }

    func testUnreadCount() {
        history.add(NotificationEntry(branch: "a", worktreePath: "/a", status: .idle, message: ""))
        history.add(NotificationEntry(branch: "b", worktreePath: "/b", status: .idle, message: ""))

        XCTAssertEqual(history.unreadCount, 2)
    }

    func testMarkRead() {
        let entry = NotificationEntry(branch: "a", worktreePath: "/a", status: .idle, message: "")
        history.add(entry)
        XCTAssertEqual(history.unreadCount, 1)

        history.markRead(id: entry.id)
        XCTAssertEqual(history.unreadCount, 0)
        XCTAssertTrue(history.entries[0].isRead)
    }

    func testMarkAllRead() {
        history.add(NotificationEntry(branch: "a", worktreePath: "/a", status: .idle, message: ""))
        history.add(NotificationEntry(branch: "b", worktreePath: "/b", status: .idle, message: ""))
        XCTAssertEqual(history.unreadCount, 2)

        history.markAllRead()
        XCTAssertEqual(history.unreadCount, 0)
    }

    func testMarkLatestReadMatchesWorktreeAndPane() {
        history.add(NotificationEntry(branch: "a", worktreePath: "/repo", status: .idle, message: "", paneIndex: 1))
        history.add(NotificationEntry(branch: "a", worktreePath: "/repo", status: .waiting, message: "", paneIndex: 2))

        history.markLatestRead(worktreePath: "/repo", paneIndex: 2)

        XCTAssertEqual(history.unreadCount, 1)
        XCTAssertTrue(history.entries[0].isRead)
        XCTAssertFalse(history.entries[1].isRead)
    }

    func testClear() {
        history.add(NotificationEntry(branch: "a", worktreePath: "/a", status: .idle, message: ""))
        history.add(NotificationEntry(branch: "b", worktreePath: "/b", status: .idle, message: ""))
        XCTAssertEqual(history.entries.count, 2)

        history.clear()
        XCTAssertEqual(history.entries.count, 0)
    }

    func testMaxEntriesCap() {
        for i in 0..<120 {
            history.add(NotificationEntry(branch: "b\(i)", worktreePath: "/\(i)", status: .idle, message: ""))
        }
        XCTAssertEqual(history.entries.count, NotificationHistory.maxEntries)
        // Newest should be last added
        XCTAssertEqual(history.entries[0].branch, "b119")
    }

    func testEntryProperties() {
        let entry = NotificationEntry(branch: "feature", worktreePath: "/repo/feature", status: .error, message: "Build failed")
        XCTAssertFalse(entry.isRead)
        XCTAssertEqual(entry.status, .error)
        XCTAssertEqual(entry.message, "Build failed")
        XCTAssertNotNil(entry.id)
    }
}
