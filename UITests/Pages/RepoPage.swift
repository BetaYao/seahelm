import XCTest

/// Page object for the project/repo view (simplified from split-pane design).
class RepoPage {
    let app: XCUIApplication

    init(_ app: XCUIApplication) { self.app = app }

    /// The terminal area: the split container of the selected worktree.
    var terminal: XCUIElement { app.descendants(matching: .any)["splitPane.container"] }
    var emptyState: XCUIElement { app.staticTexts["project.emptyState"] }
}
