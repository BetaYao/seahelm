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

    // MARK: - Broadened error classification (agent/tool/API wording)

    private func errorTitle(_ message: String) -> String {
        NotificationManager.formatTitle(
            status: .error, workspaceName: "ws", branch: "br",
            paneIndex: 1, paneCount: 1, lastMessage: message
        )
    }

    func testRateLimitErrorTitle() {
        XCTAssertEqual(errorTitle("Error: you have hit your usage limit for today"),
                       "Rate limited — ws / br")
        XCTAssertEqual(errorTitle("API request failed: overloaded_error"),
                       "Rate limited — ws / br")
    }

    func testTimeoutErrorTitle() {
        XCTAssertEqual(errorTitle("request timed out after 60s"), "Timed out — ws / br")
    }

    func testNetworkErrorTitle() {
        XCTAssertEqual(errorTitle("connect ECONNREFUSED 127.0.0.1:443"), "Network error — ws / br")
    }

    func testCommandNotFoundTitle() {
        XCTAssertEqual(errorTitle("zsh: command not found: pnpm"), "Command not found — ws / br")
    }

    func testApiErrorTitle() {
        XCTAssertEqual(errorTitle("stream error: unexpected EOF"), "API error — ws / br")
    }

    func testExistingCdErrorStillClassifiedFirst() {
        // Precedence preserved: cd failures still win over the new patterns.
        XCTAssertEqual(errorTitle("Failed Bash cd /tmp/x — no such file"), "cd failed — ws / br")
    }

    func testRateLimitErrorBody() {
        let body = NotificationManager.formatBody(
            status: .error, workspaceName: "ws", branch: "br",
            lastMessage: "Error: usage limit reached, retry after 5m"
        )
        XCTAssertEqual(body, "Agent hit a rate/usage limit")
    }

    // MARK: - Stability gate

    func testShouldNotifyOnlyFiresOnRunningToTerminalEdge() {
        let m = NotificationManager.shared
        // Qualifying edges.
        XCTAssertTrue(m.shouldNotify(cooldownKey: "k1", oldStatus: .running, newStatus: .idle))
        XCTAssertTrue(m.shouldNotify(cooldownKey: "k1", oldStatus: .running, newStatus: .waiting))
        XCTAssertTrue(m.shouldNotify(cooldownKey: "k1", oldStatus: .running, newStatus: .error))
        // Wrong origin.
        XCTAssertFalse(m.shouldNotify(cooldownKey: "k1", oldStatus: .idle, newStatus: .waiting))
        // Non-terminal destination.
        XCTAssertFalse(m.shouldNotify(cooldownKey: "k1", oldStatus: .running, newStatus: .running))
    }

    func testShouldDeliverPendingHoldsOnlyWhenStatusUnchanged() {
        // Status still at the target → deliver.
        XCTAssertTrue(NotificationManager.shouldDeliverPending(targetStatus: .idle, latestStatus: .idle))
        // Flicked back to running mid-turn → drop the flash.
        XCTAssertFalse(NotificationManager.shouldDeliverPending(targetStatus: .idle, latestStatus: .running))
        // Moved to a different terminal state → drop (a fresh edge scheduled its own).
        XCTAssertFalse(NotificationManager.shouldDeliverPending(targetStatus: .idle, latestStatus: .waiting))
        // No observation → drop.
        XCTAssertFalse(NotificationManager.shouldDeliverPending(targetStatus: .idle, latestStatus: nil))
    }
}
