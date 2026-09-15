import XCTest
@testable import seahelm

final class CodexHooksSetupTests: XCTestCase {

    func testEnsureCodexHooksFeatureEnabledAppendsFeaturesSection() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("config.toml")

        XCTAssertTrue(CodexHooksSetup.ensureCodexHooksFeatureEnabledForTests(at: url))

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("[features]"))
        XCTAssertTrue(contents.contains("codex_hooks = true"))
    }

    /// Stop is a passive reporting hook now. The wrapper must discard both the
    /// bridge's stdout and stderr so no control-socket response can be mistaken
    /// for a Codex hook decision.
    func testHookCommandDiscardsBridgeOutput() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("hooks.json")
        XCTAssertTrue(CodexHooksSetup.ensureHooksJSONForTests(at: url))

        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any]
        let hooks = root?["hooks"] as? [String: Any]
        let stop = hooks?["Stop"] as? [[String: Any]]
        let command = (stop?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        let cmd = try XCTUnwrap(command)

        // Both file descriptors are discarded because the bridge has no hook
        // decision to return.
        XCTAssertTrue(cmd.contains(">/dev/null 2>&1"),
                      "bridge output must not reach Codex: \(cmd)")
        XCTAssertTrue(cmd.contains(SeahelmHookInstaller.scriptPath()), "must invoke the bridge by absolute path: \(cmd)")
    }

    /// A stale seahelm-owned command must be rewritten so existing installs also
    /// become passive reporting hooks.
    func testStaleSeahelmOwnedCommandIsUpgraded() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("hooks.json")
        let stale = "/bin/sh -lc '\(SeahelmHookInstaller.scriptPath()) >/dev/null 2>&1 || true'"
        try JSONSerialization.data(withJSONObject: [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": stale]]]]],
        ]).write(to: url)

        XCTAssertTrue(CodexHooksSetup.ensureHooksJSONForTests(at: url))

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let hooks = root?["hooks"] as? [String: Any]
        let stop = hooks?["Stop"] as? [[String: Any]]
        let command = (stop?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        XCTAssertNotEqual(command, stale, "stale seahelm hook was left in place")
        XCTAssertTrue(try XCTUnwrap(command).contains(">/dev/null 2>&1"))
    }

    func testEnsureCodexHooksFeatureEnabledReplacesFalse() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("config.toml")
        try """
        [features]
        codex_hooks = false
        apps = true
        """.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(CodexHooksSetup.ensureCodexHooksFeatureEnabledForTests(at: url))

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("codex_hooks = true"))
        XCTAssertFalse(contents.contains("codex_hooks = false"))
        XCTAssertTrue(contents.contains("apps = true"))
    }

    func testEnsureHooksJSONAddsRequiredEvents() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("hooks.json")

        XCTAssertTrue(CodexHooksSetup.ensureHooksJSONForTests(at: url))

        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"] {
            XCTAssertNotNil(hooks[event], "Missing hook config for \(event)")
        }
    }

    func testEnsureHooksJSONPreservesExistingEvent() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("hooks.json")
        let existing: [String: Any] = [
            "hooks": [
                "SessionStart": [["hooks": [["type": "command", "command": "existing-command"]]]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)

        XCTAssertTrue(CodexHooksSetup.ensureHooksJSONForTests(at: url))

        let updatedData = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let firstGroup = try XCTUnwrap(sessionStart.first)
        let hookEntries = try XCTUnwrap(firstGroup["hooks"] as? [[String: Any]])
        XCTAssertEqual(hookEntries.first?["command"] as? String, "existing-command")
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
