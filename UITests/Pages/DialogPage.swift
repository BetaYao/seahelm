import XCTest

/// Page object for the new-branch dialog.
class DialogPage {
    private let app: XCUIApplication

    init(_ app: XCUIApplication) {
        self.app = app
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
