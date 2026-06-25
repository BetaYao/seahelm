import XCTest
@testable import seahelm

/// Tests for ShipLog singleton.
/// Note: We avoid creating Station instances in tests because they
/// require Ghostty/Metal initialization. Instead we test the data management
/// logic by registering agents and verifying queries.
final class ShipLogTests: XCTestCase {

    /// Helper: register a test agent without a real surface.
    /// Returns the terminal ID (surface.id) for use in subsequent calls.
    @discardableResult
    private func registerTestSailor(
        path: String, branch: String = "main", project: String = "TestProject",
        startedAt: Date? = nil
    ) -> String {
        let surface = Station()
        ShipLog.shared.register(
            station: surface, worktreePath: path, branch: branch, project: project,
            startedAt: startedAt
        )
        return surface.id
    }

    override func setUp() {
        super.setUp()
        // Clear shared state between tests
        for agent in ShipLog.shared.allSailors() {
            ShipLog.shared.unregister(terminalID: agent.id)
        }
    }

    override func tearDown() {
        for agent in ShipLog.shared.allSailors() {
            ShipLog.shared.unregister(terminalID: agent.id)
        }
        super.tearDown()
    }

    // MARK: - Registration

    func testRegisterAndQuery() {
        let tid = registerTestSailor(path: "/tmp/repo/main", project: "MyProject")

        let agents = ShipLog.shared.allSailors()
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].id, tid)
        XCTAssertEqual(agents[0].worktreePath, "/tmp/repo/main")
        XCTAssertEqual(agents[0].branch, "main")
        XCTAssertEqual(agents[0].project, "MyProject")
        XCTAssertEqual(agents[0].agentType, .unknown)
        XCTAssertEqual(agents[0].status, .unknown)
    }

    func testUnregister() {
        let tid = registerTestSailor(path: "/tmp/repo/main")
        ShipLog.shared.unregister(terminalID: tid)

        XCTAssertEqual(ShipLog.shared.allSailors().count, 0)
        XCTAssertNil(ShipLog.shared.agent(for: tid))
        XCTAssertNil(ShipLog.shared.agent(forWorktree: "/tmp/repo/main"))
    }

    func testUnregisterCleansUpBackendsByPath() {
        let surface = Station()
        ShipLog.shared.register(
            station: surface, worktreePath: "/tmp/test-repo/main",
            branch: "main", project: "test", startedAt: nil,
            tmuxSessionName: "amux-test-main", backend: "zmx"
        )

        ShipLog.shared.unregister(terminalID: surface.id)

        XCTAssertNil(ShipLog.shared.agent(for: surface.id))
        XCTAssertNil(ShipLog.shared.agent(forWorktree: "/tmp/test-repo/main"))
    }

    // MARK: - Status Updates

    func testUpdateStatus() {
        let tid = registerTestSailor(path: "/tmp/repo/main")

        ShipLog.shared.updateStatus(
            terminalID: tid,
            status: .running,
            lastMessage: "Editing file.swift",
            roundDuration: 30.0
        )

        let agent = ShipLog.shared.agent(for: tid)
        XCTAssertEqual(agent?.status, .running)
        XCTAssertEqual(agent?.lastMessage, "Editing file.swift")
        XCTAssertEqual(agent?.roundDuration, 30.0)
    }

    func testUpdateStatusForUnknownID() {
        // Should not crash when updating non-existent terminal ID
        ShipLog.shared.updateStatus(
            terminalID: "nonexistent-id",
            status: .running,
            lastMessage: "test",
            roundDuration: 0
        )
        XCTAssertNil(ShipLog.shared.agent(for: "nonexistent-id"))
    }

    // MARK: - Detection Updates (type upgrade rules)

    func testUpdateDetectionFromUnknown() {
        let tid = registerTestSailor(path: "/tmp/repo/main")

        ShipLog.shared.updateDetection(terminalID: tid, commandLine: nil, agentType: .claudeCode)

        let agent = ShipLog.shared.agent(for: tid)
        XCTAssertEqual(agent?.agentType, .claudeCode)
    }

    func testUpdateDetectionAIAgentCannotDemoteToShellTask() {
        let tid = registerTestSailor(path: "/tmp/repo/main")

        // Set to AI agent first
        ShipLog.shared.updateDetection(terminalID: tid, commandLine: nil, agentType: .claudeCode)
        // Attempt to demote to shell task — should be blocked
        ShipLog.shared.updateDetection(terminalID: tid, commandLine: nil, agentType: .brew)

        let agent = ShipLog.shared.agent(for: tid)
        XCTAssertEqual(agent?.agentType, .claudeCode)
    }

    func testUpdateDetectionAIAgentCanUpgradeToAnotherAIAgent() {
        let tid = registerTestSailor(path: "/tmp/repo/main")

        ShipLog.shared.updateDetection(terminalID: tid, commandLine: nil, agentType: .codex)
        // Another AI agent should be allowed
        ShipLog.shared.updateDetection(terminalID: tid, commandLine: nil, agentType: .claudeCode)

        let agent = ShipLog.shared.agent(for: tid)
        XCTAssertEqual(agent?.agentType, .claudeCode)
    }

    func testUpdateDetectionShellTaskCanBeReplaced() {
        let tid = registerTestSailor(path: "/tmp/repo/main")

        ShipLog.shared.updateDetection(terminalID: tid, commandLine: nil, agentType: .brew)
        // Shell task can be replaced by any type
        ShipLog.shared.updateDetection(terminalID: tid, commandLine: nil, agentType: .claudeCode)

        let agent = ShipLog.shared.agent(for: tid)
        XCTAssertEqual(agent?.agentType, .claudeCode)
    }

    func testUpdateDetectionShellTaskCanBeReplacedByShellTask() {
        let tid = registerTestSailor(path: "/tmp/repo/main")

        ShipLog.shared.updateDetection(terminalID: tid, commandLine: nil, agentType: .brew)
        ShipLog.shared.updateDetection(terminalID: tid, commandLine: nil, agentType: .make)

        let agent = ShipLog.shared.agent(for: tid)
        XCTAssertEqual(agent?.agentType, .make)
    }

    func testUpdateDetectionIgnoresUnknownType() {
        let tid = registerTestSailor(path: "/tmp/repo/main")

        ShipLog.shared.updateDetection(terminalID: tid, commandLine: nil, agentType: .unknown)

        let agent = ShipLog.shared.agent(for: tid)
        XCTAssertEqual(agent?.agentType, .unknown)
    }

    func testUpdateDetectionSetsCommandLine() {
        let tid = registerTestSailor(path: "/tmp/repo/main")

        ShipLog.shared.updateDetection(terminalID: tid, commandLine: "brew install ffmpeg", agentType: .brew)

        let agent = ShipLog.shared.agent(for: tid)
        XCTAssertEqual(agent?.commandLine, "brew install ffmpeg")
        XCTAssertEqual(agent?.agentType, .brew)
    }

    // MARK: - Worktree Lookup

    func testAgentForWorktree() {
        let tid = registerTestSailor(path: "/tmp/repo/main")

        let agent = ShipLog.shared.agent(forWorktree: "/tmp/repo/main")
        XCTAssertNotNil(agent)
        XCTAssertEqual(agent?.id, tid)
        XCTAssertEqual(agent?.worktreePath, "/tmp/repo/main")
    }

    func testAgentForWorktreeReturnsNilForUnknown() {
        XCTAssertNil(ShipLog.shared.agent(forWorktree: "/nonexistent"))
    }

    // MARK: - Ordering

    func testAllAgentsPreservesInsertionOrder() {
        let tidA = registerTestSailor(path: "/a", branch: "a")
        let tidB = registerTestSailor(path: "/b", branch: "b")
        let tidC = registerTestSailor(path: "/c", branch: "c")

        let ids = ShipLog.shared.allSailors().map { $0.id }
        XCTAssertEqual(ids, [tidA, tidB, tidC])
    }

    func testReorderWithWorktreePaths() {
        registerTestSailor(path: "/a", branch: "a")
        registerTestSailor(path: "/b", branch: "b")
        registerTestSailor(path: "/c", branch: "c")

        // reorder accepts worktree paths
        ShipLog.shared.reorder(paths: ["/c", "/a", "/b"])

        let worktreePaths = ShipLog.shared.allSailors().map { $0.worktreePath }
        XCTAssertEqual(worktreePaths, ["/c", "/a", "/b"])
    }

    // MARK: - Project Filtering

    func testAgentsForProject() {
        registerTestSailor(path: "/repo1/main", branch: "main", project: "Repo1")
        registerTestSailor(path: "/repo2/main", branch: "main", project: "Repo2")
        registerTestSailor(path: "/repo1/feature", branch: "feature", project: "Repo1")

        let repo1Agents = ShipLog.shared.agentsForProject("Repo1")
        XCTAssertEqual(repo1Agents.count, 2)
        XCTAssertTrue(repo1Agents.allSatisfy { $0.project == "Repo1" })
    }

    // MARK: - Total Duration

    func testTotalDurationComputedFromStartedAt() {
        let fiveMinutesAgo = Date().addingTimeInterval(-300)
        let tid = registerTestSailor(path: "/tmp/repo/main", startedAt: fiveMinutesAgo)

        let agent = ShipLog.shared.agent(for: tid)!
        XCTAssertGreaterThan(agent.totalDuration, 299)
        XCTAssertLessThan(agent.totalDuration, 302)
    }

    func testTotalDurationZeroWhenNoStartedAt() {
        let tid = registerTestSailor(path: "/tmp/repo/main", startedAt: nil)

        let agent = ShipLog.shared.agent(for: tid)!
        XCTAssertEqual(agent.totalDuration, 0)
    }

    // MARK: - 1:N Worktree Index

    func testWorktreeIndexStoresMultipleTerminals() {
        let head = ShipLog.shared
        head.registerTerminalID("test-t1", forWorktree: "/test/repo/main")
        head.registerTerminalID("test-t2", forWorktree: "/test/repo/main")

        let ids = head.terminalIDs(forWorktree: "/test/repo/main")
        XCTAssertEqual(ids, ["test-t1", "test-t2"])

        // Cleanup
        head.unregisterTerminalID("test-t1", forWorktree: "/test/repo/main")
        head.unregisterTerminalID("test-t2", forWorktree: "/test/repo/main")
    }

    func testUnregisterRemovesFromWorktreeIndex() {
        let head = ShipLog.shared
        head.registerTerminalID("test-t1", forWorktree: "/test/repo/main")
        head.registerTerminalID("test-t2", forWorktree: "/test/repo/main")
        head.unregisterTerminalID("test-t1", forWorktree: "/test/repo/main")

        let ids = head.terminalIDs(forWorktree: "/test/repo/main")
        XCTAssertEqual(ids, ["test-t2"])

        // Cleanup
        head.unregisterTerminalID("test-t2", forWorktree: "/test/repo/main")
    }

    func testUnregisterLastTerminalRemovesWorktreeEntry() {
        let head = ShipLog.shared
        head.registerTerminalID("test-t1", forWorktree: "/test/repo/main")
        head.unregisterTerminalID("test-t1", forWorktree: "/test/repo/main")

        let ids = head.terminalIDs(forWorktree: "/test/repo/main")
        XCTAssertEqual(ids, [])
    }
}
