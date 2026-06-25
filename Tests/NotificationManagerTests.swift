import XCTest
@testable import seahelm

final class NotificationManagerTests: XCTestCase {
    func testFormatErrorTitleUsesSpecificSummary() {
        let title = NotificationManager.formatTitle(
            status: .error,
            workspaceName: "workspace",
            branch: "feature/article",
            paneIndex: 1,
            paneCount: 1,
            lastMessage: "Failed Bash cd /Users/dev/workspace/workspace-worktree"
        )

        XCTAssertEqual(title, "cd failed — workspace / feature/article")
    }

    func testFormatErrorBodyCollapsesLongPath() {
        let body = NotificationManager.formatBody(
            status: .error,
            workspaceName: "workspace",
            branch: "feature/article",
            lastMessage: "Failed Bash cd /Users/dev/workspace/workspace-worktree"
        )

        XCTAssertEqual(body, "Cannot open workspace-worktree worktree")
    }

    func testFormatBodyTruncatesAbsolutePathsInGeneralMessages() {
        let body = NotificationManager.formatBody(
            status: .waiting,
            workspaceName: "workspace",
            branch: "feature/article",
            lastMessage: "Review logs in /Users/dev/workspace/workspace-worktree/build/output.log before continuing"
        )

        XCTAssertEqual(body, "Review logs in output.log before continuing")
    }

    func testIdleBodyPrefersLastUserPrompt() {
        let body = NotificationManager.formatBody(
            status: .idle,
            workspaceName: "workspace",
            branch: "feature/article",
            lastMessage: "Task completed",
            lastUserPrompt: "fix the flaky dashboard notification"
        )

        XCTAssertEqual(body, "fix the flaky dashboard notification — Task completed")
    }

    func testSystemBodyUsesLastUserPromptWhenAvailable() {
        let body = NotificationManager.formatSystemBody(
            status: .idle,
            workspaceName: "workspace",
            branch: "feature/article",
            lastMessage: "Task completed",
            lastUserPrompt: "fix the flaky dashboard notification"
        )

        XCTAssertEqual(body, "fix the flaky dashboard notification")
    }

    func testSystemSubtitleUsesTarget() {
        let subtitle = NotificationManager.formatSystemSubtitle(
            workspaceName: "workspace",
            branch: "feature/article",
            paneIndex: 2,
            paneCount: 3
        )

        XCTAssertEqual(subtitle, "workspace / feature/article [Pane 2]")
    }

    func testSystemTitleUsesResultSemantic() {
        let title = NotificationManager.formatSystemTitle(status: .idle)
        XCTAssertEqual(title, "Finished successfully")
    }

    func testSystemBodyFallsBackWhenPromptMissing() {
        let body = NotificationManager.formatSystemBody(
            status: .waiting,
            workspaceName: "workspace",
            branch: "feature/article",
            lastMessage: "Review logs in /Users/dev/workspace/workspace-worktree/build/output.log before continuing",
            lastUserPrompt: ""
        )

        XCTAssertEqual(body, "Review logs in output.log before continuing")
    }

    func testIdleBodyFallsBackToLastMessageWhenPromptMissing() {
        let body = NotificationManager.formatBody(
            status: .idle,
            workspaceName: "workspace",
            branch: "feature/article",
            lastMessage: "Task completed",
            lastUserPrompt: ""
        )

        XCTAssertEqual(body, "Task completed")
    }
}
