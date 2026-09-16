import XCTest
@testable import seahelm

final class InitialAgentTaskDeliveryTests: XCTestCase {

    func testSendsOncePaneCanDeliverAndAgentIsReady() {
        var sent: [(String, String)] = []
        var lookups = 0
        InitialAgentTaskDelivery.attempt(
            task: "long brief about workspace picker",
            worktreePath: "/wt",
            remaining: 5,
            maxAttempts: 5,
            retryInterval: 0,
            lookup: { _ in
                lookups += 1
                return ("pane-1", true, true)
            },
            send: { sent.append(($0, $1)) },
            asyncAfter: { _, work in work() }
        )
        XCTAssertEqual(sent.map(\.0), ["pane-1"])
        XCTAssertEqual(sent.map(\.1), ["long brief about workspace picker"])
        XCTAssertEqual(lookups, 1)
    }

    func testRetriesUntilPaneAppears() {
        var sent: [(String, String)] = []
        var lookups = 0
        InitialAgentTaskDelivery.attempt(
            task: "do the thing",
            worktreePath: "/wt",
            remaining: 3,
            maxAttempts: 3,
            retryInterval: 0,
            lookup: { _ in
                lookups += 1
                if lookups < 3 { return nil }
                return ("pane-9", true, true)
            },
            send: { sent.append(($0, $1)) },
            asyncAfter: { _, work in work() }
        )
        XCTAssertEqual(sent.map(\.0), ["pane-9"])
        XCTAssertEqual(lookups, 3)
    }

    func testSendsAfterGraceEvenWithoutAgentDetection() {
        var sent: [(String, String)] = []
        var lookups = 0
        InitialAgentTaskDelivery.attempt(
            task: "brief",
            worktreePath: "/wt",
            remaining: InitialAgentTaskDelivery.maxAttempts - InitialAgentTaskDelivery.agentDetectGraceAttempts,
            maxAttempts: InitialAgentTaskDelivery.maxAttempts,
            retryInterval: 0,
            lookup: { _ in
                lookups += 1
                // can deliver, but agent not detected yet
                return ("pane-2", true, false)
            },
            send: { sent.append(($0, $1)) },
            asyncAfter: { _, work in work() }
        )
        XCTAssertEqual(sent.map(\.0), ["pane-2"])
        XCTAssertEqual(lookups, 1)
    }

    func testEmptyTaskIsIgnoredBySchedule() {
        var sent = 0
        InitialAgentTaskDelivery.schedule(
            task: "   ",
            worktreePath: "/wt",
            expectedAgent: .claudeCode,
            initialDelay: 0,
            lookup: { _ in ("p", true, true) },
            send: { _, _ in sent += 1 },
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
