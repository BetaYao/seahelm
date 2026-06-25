import XCTest

/// Page object for the notification side panel.
final class NotificationPanelPage {
    let app: XCUIApplication

    init(_ app: XCUIApplication) { self.app = app }

    var panel: XCUIElement { app.groups["panel.notification"] }
    var closeButton: XCUIElement { app.buttons["panel.notification.close"] }
    var backdrop: XCUIElement { app.groups["panel.backdrop"] }

    var isOpen: Bool { panel.waitForExistence(timeout: 2) }

    func notifItem(at index: Int) -> XCUIElement {
        app.buttons["panel.notification.item.\(index)"]
    }
    func close() { closeButton.waitAndClick() }
    func clickBackdrop() { backdrop.waitAndClick() }
}
