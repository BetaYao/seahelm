import XCTest

/// Page object for two-column window chrome headers (replaces TitleBarPage).
final class ChromeHeaderPage {
    let app: XCUIApplication

    init(_ app: XCUIApplication) { self.app = app }

    var sidebarHeader: XCUIElement {
        element(identifier: "chrome.sidebarHeader")
    }
    var terminalHeader: XCUIElement {
        element(identifier: "chrome.terminalHeader")
    }
    var divider: XCUIElement { element(identifier: "chrome.divider") }
    var sidebarColumn: XCUIElement { element(identifier: "chrome.sidebarColumn") }
    var terminalTitle: XCUIElement { app.staticTexts["chrome.terminalTitle"] }

    /// Prefer groups, then any descendant matching the accessibility id.
    private func element(identifier: String) -> XCUIElement {
        let group = app.groups[identifier]
        if group.exists { return group }
        let other = app.otherElements[identifier]
        if other.exists { return other }
        return app.descendants(matching: .any)[identifier]
    }

    var themeButton: XCUIElement { app.buttons["chrome.icon.theme"] }
    var firstMateButton: XCUIElement { app.buttons["chrome.icon.firstMate"] }
    var filesButton: XCUIElement { app.buttons["chrome.icon.files"] }
    var changesButton: XCUIElement { app.buttons["chrome.icon.changes"] }
    var sidebarToggle: XCUIElement { app.buttons["chrome.icon.sidebar"] }

    func worktreeRow(id: String) -> XCUIElement {
        app.groups["chrome.worktreeRow.\(id)"]
    }

    func clickTheme() { themeButton.waitAndClick() }
    func clickFirstMate() { firstMateButton.waitAndClick() }
    func clickFiles() { filesButton.waitAndClick() }
    func clickChanges() { changesButton.waitAndClick() }
    func clickSidebarToggle() { sidebarToggle.waitAndClick() }

    /// True when the left chrome column is collapsed (sidebar header gone / hidden).
    var isSidebarCollapsed: Bool {
        !sidebarHeader.exists || !sidebarHeader.isHittable
    }
}
