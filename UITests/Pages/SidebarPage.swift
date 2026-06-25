import XCTest

/// Page object for the sidebar (only visible within repo tabs).
class SidebarPage {
    private let app: XCUIApplication

    init(_ app: XCUIApplication) {
        self.app = app
    }

    var worktreeList: XCUIElement {
        app.tables["sidebar.worktreeList"]
    }

    func row(named name: String) -> XCUIElement {
        app.cells["sidebar.row.\(name)"]
    }

    func clickRow(named name: String) {
        row(named: name).waitAndClick()
    }

    func rightClickRow(named name: String) {
        row(named: name).rightClick()
    }
}
