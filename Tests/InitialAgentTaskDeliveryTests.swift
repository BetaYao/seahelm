import XCTest
@testable import seahelm

final class InitialAgentTaskDeliveryTests: XCTestCase {
    private typealias Snapshot = InitialAgentTaskDelivery.PaneSnapshot

    private static let claudePrompt = """
     ▐▛███▜▌   Claude Code v2.1.274
    ────────────────────────────────────────
    ❯ 
    ────────────────────────────────────────
      ⏵⏵ bypass permissions on (shift+tab to cycle)
    """

    private static let trustDialog = """
     Do you trust the files in this folder?

     /Volumes/work/app-worktrees/task/fix-login

     ❯ 1. Yes, proceed
       2. No, exit

     Enter to confirm · Esc to cancel
    """

    /// Runs `attempt` synchronously against a scripted sequence of snapshots
    /// (the last one repeats), returning what was sent and how many looks it took.
    private func deliver(
        _ task: String = "brief",
        remaining: Int = 10,
        snapshots: [Snapshot?]
    ) -> (sent: [(pane: String, text: String, agent: AgentType)], lookups: Int) {
        var sent: [(pane: String, text: String, agent: AgentType)] = []
        var lookups = 0
        InitialAgentTaskDelivery.attempt(
            task: task,
            worktreePath: "/wt",
            remaining: remaining,
            retryInterval: 0,
            lookup: { _ in
                defer { lookups += 1 }
                return snapshots[min(lookups, snapshots.count - 1)]
            },
            send: { sent.append(($0, $1, $2)) },
            asyncAfter: { _, work in work() }
        )
        return (sent, lookups)
    }

    func testSendsOnceAgentHasDrawnItsPrompt() {
        let ready = Snapshot(paneId: "pane-1", runningAgent: .claudeCode, screen: Self.claudePrompt)
        let result = deliver("long brief about workspace picker", snapshots: [ready])
        XCTAssertEqual(result.sent.map(\.pane), ["pane-1"])
        XCTAssertEqual(result.sent.map(\.text), ["long brief about workspace picker"])
        XCTAssertEqual(result.sent.map(\.agent), [.claudeCode])
        XCTAssertEqual(result.lookups, InitialAgentTaskDelivery.readyConfirmations)
    }

    func testRetriesUntilPaneAppears() {
        let ready = Snapshot(paneId: "pane-9", runningAgent: .codex, screen: "› Ask Codex to do anything")
        let result = deliver(snapshots: [nil, nil, ready])
        XCTAssertEqual(result.sent.map(\.pane), ["pane-9"])
        XCTAssertEqual(result.sent.map(\.agent), [.codex])
    }

    /// The launch line echoed into the shell names the agent seconds before it
    /// runs. Typing then lost the text and the Return, leaving a bare path.
    func testWaitsWhileAgentIsNotRunningHoweverLong() {
        let booting = Snapshot(paneId: "pane-2", runningAgent: nil,
                               screen: "~ % zsh -lic 'cd /wt && claude --dangerously-skip-permissions'")
        let result = deliver(remaining: 40, snapshots: [booting])
        XCTAssertTrue(result.sent.isEmpty)
        XCTAssertEqual(result.lookups, 41)
    }

    /// Between exec and the agent's first frame the screen is blank — the input
    /// loop is not up yet.
    func testWaitsWhileRunningAgentHasDrawnNothing() {
        let blank = Snapshot(paneId: "pane-3", runningAgent: .claudeCode, screen: "\n   \n\n")
        let unreadable = Snapshot(paneId: "pane-3", runningAgent: .claudeCode, screen: nil)
        let ready = Snapshot(paneId: "pane-3", runningAgent: .claudeCode, screen: Self.claudePrompt)
        let result = deliver(snapshots: [blank, unreadable, blank, ready])
        XCTAssertEqual(result.sent.map(\.pane), ["pane-3"])
        XCTAssertEqual(result.lookups, 3 + InitialAgentTaskDelivery.readyConfirmations)
    }

    /// One ready look is not enough: the process tree can show the agent while
    /// the screen still shows the shell that launched it.
    func testReadinessMustHoldOnConsecutiveLooks() {
        let ready = Snapshot(paneId: "pane-4", runningAgent: .claudeCode, screen: Self.claudePrompt)
        let blank = Snapshot(paneId: "pane-4", runningAgent: .claudeCode, screen: "")
        let result = deliver(snapshots: [ready, blank, ready, ready])
        XCTAssertEqual(result.sent.map(\.pane), ["pane-4"])
        XCTAssertEqual(result.lookups, 4)
    }

    /// The brief's Return would pick "Yes, proceed" and trust the folder for the user.
    func testHoldsWhileADialogIsUpThenSendsOnceItIsAnswered() {
        let dialog = Snapshot(paneId: "pane-5", runningAgent: .claudeCode, screen: Self.trustDialog)
        let ready = Snapshot(paneId: "pane-5", runningAgent: .claudeCode, screen: Self.claudePrompt)
        let result = deliver(snapshots: [dialog, dialog, dialog, ready])
        XCTAssertEqual(result.sent.map(\.pane), ["pane-5"])
        XCTAssertEqual(result.lookups, 3 + InitialAgentTaskDelivery.readyConfirmations)
    }

    func testGivesUpWithoutSendingWhenAttemptsRunOut() {
        let dialog = Snapshot(paneId: "pane-6", runningAgent: .claudeCode, screen: Self.trustDialog)
        let result = deliver(remaining: 5, snapshots: [dialog])
        XCTAssertTrue(result.sent.isEmpty)
        XCTAssertEqual(result.lookups, 6)
    }

    func testEmptyTaskIsIgnoredBySchedule() {
        var sent = 0
        InitialAgentTaskDelivery.schedule(
            task: "   ",
            worktreePath: "/wt",
            expectedAgent: .claudeCode,
            initialDelay: 0,
            lookup: { _ in Snapshot(paneId: "p", runningAgent: .claudeCode, screen: Self.claudePrompt) },
            send: { _, _, _ in sent += 1 },
            asyncAfter: { _, work in work() }
        )
        XCTAssertEqual(sent, 0)
    }
}

final class BareLaunchCommandTests: XCTestCase {
    func testBareLaunchOmitsTaskAndSuggestPromptForAllAIAgents() {
        let agents: [AgentType] = [.claudeCode, .codex, .cursor, .openCode, .gemini, .pi]
        for agent in agents {
            guard let cmd = agent.bareLaunchCommand(agentYolo: false) else {
                XCTFail("\(agent) should launch"); continue
            }
            XCTAssertFalse(cmd.contains("--append-system-prompt"), agent.rawValue)
            XCTAssertFalse(cmd.contains(AgentType.suggestInstruction), agent.rawValue)
            XCTAssertFalse(cmd.contains("'"), "\(agent.rawValue) must stay unquoted for zmx typing: \(cmd)")
        }
    }

    func testBareLaunchKeepsYoloFlags() {
        XCTAssertEqual(
            AgentType.claudeCode.bareLaunchCommand(agentYolo: true),
            "claude --dangerously-skip-permissions")
        XCTAssertEqual(
            AgentType.codex.bareLaunchCommand(agentYolo: true),
            "codex --dangerously-bypass-approvals-and-sandbox")
        XCTAssertEqual(
            AgentType.cursor.bareLaunchCommand(agentYolo: true),
            "agent --yolo")
        XCTAssertEqual(
            AgentType.openCode.bareLaunchCommand(agentYolo: true),
            "opencode --yolo")
    }

    func testWithTaskStillAvailableForDirectExec() {
        let cmd = AgentType.claudeCode.launchCommand(withTask: "hi", agentYolo: false)!
        XCTAssertTrue(cmd.contains("--append-system-prompt"))
        XCTAssertTrue(cmd.contains("'hi'"))
    }
}
