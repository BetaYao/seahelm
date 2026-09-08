import XCTest
@testable import seahelm

/// The card an agent is blocked on, as it reaches a phone.
final class ChatQuestionCardTests: XCTestCase {
    func testCardNamesThePaneAndSpellsOutTheOptions() {
        let text = MainWindowController.questionCardText(
            handle: 12, project: "seahelm", branch: "main",
            message: "Run the destructive migration?",
            options: ["Yes, run it", "No, stop here"])
        XCTAssertTrue(text.contains("#12 · seahelm / main"), text)
        XCTAssertTrue(text.contains("Run the destructive migration?"), text)
        // Numbered in the text as well as drawn as buttons: a button label is
        // trimmed to fit a phone, and the difference between two options is
        // often in the part that gets trimmed.
        XCTAssertTrue(text.contains("1. Yes, run it"), text)
        XCTAssertTrue(text.contains("2. No, stop here"), text)
    }

    /// A pane with no handle yet (a local pane seen for the first time) still
    /// gets a readable card rather than a stray separator.
    func testCardWithoutAHandleStillNamesTheWorktree() {
        let text = MainWindowController.questionCardText(
            handle: nil, project: "seahelm", branch: "main", message: "Pick one", options: ["a"])
        XCTAssertTrue(text.contains("seahelm / main"), text)
        XCTAssertFalse(text.contains("·"), text)
    }

    func testEachOptionGetsItsOwnRow() {
        let rows = TelegramBotAPI.keyboard([
            MessageButton(label: "Yes", token: "k1"),
            MessageButton(label: "No", token: "k2"),
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], [["text": "Yes", "callback_data": "k1"]])
        XCTAssertEqual(rows[1], [["text": "No", "callback_data": "k2"]])
    }

    /// A whole sentence of an option would be cut by Telegram at whatever width
    /// the phone has; cutting it here keeps the ellipsis honest, and newlines
    /// out of a label that has to render on one line.
    func testLongLabelsAreTrimmedAndFlattened() {
        let long = String(repeating: "ship it ", count: 20)
        let trimmed = TelegramBotAPI.trimLabel(long)
        XCTAssertEqual(trimmed.count, 48)
        XCTAssertTrue(trimmed.hasSuffix("…"))
        XCTAssertEqual(TelegramBotAPI.trimLabel("keep\nit\none line"), "keep it one line")
    }
}
