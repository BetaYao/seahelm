import XCTest
@testable import seahelm

final class AutopilotRulesTests: XCTestCase {
    // MARK: - yml

    func testParsesTheDocumentedExample() throws {
        let config = try AutomationConfig.parse(yaml: """
        first_mate:
          budget:
            max_concurrent_agents: 4
            pause_above_usage: 80
          quiet_hours: "23:00-08:00"
        rules:
          - name: fix-ci
            on: ci.failed
            when: { branch: "!main" }
            max_attempts: 2
            autonomy: { message_pane: auto, start_agent: ask }
            brief: |
              PR #{{pr}} failed.
          - name: triage
            on: { schedule: "0 9 * * 1-5" }
            brief: look at issues
        """)
        XCTAssertEqual(config.settings.maxConcurrentAgents, 4)
        XCTAssertEqual(config.settings.pauseAboveUsage, 80)
        XCTAssertNotNil(config.settings.quietHours)
        XCTAssertEqual(config.rules.count, 2)
        XCTAssertEqual(config.rules[0].trigger, .ciFailed)
        XCTAssertEqual(config.rules[0].maxAttempts, 2)
        XCTAssertEqual(config.rules[0].autonomy[.startAgent], .ask)
        XCTAssertEqual(config.rules[1].trigger, .schedule("0 9 * * 1-5"))
        XCTAssertEqual(config.autonomy(for: .deleteWorktree, rule: config.rules[0]), .ask, "falls back to the default")
    }

    func testMistakesAreNamedNotGuessed() {
        XCTAssertThrowsError(try AutomationConfig.parse(yaml: "rules:\n  - name: x\n    on: push\n    brief: b"))
        XCTAssertThrowsError(try AutomationConfig.parse(
            yaml: "rules:\n  - name: x\n    on: ci.failed\n    autonomy: { merge: auto }\n    brief: b"))
        XCTAssertThrowsError(try AutomationConfig.parse(
            yaml: "rules:\n  - name: x\n    on: ci.failed\n    autonomy: { start_agent: yes }\n    brief: b"))
        XCTAssertThrowsError(try AutomationConfig.parse(yaml: "rules:\n  - name: x\n    on: ci.failed"))
        XCTAssertThrowsError(try AutomationConfig.parse(yaml: "- just a list"))
    }

    func testABrokenFileStopsTheRepoRatherThanFallingBack() throws {
        let repo = NSTemporaryDirectory() + "auto-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: repo) }
        XCTAssertEqual(AutomationConfig.load(repoPath: repo).config, .builtIn)
        try FileManager.default.createDirectory(atPath: repo + "/.seahelm", withIntermediateDirectories: true)
        try "rules: [ {name: x} ]".write(toFile: repo + "/.seahelm/automations.yml", atomically: true, encoding: .utf8)
        let loaded = AutomationConfig.load(repoPath: repo)
        XCTAssertNil(loaded.config)
        XCTAssertNotNil(loaded.error)
    }

    func testBranchFiltersAndQuietHours() {
        XCTAssertFalse(BranchFilter(pattern: "!main").matches("main"))
        XCTAssertTrue(BranchFilter(pattern: "!main").matches("feat/x"))
        XCTAssertTrue(BranchFilter(pattern: "feat/*").matches("feat/x"))
        XCTAssertFalse(BranchFilter(pattern: "feat/*").matches("fix/x"))

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let at = { (h: Int, m: Int) in cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: h, minute: m))! }
        let night = QuietHours("23:00-08:00")!
        XCTAssertTrue(night.contains(at(23, 30), calendar: cal))
        XCTAssertTrue(night.contains(at(7, 59), calendar: cal))
        XCTAssertFalse(night.contains(at(8, 0), calendar: cal))
        XCTAssertFalse(night.contains(at(12, 0), calendar: cal))
        XCTAssertNil(QuietHours("25:00-08:00"))
    }
}

final class FirstMatePaneTests: XCTestCase {
    func testProvisionWritesTheManagedFilesAndKeepsStandingOrders() throws {
        let dir = NSTemporaryDirectory() + "fm-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FirstMatePane.provision(at: dir)
        let claude = try String(contentsOfFile: dir + "/CLAUDE.md", encoding: .utf8)
        XCTAssertTrue(claude.contains("You are First Mate"))
        let settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: dir + "/.claude/settings.json"))) as? [String: Any]
        let allow = (settings?["permissions"] as? [String: Any])?["allow"] as? [String]
        XCTAssertTrue(allow?.contains("Bash(seahelm:*)") == true)
        XCTAssertFalse(allow?.contains(where: { $0.hasPrefix("Bash(git push") }) == true,
                       "a push is not First Mate's to make unasked")

        try "keep off saas-mono".write(toFile: dir + "/standing-orders.md", atomically: true, encoding: .utf8)
        try "stale".write(toFile: dir + "/CLAUDE.md", atomically: true, encoding: .utf8)
        FirstMatePane.provision(at: dir)
        XCTAssertEqual(try String(contentsOfFile: dir + "/standing-orders.md", encoding: .utf8), "keep off saas-mono")
        XCTAssertTrue(try String(contentsOfFile: dir + "/CLAUDE.md", encoding: .utf8).contains("You are First Mate"),
                      "a stale managed file is rewritten")
    }

    func testFirstMateNeverInheritsABypass() throws {
        XCTAssertTrue(FirstMatePane.launchCommand.contains("--permission-mode default"))
        XCTAssertFalse(FirstMatePane.launchCommand.contains("dangerously"))
        let permissions = FirstMatePane.permissions["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["defaultMode"] as? String, "default")
    }

    func testAnOldSessionIsNotCurrent() {
        let dir = NSTemporaryDirectory() + "fmv-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertFalse(FirstMatePane.sessionIsCurrent(at: dir))
        try? "1".write(toFile: dir + "/.session-version", atomically: true, encoding: .utf8)
        XCTAssertFalse(FirstMatePane.sessionIsCurrent(at: dir))
        FirstMatePane.markSessionCurrent(at: dir)
        XCTAssertTrue(FirstMatePane.sessionIsCurrent(at: dir))
    }


}

final class FirstMateAgentTests: XCTestCase {
    /// Neither agent may start without its bounds.
    func testEachAgentStartsHeld() {
        XCTAssertEqual(FirstMatePane.launchCommand(for: .claudeCode), "claude --permission-mode default")
        let codex = FirstMatePane.launchCommand(for: .codex)
        XCTAssertTrue(codex.contains("--sandbox workspace-write"), codex)
        XCTAssertTrue(codex.contains("--ask-for-approval on-request"), codex)
        XCTAssertTrue(codex.contains("network_access=true"), "gh and the seahelm socket need it")
        XCTAssertTrue(codex.hasPrefix("codex --no-daemon "), "its hooks must name its own session")
        for agent in FirstMatePane.agents {
            XCTAssertFalse(FirstMatePane.launchCommand(for: agent).contains("dangerously"), "\(agent)")
        }
    }

    func testSwitchingAgentMakesTheSessionStale() {
        let dir = NSTemporaryDirectory() + "fma-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FirstMatePane.markSessionCurrent(agent: .claudeCode, at: dir)
        XCTAssertTrue(FirstMatePane.sessionIsCurrent(agent: .claudeCode, at: dir))
        XCTAssertFalse(FirstMatePane.sessionIsCurrent(agent: .codex, at: dir))
    }

    func testBothAgentsFindTheInstructions() throws {
        let dir = NSTemporaryDirectory() + "fmi-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FirstMatePane.provision(at: dir)
        for name in ["CLAUDE.md", "AGENTS.md"] {
            XCTAssertTrue(try String(contentsOfFile: dir + "/" + name, encoding: .utf8).contains("You are First Mate"), name)
        }
    }
}
