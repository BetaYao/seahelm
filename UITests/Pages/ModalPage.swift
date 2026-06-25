import XCTest

/// Page object for generic modal dialogs (close confirmation, add project, etc.).
final class ModalPage {
    let app: XCUIApplication

    init(_ app: XCUIApplication) { self.app = app }

    var overlay: XCUIElement { app.groups["modal.overlay"] }
    var title: XCUIElement { app.staticTexts["modal.title"] }
    var subtitle: XCUIElement { app.staticTexts["modal.subtitle"] }
    var input: XCUIElement { app.textFields["modal.input"] }
    var textArea: XCUIElement { app.textViews["modal.input"] }
    var cancelButton: XCUIElement { app.buttons["modal.cancel"] }
    var confirmButton: XCUIElement { app.buttons["modal.confirm"] }

    var isVisible: Bool { overlay.waitForExistence(timeout: 3) }

    func typeInInput(_ text: String) {
        input.waitAndClick()
        input.typeText(text)
    }
    func typeInTextArea(_ text: String) {
        textArea.waitAndClick()
        textArea.typeText(text)
    }
    func confirm() { confirmButton.waitAndClick() }
    func cancel() { cancelButton.waitAndClick() }
    func dismissWithEscape() { app.typeKey(.escape, modifierFlags: []) }
}
