import XCTest
@testable import seahelm

final class FirstMateSettingsTests: XCTestCase {
    private func sample() -> AutomationConfig {
        var config = AutomationConfig(rules: [
            AutomationRule(name: "fix-ci", trigger: .ciFailed, branch: BranchFilter(pattern: "!main"),
                           maxAttempts: 2, autonomy: [.messagePane: .auto, .startAgent: .ask],
                           brief: "PR #{{pr}} failed.\nRead the log first."),
            AutomationRule(name: "triage", trigger: .schedule("0 9 * * 1-5"), brief: "look", enabled: false),
        ])
        config.settings = AutomationSettings(maxConcurrentAgents: 3, pauseAboveUsage: 80,
                                             quietHours: QuietHours("23:00-08:00"))
        return config
    }

    /// What Settings writes must read back as the same rules — `!main` in
    /// particular, which YAML takes for a tag unless it is quoted.
    func testWrittenFileReadsBackTheSame() throws {
        let config = sample()
        let text = config.yaml()
        XCTAssertTrue(text.hasPrefix("# First Mate rules"))
        XCTAssertEqual(try AutomationConfig.parse(yaml: text), config, text)
    }

    func testADisabledRuleIsKeptButNeverFires() {
        let config = sample()
        XCTAssertTrue(config.rules(for: .schedule("0 9 * * 1-5")).isEmpty)
        XCTAssertEqual(config.rules(for: .ciFailed).map(\.name), ["fix-ci"])
    }

    func testTheUsersDefaultsSitUnderEveryRule() {
        var config = sample()
        config.defaults = AutomationConfig.defaults(overriding: ["delete_worktree": "deny", "bogus": "auto",
                                                                  "start_agent": "nonsense"])
        XCTAssertEqual(config.autonomy(for: .deleteWorktree, rule: config.rules[0]), .deny)
        XCTAssertEqual(config.autonomy(for: .startAgent, rule: config.rules[0]), .ask, "the rule's own level wins")
        XCTAssertEqual(config.autonomy(for: .startAgent, rule: nil), .ask, "an unreadable value keeps the default")
    }

    func testWriteCreatesTheFileInTheRepo() throws {
        let repo = NSTemporaryDirectory() + "fms-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        XCTAssertFalse(AutomationConfig.hasFile(repoPath: repo))
        try sample().write(repoPath: repo)
        XCTAssertTrue(AutomationConfig.hasFile(repoPath: repo))
        XCTAssertEqual(AutomationConfig.load(repoPath: repo).config, sample())
    }

    // MARK: - the editor

    func testEditorAddsAndRemovesRules() {
        let view = FirstMateRulesView(config: AutomationConfig(rules: []))
        var changes: [AutomationConfig] = []
        view.onChange = { changes.append($0) }
        view.perform(Selector(("addRule")))
        XCTAssertEqual(view.config.rules.count, 1)
        XCTAssertEqual(changes.count, 1)
        view.perform(Selector(("removeRule")))
        XCTAssertTrue(view.config.rules.isEmpty)
        view.load(sample())
        XCTAssertEqual(view.config, sample())
    }
}
