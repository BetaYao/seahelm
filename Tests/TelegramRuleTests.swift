import XCTest
@testable import seahelm

/// The rule shape Settings writes to seahelm-gateway, and the target lookup the
/// rule editor uses to show which pane a stored rule points at.
final class TelegramRuleTests: XCTestCase {
    private func pane(_ id: String, session: String = "", worktree: String = "", project: String = "")
        -> PaneSnapshot {
        PaneSnapshot(paneId: id, worktreePath: worktree, branch: "", project: project,
                     agentType: "", status: "", lastMessage: "", paneSessionKey: session)
    }

    func testPaneTargetMatchesSessionKeyOrInstanceId() {
        let panes = [pane("inst-1", session: "seahelm-repo-main")]
        XCTAssertEqual(TelegramRuleTarget(kind: .pane, value: "seahelm-repo-main").resolvePane(in: panes)?.paneId, "inst-1")
        XCTAssertEqual(TelegramRuleTarget(kind: .pane, value: "inst-1").resolvePane(in: panes)?.paneId, "inst-1")
    }

    func testWorktreeTargetMatchesPathOrLeafName() {
        let panes = [pane("p1", worktree: "/work/repo-worktrees/task/fix")]
        XCTAssertNotNil(TelegramRuleTarget(kind: .worktree, value: "/work/repo-worktrees/task/fix").resolvePane(in: panes))
        XCTAssertNotNil(TelegramRuleTarget(kind: .worktree, value: "fix").resolvePane(in: panes))
    }

    func testProjectTargetMatchesProjectName() {
        let panes = [pane("p1", project: "seahelm")]
        XCTAssertEqual(TelegramRuleTarget(kind: .project, value: "seahelm").resolvePane(in: panes)?.paneId, "p1")
    }

    /// A rule pointing at a deleted worktree does nothing rather than guessing
    /// at a neighbouring pane.
    func testUnresolvableTargetReturnsNil() {
        let panes = [pane("p1", worktree: "/work/a")]
        XCTAssertNil(TelegramRuleTarget(kind: .worktree, value: "/work/gone").resolvePane(in: panes))
    }

    func testEmptyTargetValueResolvesToNothing() {
        let panes = [pane("p1", worktree: "/work/a")]
        XCTAssertNil(TelegramRuleTarget(kind: .worktree, value: "  ").resolvePane(in: panes))
    }

    // MARK: - Wire shape

    func testRulesDecodeFromGatewayConfig() {
        let settings = GatewaySettings(["telegram": ["rules": [[
            "name": "aliyun-cpu", "from": "^106", "match": "CPU.*?(\\d+)%",
            "prompt": "check {{1}}%", "target": ["kind": "worktree", "value": "/work/ops"],
        ]]]])
        XCTAssertEqual(settings.telegram.rules.count, 1)
        XCTAssertEqual(settings.telegram.rules[0].name, "aliyun-cpu")
        XCTAssertEqual(settings.telegram.rules[0].target.kind, .worktree)
        XCTAssertTrue(settings.telegram.rules[0].isEnabled, "a rule with no `enabled` key is on")
    }

    func testRulesRoundTripThroughWireJSON() {
        let rules = [TelegramRule(name: "a", enabled: false, from: "x", match: "y", prompt: "p",
                                  target: .init(kind: .pane, value: "k"))]
        let back = GatewaySettings(["telegram": ["rules": GatewaySettings.rulesJSON(rules)]])
        XCTAssertEqual(back.telegram.rules, rules)
    }

    func testConfigWithoutRulesIsEmpty() {
        XCTAssertTrue(GatewaySettings([:]).telegram.rules.isEmpty)
    }
}
