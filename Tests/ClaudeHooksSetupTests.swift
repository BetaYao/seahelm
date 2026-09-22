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

    /// A user's own hook on an event we need must survive — and ours has to go
    /// in beside it. Bailing out of the whole event (what this used to do) left
    /// that event reporting nothing to seahelm, silently.
    func testUserOwnedObservationHookKeepsOursAlongside() throws {
        let (hooks, changed) = ClaudeHooksSetup.reconcile(existingHooks: ["Stop": userEntry()])
        XCTAssertTrue(changed)

        let groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let commands = groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains("/usr/local/bin/my-own-worktree-maker"),
                      "user hook was disturbed: \(commands)")
        XCTAssertEqual(commands.filter { $0.contains("seahelm-hook") }.count, 1,
                       "ours must be present exactly once: \(commands)")
    }

    /// The worse half of the same bug: `isSeahelmManaged` tested the whole event
    /// for the string `seahelm-hook`, so an event holding ours *and* the user's
    /// counted as ours and was replaced wholesale — deleting theirs.
    func testMixedEventDoesNotLoseTheUserHook() throws {
        let mixed: [[String: Any]] = [
            ["hooks": [["type": "command", "command": "/usr/local/bin/my-own-worktree-maker"]]],
            ["hooks": [["type": "http", "url": "http://127.0.0.1:8765/webhook"]]],
        ]
        let (hooks, _) = ClaudeHooksSetup.reconcile(existingHooks: ["Stop": mixed])

        let groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let entries = groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        XCTAssertTrue(entries.contains { $0["command"] as? String == "/usr/local/bin/my-own-worktree-maker" },
                      "user hook was deleted: \(entries)")
        // The legacy http entry is ours, so it migrates rather than doubling up.
        XCTAssertEqual(entries.filter { ($0["command"] as? String)?.contains("seahelm-hook") == true }.count, 1)
        XCTAssertFalse(entries.contains { $0["type"] as? String == "http" }, "legacy entry was not migrated")
    }

    /// A retired event holding both is the mirror image: ours goes, theirs stays.
    func testRetiredSweepKeepsAUserHookInTheSameEvent() throws {
        let mixed: [[String: Any]] = [
            ["hooks": [["type": "command", "command": "/usr/local/bin/my-own-worktree-maker"]]],
            ["hooks": [["type": "command", "command": "/Users/x/.local/bin/seahelm-hook claude-code"]]],
        ]
        let (hooks, changed) = ClaudeHooksSetup.reconcile(existingHooks: ["WorktreeCreate": mixed])
        XCTAssertTrue(changed)

        let groups = try XCTUnwrap(hooks["WorktreeCreate"] as? [[String: Any]])
        let commands = groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertEqual(commands, ["/usr/local/bin/my-own-worktree-maker"])
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
