import XCTest

/// Page object for the AI assistant side panel.
final class AIPanelPage {
    let app: XCUIApplication

    init(_ app: XCUIApplication) { self.app = app }

    var panel: XCUIElement { app.groups["panel.ai"] }
    var closeButton: XCUIElement { app.buttons["panel.ai.close"] }
    var inputField: XCUIElement { app.textFields["panel.ai.input"] }
    var sendButton: XCUIElement { app.buttons["panel.ai.send"] }
    var content: XCUIElement { app.scrollViews["panel.ai.content"] }
    var todoTab: XCUIElement { app.buttons["panel.ai.tab.todo"] }
    var ideasTab: XCUIElement { app.buttons["panel.ai.tab.ideas"] }

    var isOpen: Bool { panel.waitForExistence(timeout: 2) }

    func addIdea(_ text: String) {
        ideasTab.waitAndClick()
        inputField.waitAndClick()
        inputField.typeText(text)
        sendButton.waitAndClick()
    }
    func close() { closeButton.waitAndClick() }
}
