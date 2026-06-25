import XCTest

/// Page object for the layout selection menu (triggered from view menu).
final class LayoutPopoverPage {
    let app: XCUIApplication

    init(_ app: XCUIApplication) { self.app = app }

    var gridItem: XCUIElement { app.menuItems["Grid"] }
    var leftRightItem: XCUIElement { app.menuItems["Left Right"] }
    var topSmallItem: XCUIElement { app.menuItems["Top Small"] }
    var topLargeItem: XCUIElement { app.menuItems["Top Large"] }

    private func ensureVisible(_ item: XCUIElement) {
        if item.waitForExistence(timeout: 1) {
            return
        }
        app.buttons["titlebar.viewMenu"].waitAndClick()
        _ = item.waitForExistence(timeout: 3)
    }

    func selectGrid() {
        ensureVisible(gridItem)
        gridItem.waitAndClick()
    }

    func selectLeftRight() {
        ensureVisible(leftRightItem)
        leftRightItem.waitAndClick()
    }

    func selectTopSmall() {
        ensureVisible(topSmallItem)
        topSmallItem.waitAndClick()
    }

    func selectTopLarge() {
        ensureVisible(topLargeItem)
        topLargeItem.waitAndClick()
    }
}
