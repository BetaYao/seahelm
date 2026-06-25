import XCTest
@testable import seahelm

final class StatusBarViewTests: XCTestCase {
    func testUpdateUsageSetsText() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 28))
        bar.updateUsage(text: "Claude 42% · Codex 1.2k")
        XCTAssertEqual(bar.usageTextForTesting, "Claude 42% · Codex 1.2k")
    }

    func testUpdateNotificationSetsText() {
        let bar = StatusBarView(frame: .zero)
        bar.updateNotification(text: "3 unread")
        XCTAssertEqual(bar.notificationTextForTesting, "3 unread")
    }
}
