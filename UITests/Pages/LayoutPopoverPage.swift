import XCTest

/// Legacy layout-popover page object. View-mode layout menus were retired with
/// two-column chrome; kept as a thin stub so older callers compile.
final class LayoutPopoverPage {
    let app: XCUIApplication

    init(_ app: XCUIApplication) { self.app = app }

    var gridItem: XCUIElement { app.menuItems["Grid"] }
    var leftRightItem: XCUIElement { app.menuItems["Left Right"] }
    var topSmallItem: XCUIElement { app.menuItems["Top Small"] }
    var topLargeItem: XCUIElement { app.menuItems["Top Large"] }

    private func ensureVisible(_ item: XCUIElement) {
        // Layout switcher removed from chrome; no-op if menu absent.
        _ = item.waitForExistence(timeout: 1)
    }

    func selectGrid() {
        ensureVisible(gridItem)
        if gridItem.exists { gridItem.waitAndClick() }
    }

    func selectLeftRight() {
        ensureVisible(leftRightItem)
        if leftRightItem.exists { leftRightItem.waitAndClick() }
    }

    func selectTopSmall() {
        ensureVisible(topSmallItem)
        if topSmallItem.exists { topSmallItem.waitAndClick() }
    }

    func selectTopLarge() {
        ensureVisible(topLargeItem)
        if topLargeItem.exists { topLargeItem.waitAndClick() }
    }
}
