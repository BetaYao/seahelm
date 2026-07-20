import XCTest
@testable import seahelm

final class ChoiceOptionParserTests: XCTestCase {

    func testParsesPermissionPrompt() {
        let screen = """
        Bash command
        gh pr checks 4552 --watch

        Do you want to proceed?
        ❯ 1. Yes
          2. Yes, and don't ask again for bash commands
          3. No, and tell Claude what to do differently
        """
        let opts = ChoiceOptionParser.parse(screen)
        XCTAssertEqual(opts.count, 3)
        XCTAssertEqual(opts[0].index, 1)
        XCTAssertEqual(opts[0].label, "Yes")
        XCTAssertTrue(opts[0].selected)          // ❯ cursor
        XCTAssertFalse(opts[1].selected)
        XCTAssertEqual(opts[2].label, "No, and tell Claude what to do differently")
    }

    func testParsesAskUserQuestion() {
        let screen = """
        Which auth method?
          1. OAuth
        ❯ 2. JWT
        """
        let opts = ChoiceOptionParser.parse(screen)
        XCTAssertEqual(opts.map(\.index), [1, 2])
        XCTAssertEqual(opts[1].label, "JWT")
        XCTAssertTrue(opts[1].selected)
    }

    func testParsesCodexApprovalWithWrappedOptionAndFooter() {
        let screen = """
        Would you like to run the following command?

        Environment: local

        Reason: Allow me to rebase the PR branch onto the latest main and
        resolve its conflicts?

        $ git rebase origin/main

        ❯ 1. Yes, proceed (y)
          2. Yes, and don't ask again for commands that start with `git rebase
             origin/main` (p)
          3. No, and tell Codex what to do differently (esc)

        Press enter to confirm or esc to cancel
        """
        let opts = ChoiceOptionParser.parse(screen)
        XCTAssertEqual(opts.map(\.index), [1, 2, 3])
        XCTAssertEqual(opts[1].label,
                       "Yes, and don't ask again for commands that start with `git rebase origin/main` (p)")
        XCTAssertTrue(opts[0].selected)
    }

    func testIgnoresNonConsecutiveProse() {
        // A numbered list in normal output must NOT be treated as a choice box.
        let screen = """
        Here's the plan:
        1. First do this
        Then some explanation text.
        2. Then do that
        """
        XCTAssertTrue(ChoiceOptionParser.parse(screen).isEmpty)
    }

    func testIgnoresSingleOption() {
        XCTAssertTrue(ChoiceOptionParser.parse("1. Only one").isEmpty)
    }

    func testDoesNotReturnStaleChoiceAboveNewOutput() {
        let screen = """
        ❯ 1. Approve
          2. Reject

        The command completed successfully.
        """
        XCTAssertTrue(ChoiceOptionParser.parse(screen).isEmpty)
    }

    func testEmptyScreen() {
        XCTAssertTrue(ChoiceOptionParser.parse("").isEmpty)
    }
}
