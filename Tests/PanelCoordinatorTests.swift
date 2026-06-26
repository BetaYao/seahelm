import XCTest
@testable import seahelm

final class PanelCoordinatorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NotificationHistory.shared.clear()
    }

    func testSelectPrimaryCapsuleNotificationPrefersSelectedWorktreeEntries() {
        let globalError = NotificationEntry(
            branch: "release",
            worktreePath: "/repo/release",
            status: .error,
            message: "Build failed"
        )
        let selectedWaiting = NotificationEntry(
            branch: "feature",
            worktreePath: "/repo/feature",
            status: .waiting,
            message: "Need approval"
        )

        let entry = MainWindowController.selectPrimaryCapsuleNotification(
            from: [globalError, selectedWaiting]
        )

        XCTAssertEqual(entry?.worktreePath, "/repo/release")
        XCTAssertEqual(entry?.status, .error)
    }

    func testSelectPrimaryCapsuleNotificationFallsBackToGlobalPriority() {
        let idle = NotificationEntry(
            branch: "feature",
            worktreePath: "/repo/feature",
            status: .idle,
            message: "Finished"
        )
        let error = NotificationEntry(
            branch: "release",
            worktreePath: "/repo/release",
            status: .error,
            message: "Build failed"
        )

        let entry = MainWindowController.selectPrimaryCapsuleNotification(
            from: [idle, error]
        )

        XCTAssertEqual(entry?.worktreePath, "/repo/release")
        XCTAssertEqual(entry?.status, .error)
    }

    func testSelectPrimaryCapsuleNotificationIgnoresReadEntries() {
        let unreadWaiting = NotificationEntry(
            branch: "feature",
            worktreePath: "/repo/feature",
            status: .waiting,
            message: "Need approval"
        )
        var readError = NotificationEntry(
            branch: "release",
            worktreePath: "/repo/release",
            status: .error,
            message: "Build failed"
        )
        readError.isRead = true

        let entry = MainWindowController.selectPrimaryCapsuleNotification(from: [readError, unreadWaiting])

        XCTAssertEqual(entry?.worktreePath, "/repo/feature")
        XCTAssertEqual(entry?.status, .waiting)
    }

    func testSelectPrimaryCapsuleNotificationExcludesDismissedEntries() {
        let dismissedError = NotificationEntry(
            branch: "release",
            worktreePath: "/repo/release",
            status: .error,
            message: "Build failed"
        )
        let visibleWaiting = NotificationEntry(
            branch: "feature",
            worktreePath: "/repo/feature",
            status: .waiting,
            message: "Need approval"
        )

        let entry = MainWindowController.selectPrimaryCapsuleNotification(
            from: [dismissedError, visibleWaiting],
            excluding: [dismissedError.id]
        )

        XCTAssertEqual(entry?.worktreePath, "/repo/feature")
        XCTAssertEqual(entry?.status, .waiting)
    }
}
