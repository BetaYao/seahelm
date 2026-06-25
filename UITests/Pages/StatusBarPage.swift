import XCTest

/// Page object for the bottom status bar.
final class StatusBarPage {
    let app: XCUIApplication

    init(_ app: XCUIApplication) { self.app = app }

    var statusBar: XCUIElement { app.groups["statusbar"] }
    var summary: XCUIElement { app.staticTexts["statusbar.summary"] }
    var summaryText: String { summary.label }
}
