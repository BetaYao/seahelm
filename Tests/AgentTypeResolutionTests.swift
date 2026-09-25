import XCTest
@testable import seahelm

/// A pane's agent type is what tells a remote client whether its input reaches
/// an agent or a bare shell, so an agent that exited must not stay on the label.
final class AgentTypeResolutionTests: XCTestCase {
    private let seesClaude: (AgentType) -> Bool = { $0 == .claudeCode || $0 == .codex }

    private func resolve(probed: AgentType = .unknown,
                         noAgent: StatusPublisher.NoAgentSighting = .none,
                         screen: AgentType = .unknown,
                         existing: AgentType) -> AgentType {
        StatusPublisher.resolveAgentType(probed: probed, noAgent: noAgent, screen: screen,
                                         existing: existing, probeCanSee: seesClaude)
    }

    func testProbedAgentWins() {
        XCTAssertEqual(resolve(probed: .codex, screen: .claudeCode, existing: .unknown), .codex)
    }

    func testAMissKeepsTheKnownAgent() {
        XCTAssertEqual(resolve(existing: .claudeCode), .claudeCode)
    }

    func testAFreshProbeWithNoAgentTakesTheAgentAway() {
        XCTAssertEqual(resolve(noAgent: .fresh, existing: .claudeCode), .shellCommand)
    }

    func testScrollbackNamingTheAgentDoesNotBringItBack() {
        XCTAssertEqual(resolve(noAgent: .fresh, screen: .claudeCode, existing: .claudeCode), .shellCommand)
        XCTAssertEqual(resolve(noAgent: .cached, screen: .claudeCode, existing: .shellCommand), .shellCommand)
    }

    /// A hook reported the agent starting after the last probe: the remembered
    /// sighting is older than that, so it must not undo it.
    func testACachedSightingDoesNotOverruleAnAgentSinceReported() {
        XCTAssertEqual(resolve(noAgent: .cached, existing: .claudeCode), .claudeCode)
    }

    /// The probe cannot recognize this agent, so not finding it proves nothing.
    func testAnAgentTheProbeCannotSeeIsKept() {
        XCTAssertEqual(resolve(noAgent: .fresh, existing: .aider), .aider)
        XCTAssertEqual(resolve(noAgent: .fresh, screen: .aider, existing: .unknown), .aider)
    }

    func testAShellJobIsLeftAlone() {
        XCTAssertEqual(resolve(noAgent: .fresh, existing: .npm), .npm)
    }
}

final class HostGatewayPaneNotifyTests: XCTestCase {
    private func updated(_ id: String, _ type: String) -> [String: Any] {
        ["type": "pane.updated", "pane_id": id, "agent_type": type, "status": "Idle"]
    }

    func testUpdateWithUnchangedAgentTypeIsDropped() {
        var sent = ["p1": "claudeCode"]
        XCTAssertNil(HostGatewaySession.paneNotify(for: updated("p1", "claudeCode"), sentAgentTypes: &sent))
    }

    /// An agent exiting at rest changes no status, so this is the only word of it.
    func testUpdateThatChangesAgentTypeIsSentAsStatus() {
        var sent = ["p1": "claudeCode"]
        let note = HostGatewaySession.paneNotify(for: updated("p1", "shellCommand"), sentAgentTypes: &sent)
        XCTAssertEqual(note?.method, "pane.status")
        XCTAssertEqual(note?.params["agent_type"] as? String, "shellCommand")
        XCTAssertEqual(sent["p1"], "shellCommand")
        XCTAssertNil(HostGatewaySession.paneNotify(for: updated("p1", "shellCommand"), sentAgentTypes: &sent))
    }

    func testStatusChangeRecordsTheTypeItCarried() {
        var sent: [String: String] = [:]
        let event: [String: Any] = ["type": "pane.status_changed", "pane_id": "p1",
                                    "agent_type": "codex", "status": "Running"]
        XCTAssertNotNil(HostGatewaySession.paneNotify(for: event, sentAgentTypes: &sent))
        XCTAssertNil(HostGatewaySession.paneNotify(for: updated("p1", "codex"), sentAgentTypes: &sent))
    }

    func testSnapshotSeedsTheSentTypes() {
        let panes: [[String: Any]] = [["pane_id": "p1", "agent_type": "claudeCode"],
                                      ["pane_id": "p2", "agent_type": "unknown"]]
        XCTAssertEqual(HostGatewaySession.agentTypes(inSnapshotPanes: panes),
                       ["p1": "claudeCode", "p2": "unknown"])
    }
}
