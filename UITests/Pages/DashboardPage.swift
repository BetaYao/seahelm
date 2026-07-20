import XCTest

/// Page object for the redesigned Dashboard with multiple layout modes.
class DashboardPage {
    let app: XCUIApplication

    init(_ app: XCUIApplication) { self.app = app }

    var dashboardView: XCUIElement { app.groups["dashboard.view"] }
    var gridLayout: XCUIElement { app.descendants(matching: .any)["dashboard.layout.grid"] }
    var leftRightLayout: XCUIElement { app.descendants(matching: .any)["dashboard.layout.left-right"] }
    var topSmallLayout: XCUIElement { app.descendants(matching: .any)["dashboard.layout.top-small"] }
    var topLargeLayout: XCUIElement { app.descendants(matching: .any)["dashboard.layout.top-large"] }
    var focusPanel: XCUIElement { app.groups["dashboard.focusPanel"] }
    var enterProjectButton: XCUIElement { app.buttons["dashboard.focusPanel.enterProject"] }

    var cards: XCUIElementQuery {
        app.groups.matching(NSPredicate(format: "identifier BEGINSWITH 'dashboard.card.'"))
    }

    func tapCard(id: String) { app.groups["dashboard.card.\(id)"].waitAndClick() }
    func tapEnterProject() { enterProjectButton.waitAndClick() }
}
