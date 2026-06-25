import XCTest

/// Page object for the project/repo view (simplified from split-pane design).
class RepoPage {
    let app: XCUIApplication

    init(_ app: XCUIApplication) { self.app = app }

    var terminal: XCUIElement { app.groups["project.terminal"] }
    var emptyState: XCUIElement { app.staticTexts["project.emptyState"] }
}
