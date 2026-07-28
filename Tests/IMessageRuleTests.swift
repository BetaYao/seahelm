import XCTest
@testable import seahelm

final class IMessageRuleTests: XCTestCase {

    private func rule(name: String = "r",
                      from: String? = nil,
                      match: String? = nil,
                      prompt: String = "{{text}}",
                      enabled: Bool? = nil,
                      target: IMessageRuleTarget = .init(kind: .worktree, value: "/wt")) -> IMessageRule {
        IMessageRule(name: name, enabled: enabled, from: from, match: match,
                     prompt: prompt, target: target)
    }

    // MARK: - Matching

    func testEmptyPatternMatchesAnything() {
        XCTAssertEqual(IMessageRuleEngine.matches(pattern: nil, in: "anything"), [])
        XCTAssertEqual(IMessageRuleEngine.matches(pattern: "   ", in: "anything"), [])
    }

    func testPatternReturnsCaptureGroups() {
        let groups = IMessageRuleEngine.matches(pattern: "CPU.*?(\\d+)%.*?(\\w+)$",
                                                in: "CPU 95% host web01")
        XCTAssertEqual(groups, ["95", "web01"])
    }

    func testPatternIsCaseInsensitive() {
        XCTAssertNotNil(IMessageRuleEngine.matches(pattern: "alert", in: "ALERT: disk full"))
    }

    func testNonMatchingPatternReturnsNil() {
        XCTAssertNil(IMessageRuleEngine.matches(pattern: "disk", in: "CPU high"))
    }

    /// A typo'd regex that "matched everything" would fire an agent on every
    /// text the user receives, so an uncompilable pattern must fail closed.
    func testUncompilablePatternFailsClosed() {
        XCTAssertNil(IMessageRuleEngine.matches(pattern: "([unclosed", in: "anything"))
    }

    // MARK: - Rule selection

    func testBothPatternsMustMatch() {
        let rules = [rule(from: "^106", match: "CPU")]
        XCTAssertNil(IMessageRuleEngine.firstMatch(rules: rules, sender: "106900", text: "disk full"))
        XCTAssertNil(IMessageRuleEngine.firstMatch(rules: rules, sender: "+8613800138000",
                                                   text: "CPU high"))
        XCTAssertNotNil(IMessageRuleEngine.firstMatch(rules: rules, sender: "106900",
                                                      text: "CPU high"))
    }

    func testDisabledRuleIsSkipped() {
        let rules = [rule(name: "off", enabled: false), rule(name: "on")]
        let match = IMessageRuleEngine.firstMatch(rules: rules, sender: "a", text: "b")
        XCTAssertEqual(match?.rule.name, "on")
    }

    /// Two rules firing on one alert would put the same text in two panes.
    func testFirstMatchWins() {
        let rules = [rule(name: "specific", match: "CPU"), rule(name: "catch-all")]
        let match = IMessageRuleEngine.firstMatch(rules: rules, sender: "a", text: "CPU high")
        XCTAssertEqual(match?.rule.name, "specific")
    }

    func testNoRulesMeansNoMatch() {
        XCTAssertNil(IMessageRuleEngine.firstMatch(rules: [], sender: "a", text: "b"))
    }

    // MARK: - Prompt rendering

    func testPlaceholdersAreFilled() {
        let rules = [rule(match: "CPU.*?(\\d+)%",
                          prompt: "Alert from {{from}}: {{text}}\nCPU hit {{1}}%, investigate")]
        let match = IMessageRuleEngine.firstMatch(rules: rules, sender: "106900",
                                                  text: "host web01 CPU 95% sustained")

        XCTAssertEqual(match?.prompt,
                       "Alert from 106900: host web01 CPU 95% sustained\nCPU hit 95%, investigate")
    }

    /// An absent capture should vanish, not reach the agent as literal braces.
    func testUnfilledGroupPlaceholdersAreStripped() {
        let rendered = IMessageRuleEngine.render("a {{1}} b {{3}} c", text: "t", from: "f",
                                                 groups: ["X"])
        XCTAssertEqual(rendered, "a X b  c")
    }

    // MARK: - Target resolution

    private func pane(_ id: String, session: String = "", worktree: String = "", project: String = "")
        -> PaneSnapshot {
        PaneSnapshot(paneId: id, worktreePath: worktree, branch: "", project: project,
                     agentType: "", status: "", lastMessage: "", paneSessionKey: session)
    }

    func testPaneTargetMatchesSessionKeyOrInstanceId() {
        let panes = [pane("inst-1", session: "seahelm-repo-main")]
        XCTAssertEqual(IMessageRuleEngine.resolvePane(
            .init(kind: .pane, value: "seahelm-repo-main"), panes: panes)?.paneId, "inst-1")
        XCTAssertEqual(IMessageRuleEngine.resolvePane(
            .init(kind: .pane, value: "inst-1"), panes: panes)?.paneId, "inst-1")
    }

    func testWorktreeTargetMatchesPathOrLeafName() {
        let panes = [pane("p1", worktree: "/work/repo-worktrees/task/fix")]
        XCTAssertNotNil(IMessageRuleEngine.resolvePane(
            .init(kind: .worktree, value: "/work/repo-worktrees/task/fix"), panes: panes))
        XCTAssertNotNil(IMessageRuleEngine.resolvePane(
            .init(kind: .worktree, value: "fix"), panes: panes))
    }

    func testProjectTargetMatchesProjectName() {
        let panes = [pane("p1", project: "seahelm")]
        XCTAssertEqual(IMessageRuleEngine.resolvePane(
            .init(kind: .project, value: "seahelm"), panes: panes)?.paneId, "p1")
    }

    /// A rule pointing at a deleted worktree does nothing rather than guessing
    /// at a neighbouring pane.
    func testUnresolvableTargetReturnsNil() {
        let panes = [pane("p1", worktree: "/work/a")]
        XCTAssertNil(IMessageRuleEngine.resolvePane(
            .init(kind: .worktree, value: "/work/gone"), panes: panes))
    }

    func testEmptyTargetValueResolvesToNothing() {
        let panes = [pane("p1", worktree: "/work/a")]
        XCTAssertNil(IMessageRuleEngine.resolvePane(
            .init(kind: .worktree, value: "  "), panes: panes))
    }

    // MARK: - Config round-trip

    func testRulesDecodeFromConfigJSON() throws {
        let json = """
        {
          "allowed_handles": ["13800138000"],
          "rules": [{
            "name": "aliyun-cpu",
            "from": "^106",
            "match": "CPU.*?(\\\\d+)%",
            "prompt": "check {{1}}%",
            "target": { "kind": "worktree", "value": "/work/ops" }
          }]
        }
        """.data(using: .utf8)!

        let cfg = try JSONDecoder().decode(IMessageConfig.self, from: json)

        XCTAssertEqual(cfg.resolvedRules.count, 1)
        XCTAssertEqual(cfg.resolvedRules[0].name, "aliyun-cpu")
        XCTAssertEqual(cfg.resolvedRules[0].target.kind, .worktree)
        XCTAssertTrue(cfg.resolvedRules[0].isEnabled, "a rule with no `enabled` key is on")
    }

    func testConfigWithoutRulesIsEmptyNotNilCrash() throws {
        let cfg = try JSONDecoder().decode(IMessageConfig.self, from: "{}".data(using: .utf8)!)
        XCTAssertTrue(cfg.resolvedRules.isEmpty)
    }
}
