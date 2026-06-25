import XCTest

/// Page object for dialogs (Quick Switcher, New Branch).
class DialogPage {
    private let app: XCUIApplication

    init(_ app: XCUIApplication) {
        self.app = app
    }

    // MARK: - Quick Switcher

    var quickSwitcher: XCUIElement {
        app.groups["dialog.quickSwitcher"]
    }

    var searchField: XCUIElement {
        app.textFields["dialog.quickSwitcher.searchField"]
    }

    var resultsList: XCUIElement {
        app.tables["dialog.quickSwitcher.resultsList"]
    }

    func openQuickSwitcher() {
        app.typeKey("p", modifierFlags: .command)
    }

    func search(_ query: String) {
        searchField.typeText(query)
    }

    func selectFirstResult() {
        app.typeKey(.enter, modifierFlags: [])
    }

    // MARK: - New Branch

    var newBranchDialog: XCUIElement {
        app.groups["dialog.newBranch"]
    }

    var branchNameField: XCUIElement {
        app.textFields["dialog.newBranch.nameField"]
    }

    var createButton: XCUIElement {
        app.buttons["dialog.newBranch.createButton"]
    }

    func openNewBranchDialog() {
        app.typeKey("n", modifierFlags: .command)
    }
}
