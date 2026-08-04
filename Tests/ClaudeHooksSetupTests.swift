import XCTest
@testable import seahelm

final class ClaudeHooksSetupTests: XCTestCase {

    private func seahelmEntry() -> [[String: Any]] {
        [["hooks": [["type": "command", "command": "/Users/x/.local/bin/seahelm-hook claude-code"]]]]
    }

    private func legacyHttpEntry() -> [[String: Any]] {
        [["hooks": [["type": "http", "url": "http://127.0.0.1:8765/webhook"]]]]
    }

    private func userEntry() -> [[String: Any]] {
        [["hooks": [["type": "command", "command": "/usr/local/bin/my-own-worktree-maker"]]]]
    }

    // MARK: - WorktreeCreate must no longer be claimed

    func testWorktreeCreateIsNotInstalled() {
        // Claude Code treats WorktreeCreate as a *replacement* for its own git
        // behaviour and waits for the new path on stdout. Our bridge only ever
        // prints Stop decisions, so claiming this event broke every
        // `--worktree` create with "returned no worktree path".
        let (hooks, _) = ClaudeHooksSetup.reconcile(existingHooks: [:])
        XCTAssertNil(hooks["WorktreeCreate"])
    }

    func testObservationHooksAreStillInstalled() {
        let (hooks, changed) = ClaudeHooksSetup.reconcile(existingHooks: [:])
        XCTAssertTrue(changed)
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                      "Stop", "SubagentStop", "Notification", "CwdChanged"] {
            XCTAssertNotNil(hooks[event], "\(event) should still be installed")
        }
    }

    // MARK: - Retiring what we already wrote

    func testExistingSeahelmWorktreeCreateIsRemoved() {
        // Dropping it from requiredHooks only stops new installs; the entry a
        // previous version wrote has to be actively swept.
        let (hooks, changed) = ClaudeHooksSetup.reconcile(
            existingHooks: ["WorktreeCreate": seahelmEntry()])
        XCTAssertNil(hooks["WorktreeCreate"])
        XCTAssertTrue(changed)
    }

    func testLegacyHttpWorktreeCreateIsAlsoRemoved() {
        let (hooks, changed) = ClaudeHooksSetup.reconcile(
            existingHooks: ["WorktreeCreate": legacyHttpEntry()])
        XCTAssertNil(hooks["WorktreeCreate"])
        XCTAssertTrue(changed)
    }

    func testUserOwnedWorktreeCreateIsLeftAlone() {
        // Someone using this hook for a real non-git VCS must keep it. We only
        // clean up what we recognise as ours.
        let (hooks, _) = ClaudeHooksSetup.reconcile(
            existingHooks: ["WorktreeCreate": userEntry()])
        XCTAssertNotNil(hooks["WorktreeCreate"])
        XCTAssertTrue(ClaudeHooksSetup.entriesEqual(hooks["WorktreeCreate"], userEntry()))
    }

    // MARK: - Merge behaviour that must not regress

    func testUnrelatedUserHooksSurvive() {
        let (hooks, _) = ClaudeHooksSetup.reconcile(
            existingHooks: ["PermissionRequest": userEntry(), "TeammateIdle": userEntry()])
        XCTAssertNotNil(hooks["PermissionRequest"])
        XCTAssertNotNil(hooks["TeammateIdle"])
    }

    func testUserOwnedObservationHookIsNotOverwritten() {
        let (hooks, _) = ClaudeHooksSetup.reconcile(existingHooks: ["Stop": userEntry()])
        XCTAssertTrue(ClaudeHooksSetup.entriesEqual(hooks["Stop"], userEntry()))
    }

    func testAlreadyCorrectConfigReportsNoChange() {
        // Idempotence: a second launch must not rewrite the file, or we'd churn
        // the user's settings.json on every start.
        let (first, firstChanged) = ClaudeHooksSetup.reconcile(existingHooks: [:])
        XCTAssertTrue(firstChanged)
        let (_, secondChanged) = ClaudeHooksSetup.reconcile(existingHooks: first)
        XCTAssertFalse(secondChanged, "reconcile should be idempotent")
    }

    func testRetiredSweepAloneCountsAsAChange() {
        // Start from a settled config, then add back only the retired entry:
        // the sweep must be enough on its own to trigger a write.
        var settled = ClaudeHooksSetup.reconcile(existingHooks: [:]).hooks
        settled["WorktreeCreate"] = seahelmEntry()
        let (hooks, changed) = ClaudeHooksSetup.reconcile(existingHooks: settled)
        XCTAssertTrue(changed)
        XCTAssertNil(hooks["WorktreeCreate"])
    }
}
