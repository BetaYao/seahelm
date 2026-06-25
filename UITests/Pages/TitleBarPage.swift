import XCTest

/// Page object for the redesigned title bar (replaces TabBarPage).
final class TitleBarPage {
    let app: XCUIApplication

    init(_ app: XCUIApplication) { self.app = app }

    var titleBar: XCUIElement { app.groups["titlebar"] }
    var dashboardTab: XCUIElement { app.buttons["titlebar.dashboardTab"] }
    var addProjectButton: XCUIElement { app.buttons["titlebar.addProject"] }
    var newThreadButton: XCUIElement { app.buttons["titlebar.newThread"] }
    var viewMenuButton: XCUIElement { app.buttons["titlebar.viewMenu"] }
    var notifButton: XCUIElement { app.buttons["titlebar.notifButton"] }
    var notifBadge: XCUIElement { app.staticTexts["titlebar.notifBadge"] }
    var aiButton: XCUIElement { app.buttons["titlebar.aiButton"] }
    var themeToggle: XCUIElement { app.buttons["titlebar.themeToggle"] }

    func projectTab(named name: String) -> XCUIElement {
        app.buttons["titlebar.projectTab.\(name)"]
    }
    func closeProjectTab(named name: String) {
        app.buttons["titlebar.projectTab.\(name).close"].waitAndClick()
    }
    func clickDashboardTab() { dashboardTab.waitAndClick() }
    func clickProjectTab(named name: String) { projectTab(named: name).waitAndClick() }
    func clickAddProject() { addProjectButton.waitAndClick() }
    func clickNewThread() { newThreadButton.waitAndClick() }
    func clickViewMenu() { viewMenuButton.waitAndClick() }
    func clickNotif() { notifButton.waitAndClick() }
    func clickAI() { aiButton.waitAndClick() }
    func clickTheme() { themeToggle.waitAndClick() }
}
