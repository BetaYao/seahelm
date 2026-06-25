import XCTest

/// Page object for the settings sheet.
class SettingsPage {
    private let app: XCUIApplication

    init(_ app: XCUIApplication) {
        self.app = app
    }

    var sheet: XCUIElement {
        app.groups["settings.sheet"]
    }

    var workspacePaths: XCUIElement {
        app.tables["settings.workspacePaths"]
    }

    var addPathButton: XCUIElement {
        app.buttons["settings.addPath"]
    }

    var removePathButton: XCUIElement {
        app.buttons["settings.removePath"]
    }

    func open() {
        app.typeKey(",", modifierFlags: .command)
    }
}
