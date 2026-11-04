import XCTest
@testable import seahelm

final class UserPromptTextTests: XCTestCase {

    /// The shape actually captured from a live `UserPromptSubmit` payload.
    private let notification = """
    <task-notification>
    <task-id>bjnvnz7a2</task-id>
    <tool-use-id>toolu_014spY43jpr26tyRKTAvdShw</tool-use-id>
    <status>completed</status>
    <summary>Background command "Wait for the new CI run" completed (exit code 0)</summary>
    </task-notification>
    """

    // MARK: - What nobody said

    func testTaskNotificationIsNotAPersonSpeaking() {
        XCTAssertNil(UserPromptText.humanText(notification))
    }

    func testSurroundingWhitespaceDoesNotSaveIt() {
        XCTAssertNil(UserPromptText.humanText("\n\n\(notification)\n  "))
    }

    func testSystemReminderIsAlsoMachinePlumbing() {
        XCTAssertNil(UserPromptText.humanText("<system-reminder>be brief</system-reminder>"))
    }

    func testEmptyPromptIsNothing() {
        XCTAssertNil(UserPromptText.humanText("   \n "))
    }

    // MARK: - What someone did say

    func testPlainPromptSurvivesUntouched() {
        XCTAssertEqual(UserPromptText.humanText("fix the flaky test"), "fix the flaky test")
    }

    /// How this bug was reported: a person quoting a notification to complain
    /// about it. Their message is theirs, quote and all — cutting the block out
    /// would leave a complaint with its subject missing.
    func testQuotingANotificationIsStillAPersonSpeaking() {
        let quoted = "seahelm-web shows this on the user side: \(notification), which is clearly not a human."
        XCTAssertEqual(UserPromptText.humanText(quoted), quoted)
    }

    /// A block that merely *starts* the message is not the whole message.
    func testNotificationFollowedByWordsIsKept() {
        let text = "\(notification)\n\nwhy did that fail?"
        XCTAssertEqual(UserPromptText.humanText(text), text)
    }

    // MARK: - Paste wrapper

    func testPasteWrapperComesOff() {
        let raw = "<pasted_content id=\"1404\">\nmerge #1561 first\n</pasted_content id=\"1404\">"
        XCTAssertEqual(UserPromptText.humanText(raw), "merge #1561 first")
    }


    // MARK: - Healing a history that was already written



}
