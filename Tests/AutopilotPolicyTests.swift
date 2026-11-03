import XCTest
@testable import seahelm

private final class GateFakeDataSource: ControlDataSource {
    var gate: AutopilotGate = .allow
    var gated: [(AutopilotAction, String)] = []
    var ran: [String] = []
    var sent: [String] = []

    func snapshotPanes() -> [PaneSnapshot] { [] }
    func readPane(paneId: String, source: String, lines: Int) -> String? { "" }
    func ingestHook(json: [String: Any]) {}
    func sendText(paneId: String, text: String, enter: Bool) -> Bool { sent.append(text); return true }
    func autopilotGate(action: AutopilotAction, method: String, params: [String: Any]) -> AutopilotGate {
        gated.append((action, method)); return gate
    }
    func autopilotDidRun(method: String, result: ControlResult) { ran.append(method) }
}

final class AutopilotPolicyTests: XCTestCase {
    private func call(_ router: ControlRouter, _ method: String, caller: String?,
                      _ params: [String: Any] = [:]) -> ControlResult {
        var p = params
        if let caller { p["_meta"] = ["caller": caller] }
        return router.handle(method: method, params: p)
    }

    // MARK: - router

    func testFirstMateReadsFreely() {
        let ds = GateFakeDataSource()
        let router = ControlRouter(dataSource: ds)
        guard case .ok = call(router, "pane.list", caller: FirstMatePane.sessionName) else { return XCTFail() }
        XCTAssertTrue(ds.gated.isEmpty)
    }

    func testWhatIsNotFirstMatesIsRefusedOutright() {
        let ds = GateFakeDataSource()
        let router = ControlRouter(dataSource: ds)
        guard case .error(let code, _) = call(router, "pane.close", caller: FirstMatePane.sessionName,
                                              ["pane_id": "p"]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.autopilotRefused)
        XCTAssertTrue(ds.gated.isEmpty)
    }

    func testAQueuedActionRunsNothing() {
        let ds = GateFakeDataSource()
        ds.gate = .queued("autopilot-1")
        let router = ControlRouter(dataSource: ds)
        guard case .ok(let r) = call(router, "pane.run", caller: FirstMatePane.sessionName,
                                     ["pane_id": "p", "command": "fix it"]) else { return XCTFail() }
        XCTAssertEqual(r["queued"] as? String, "approval")
        XCTAssertEqual(r["card"] as? String, "autopilot-1")
        XCTAssertTrue(ds.sent.isEmpty, "typed into the pane before the user said yes")
        XCTAssertEqual(ds.gated.map(\.0), [.messagePane])
    }

    func testAnAllowedActionRunsAndIsReported() {
        let ds = GateFakeDataSource()
        let router = ControlRouter(dataSource: ds)
        _ = call(router, "pane.run", caller: FirstMatePane.sessionName, ["pane_id": "p", "command": "go"])
        XCTAssertEqual(ds.sent, ["go"])
        XCTAssertEqual(ds.ran, ["pane.run"])
    }

    func testADeniedActionSaysWhy() {
        let ds = GateFakeDataSource()
        ds.gate = .deny("start_agent is set to deny")
        let router = ControlRouter(dataSource: ds)
        guard case .error(let code, let message) = call(router, "worktree.create", caller: FirstMatePane.sessionName,
                                                        ["repo_path": "/r", "prompt": "x"]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.autopilotRefused)
        XCTAssertEqual(message, "start_agent is set to deny")
    }

    func testEveryoneElseIsUngated() {
        let ds = GateFakeDataSource()
        ds.gate = .deny("no")
        let router = ControlRouter(dataSource: ds)
        _ = call(router, "pane.run", caller: "seahelm-some-pane", ["pane_id": "p", "command": "go"])
        _ = call(router, "pane.run", caller: nil, ["pane_id": "p", "command": "go"])
        XCTAssertTrue(ds.gated.isEmpty)
        XCTAssertEqual(ds.sent, ["go", "go"])
    }

    /// First Mate must not approve its own cards, nor read the state built for the user.
    func testFirstMateCannotAnswerItsOwnCards() {
        XCTAssertEqual(AutopilotPolicy.classify(method: "autopilot.answer"), .forbidden)
        let router = ControlRouter(dataSource: GateFakeDataSource())
        guard case .error(let code, _) = call(router, "autopilot.answer", caller: FirstMatePane.sessionName,
                                              ["card": "c", "option": "Approve"]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.autopilotRefused)
    }

    func testResultsReadAsWords() {
        XCTAssertEqual(AutopilotCoordinator.compact(["deleting": true, "worktree_path": "/wt/feat-x"]), "deleting feat-x")
        XCTAssertEqual(AutopilotCoordinator.compact(["worktree_path": "/wt/fix-ci", "pane_session_key": "k"]), "started in fix-ci")
        XCTAssertEqual(AutopilotCoordinator.compact(["sent": true]), "sent")
        XCTAssertEqual(AutopilotCoordinator.compact([:]), "done")
    }

    func testClassification() {
        XCTAssertEqual(AutopilotPolicy.classify(method: "pane.read"), .open)
        XCTAssertEqual(AutopilotPolicy.classify(method: "pane.send_keys"), .gated(.messagePane))
        XCTAssertEqual(AutopilotPolicy.classify(method: "worktree.create"), .gated(.startAgent))
        XCTAssertEqual(AutopilotPolicy.classify(method: "worktree.delete"), .gated(.deleteWorktree))
        XCTAssertEqual(AutopilotPolicy.classify(method: "layout.apply"), .forbidden)
        XCTAssertEqual(AutopilotPolicy.classify(method: "pane.fork"), .forbidden)
    }

    // MARK: - the coordinator's levels

    private func coordinator() -> AutopilotCoordinator {
        let dir = NSTemporaryDirectory() + "autopilot-\(UUID().uuidString)"
        return AutopilotCoordinator(auditPath: dir + "/audit.jsonl", ledgerPath: dir + "/state.json")
    }

    func testDefaultsApplyWhenNothingIsBeingHandled() {
        let c = coordinator()
        XCTAssertEqual(c.level(for: .messagePane), .auto)
        XCTAssertEqual(c.level(for: .startAgent), .ask)
        XCTAssertEqual(c.level(for: .deleteWorktree), .ask)
    }

    func testTheRuleBeingHandledDecides() {
        let c = coordinator()
        let lenient = AutomationRule(name: "r", trigger: .ciFailed, autonomy: [.startAgent: .auto], brief: "b")
        c.setActiveRulesForTesting([(lenient, .builtIn)])
        XCTAssertEqual(c.level(for: .startAgent), .auto)
        let strict = AutomationRule(name: "s", trigger: .ciFailed, autonomy: [.messagePane: .deny], brief: "b")
        c.setActiveRulesForTesting([(lenient, .builtIn), (strict, .builtIn)])
        XCTAssertEqual(c.level(for: .messagePane), .deny, "the strictest of the batch")
    }

    /// "Just do it" in conversation must not loosen what a rule asks about.
    func testTalkingCannotLoosenARule() {
        let c = coordinator()
        let lenient = AutomationRule(name: "r", trigger: .ciFailed, autonomy: [.startAgent: .auto], brief: "b")
        c.setActiveRulesForTesting([(lenient, .builtIn)], userSpoke: true)
        XCTAssertEqual(c.level(for: .startAgent), .ask)
    }

    func testGateQueuesAnApprovalAndRaisesACard() {
        let c = coordinator()
        c.activateForTesting()
        var raised: [String] = []
        c.onRequestApproval = { id, _ in raised.append(id) }
        let gate = c.gate(action: .deleteWorktree, method: "worktree.delete", params: ["worktree_path": "/wt/a"])
        guard case .queued(let id) = gate else { return XCTFail("\(gate)") }
        XCTAssertEqual(raised, [id])
        XCTAssertEqual(c.state.pendingApprovals, 1)

        var closed: [String] = []
        c.onApprovalClosed = { closed.append($0) }
        c.resolveApproval(id, approved: false)
        XCTAssertEqual(closed, [id])
        XCTAssertEqual(c.state.pendingApprovals, 0)
        XCTAssertEqual(c.audit.recent().last?.text, "rejected: Delete worktree a")
    }

    /// An approved card runs the call, once: it must not reach the gate again
    /// (which raised a second card, ran nothing, and reported "done").
    func testAnApprovedCallRunsPastTheGate() {
        let ds = GateFakeDataSource()
        ds.gate = .queued("autopilot-again")
        let router = ControlRouter(dataSource: ds)
        let c = coordinator()
        c.activateForTesting()
        let ran = expectation(description: "ran")
        c.execute = { method, params in
            let result = router.handle(method: method, params: params)
            ran.fulfill()
            return result
        }
        let params: [String: Any] = ["_meta": ["caller": FirstMatePane.sessionName], "worktree_path": "/wt/a"]
        let gate = c.gate(action: .deleteWorktree, method: "worktree.delete", params: params)
        guard case .queued(let id) = gate else { return XCTFail("\(gate)") }
        c.resolveApproval(id, approved: true)
        wait(for: [ran], timeout: 2)
        XCTAssertTrue(ds.gated.isEmpty, "the approved call was gated a second time")
        XCTAssertEqual(c.state.pendingApprovals, 0, "a second card went up")
    }

    func testPausedOrOffRefuses() {
        let off = coordinator()
        XCTAssertEqual(off.gate(action: .messagePane, method: "pane.run", params: [:]), .deny("First Mate is off"))
        let paused = coordinator()
        paused.activateForTesting(paused: true)
        XCTAssertEqual(paused.gate(action: .messagePane, method: "pane.run", params: [:]), .deny("First Mate is paused"))
    }

    func testUsageAboveTheLimitStopsNewAgents() throws {
        let repo = NSTemporaryDirectory() + "repo-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: repo + "/.seahelm", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try """
        first_mate:
          budget: { pause_above_usage: 80, max_concurrent_agents: 1 }
        rules: []
        """.write(toFile: repo + "/.seahelm/automations.yml", atomically: true, encoding: .utf8)
        let c = coordinator()
        c.activateForTesting()
        c.usagePercent = 85
        guard case .deny(let why) = c.gate(action: .startAgent, method: "worktree.create",
                                           params: ["repo_path": repo, "prompt": "x"]) else { return XCTFail() }
        XCTAssertTrue(why.contains("pause_above_usage"), why)

        c.usagePercent = 10
        c.didRun(method: "worktree.create", result: .ok(["worktree_path": "/wt/new"]))
        c.liveWorktrees = { ["/wt/new"] }
        guard case .deny(let cap) = c.gate(action: .startAgent, method: "worktree.create",
                                           params: ["repo_path": repo, "prompt": "x"]) else { return XCTFail() }
        XCTAssertTrue(cap.contains("max_concurrent_agents"), cap)
        c.liveWorktrees = { [] }
        if case .deny = c.gate(action: .startAgent, method: "worktree.create", params: ["repo_path": repo, "prompt": "x"]) {
            XCTFail("a deleted worktree still counted against the cap")
        }
    }
}
