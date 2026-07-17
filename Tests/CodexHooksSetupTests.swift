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

    /// Regression: the Codex wrapper ran the bridge as `>/dev/null 2>&1`, throwing
    /// away its stdout — which is exactly where a Stop-hook block decision lives.
    /// Codex's wire takes the same `{"decision":"block","reason":…}` Claude does,
    /// so suggestions were one redirect away from working all along.
    ///
    /// stderr must stay discarded AND must not be folded into stdout: `2>&1` would
    /// splice diagnostics into the JSON Codex parses.
    func testStopHookCommandKeepsStdoutSoBlockDecisionsReachCodex() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("hooks.json")
        XCTAssertTrue(CodexHooksSetup.ensureHooksJSONForTests(at: url))

        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any]
        let hooks = root?["hooks"] as? [String: Any]
        let stop = hooks?["Stop"] as? [[String: Any]]
        let command = (stop?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        let cmd = try XCTUnwrap(command)

        // Match the fd-1 redirect specifically: bare `>` and `1>`. A plain
        // `contains(">/dev/null")` also matches the `2>/dev/null` we *want*.
        XCTAssertFalse(cmd.contains(" >/dev/null") || cmd.contains("1>/dev/null"),
                       "stdout is discarded, so no block decision can reach Codex: \(cmd)")
        XCTAssertFalse(cmd.contains("2>&1"), "stderr merged into stdout would corrupt the JSON Codex parses: \(cmd)")
        XCTAssertTrue(cmd.contains("2>/dev/null"), "stderr should still be discarded: \(cmd)")
        XCTAssertTrue(cmd.contains(SeahelmHookInstaller.scriptPath()), "must invoke the bridge by absolute path: \(cmd)")
    }

    /// A stale seahelm-owned command must be rewritten, or every existing install
    /// keeps the stdout-discarding wrapper forever and never sees the fix.
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
        XCTAssertFalse(try XCTUnwrap(command).contains(">/dev/null 2>&1"))
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
