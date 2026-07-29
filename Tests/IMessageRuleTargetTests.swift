import XCTest
import AppKit
@testable import seahelm

/// The target cascade is three popups editing one stored value, so the failure
/// mode is silent: pick a worktree, watch it snap back to "Any worktree".
final class IMessageRuleTargetTests: XCTestCase {
    private func pane(_ key: String, worktree: String, branch: String,
                      project: String = "saas-mono", title: String = "") -> PaneSnapshot {
        PaneSnapshot(paneId: "id-\(key)", worktreePath: worktree, branch: branch,
                     project: project, agentType: "claudeCode", status: "idle",
                     lastMessage: "", paneSessionKey: key, title: title)
    }

    private func popup(_ view: NSView, _ id: String) -> NSPopUpButton {
        func find(_ v: NSView) -> NSPopUpButton? {
            if let p = v as? NSPopUpButton, p.accessibilityIdentifier() == id { return p }
            for child in v.subviews {
                if let hit = find(child) { return hit }
            }
            return nil
        }
        return find(view)!
    }

    func testPickingAWorktreeSticks() {
        let view = IMessageRulesView(rules: [
            IMessageRule(name: "aliyun", prompt: "{{text}}",
                         target: .init(kind: .project, value: "saas-mono")),
        ])
        view.panes = [
            pane("k1", worktree: "/work/a", branch: "task/alpha", title: "claude"),
            pane("k2", worktree: "/work/b", branch: "task/beta", title: "claude"),
        ]
        view.selectRule(at: 0)

        let worktreePopup = popup(view, "settings.imessage.ruleTargetWorktree")
        XCTAssertEqual(worktreePopup.itemTitles, ["Any worktree", "task/alpha", "task/beta"])

        worktreePopup.selectItem(at: 2)
        worktreePopup.sendAction(worktreePopup.action, to: worktreePopup.target)

        XCTAssertEqual(worktreePopup.titleOfSelectedItem, "task/beta",
                       "the picked worktree snapped back")
        XCTAssertEqual(view.rules[0].target, IMessageRuleTarget(kind: .worktree, value: "/work/b"))
    }

    /// The rule points at a pane that is no longer running, so its key sits in
    /// the pane popup with nothing above it. Picking a worktree has to win over
    /// that leftover rather than being snapped back by it.
    func testPickingAWorktreeClearsAStalePaneTarget() {
        let view = IMessageRulesView(rules: [
            IMessageRule(name: "aliyun", prompt: "{{text}}",
                         target: .init(kind: .pane, value: "closed-pane-3")),
        ])
        view.panes = [pane("k1", worktree: "/work/a", branch: "task/alpha", title: "claude")]
        view.selectRule(at: 0)

        let worktreePopup = popup(view, "settings.imessage.ruleTargetWorktree")
        XCTAssertEqual(worktreePopup.titleOfSelectedItem, "Any worktree")

        worktreePopup.selectItem(withTitle: "task/alpha")
        worktreePopup.sendAction(worktreePopup.action, to: worktreePopup.target)

        XCTAssertEqual(worktreePopup.titleOfSelectedItem, "task/alpha",
                       "the dead pane target snapped the worktree back")
        XCTAssertEqual(view.rules[0].target, IMessageRuleTarget(kind: .worktree, value: "/work/a"))
    }

    /// Moving up the chain drops what was below it.
    func testPickingAnyWorktreeFallsBackToTheProject() {
        let view = IMessageRulesView(rules: [
            IMessageRule(name: "aliyun", prompt: "{{text}}",
                         target: .init(kind: .pane, value: "k1")),
        ])
        view.panes = [pane("k1", worktree: "/work/a", branch: "task/alpha", title: "claude")]
        view.selectRule(at: 0)

        let worktreePopup = popup(view, "settings.imessage.ruleTargetWorktree")
        worktreePopup.selectItem(withTitle: "Any worktree")
        worktreePopup.sendAction(worktreePopup.action, to: worktreePopup.target)

        XCTAssertEqual(view.rules[0].target,
                       IMessageRuleTarget(kind: .project, value: "saas-mono"))
    }

    func testPickingAPaneStoresItsSessionKeyNotItsTitle() {
        let view = IMessageRulesView(rules: [
            IMessageRule(name: "aliyun", prompt: "{{text}}",
                         target: .init(kind: .worktree, value: "/work/a")),
        ])
        view.panes = [
            pane("k1", worktree: "/work/a", branch: "task/alpha", title: "claude"),
            pane("k2", worktree: "/work/a", branch: "task/alpha", title: "claude"),
        ]
        view.selectRule(at: 0)

        let panePopup = popup(view, "settings.imessage.ruleTargetPane")
        panePopup.selectItem(at: 2)   // the second same-titled pane
        panePopup.sendAction(panePopup.action, to: panePopup.target)

        XCTAssertEqual(view.rules[0].target, IMessageRuleTarget(kind: .pane, value: "k2"))
    }
}
