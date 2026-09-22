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

    /// The old entry point still answers, so callers reading a prompt for a
    /// title get the same unwrapping they always did.
    func testProviderEntryPointStillDelegates() {
        XCTAssertEqual(
            WebhookStatusProvider.unwrapPastedContent("<pasted_content>\nhi\n</pasted_content>"), "hi")
    }

    // MARK: - Healing a history that was already written

    /// Stored rows go back through the same rule on the way out, so a timeline
    /// someone already has stops showing what should never have been recorded.
    func testStoredNotificationDoesNotDecodeBack() {
        var row = MessageEvent(seq: 7, paneId: "p", paneSessionKey: "k", kind: .user, ts: Date())
        row.text = notification
        XCTAssertNil(MessageStreamHub.decodeForTests(row.dict))
    }

    func testStoredPromptIsUnwrappedOnTheWayOut() throws {
        var row = MessageEvent(seq: 8, paneId: "p", paneSessionKey: "k", kind: .user, ts: Date())
        row.text = "<pasted_content id=\"1\">\nship it\n</pasted_content id=\"1\">"
        let decoded = try XCTUnwrap(MessageStreamHub.decodeForTests(row.dict))
        XCTAssertEqual(decoded.text, "ship it")
    }

    /// Nothing else is touched on the way out.
    func testStoredToolRowIsUnchanged() throws {
        var row = MessageEvent(seq: 9, paneId: "p", paneSessionKey: "k", kind: .tool, ts: Date())
        row.text = notification          // a tool row is not a prompt, whatever it says
        let decoded = try XCTUnwrap(MessageStreamHub.decodeForTests(row.dict))
        XCTAssertEqual(decoded.kind, .tool)
    }
}
