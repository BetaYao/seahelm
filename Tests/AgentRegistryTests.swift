import XCTest
@testable import seahelm

/// Tests for Fleet singleton.
/// Note: We avoid creating Station instances in tests because they
/// require Ghostty/Metal initialization. Instead we test the data management
/// logic by registering agents and verifying queries.
final class FleetTests: XCTestCase {

    /// Helper: register a test agent without a real surface.
    /// Returns the terminal ID (surface.id) for use in subsequent calls.
    @discardableResult
    private func registerTestPane(
        path: String, branch: String = "main", project: String = "TestProject",
        startedAt: Date? = nil
    ) -> String {
        let surface = Station()
        Fleet.shared.register(
            station: surface, worktreePath: path, branch: branch, project: project,
            startedAt: startedAt
        )
        return surface.id
    }

    override func setUp() {
        super.setUp()
        // Clear shared state between tests
        for agent in Fleet.shared.allPanes() {
            Fleet.shared.unregister(terminalID: agent.id)
        }
    }

    override func tearDown() {
        for agent in Fleet.shared.allPanes() {
            Fleet.shared.unregister(terminalID: agent.id)
        }
        super.tearDown()
    }

    // MARK: - Registration

    func testRegisterAndQuery() {
        let tid = registerTestPane(path: "/tmp/repo/main", project: "MyProject")

        let agents = Fleet.shared.allPanes()
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].id, tid)
        XCTAssertEqual(agents[0].worktreePath, "/tmp/repo/main")
        XCTAssertEqual(agents[0].branch, "main")
        XCTAssertEqual(agents[0].project, "MyProject")
        XCTAssertEqual(agents[0].agentType, .unknown)
        XCTAssertEqual(agents[0].status, .unknown)
    }

    func testUnregister() {
        let tid = registerTestPane(path: "/tmp/repo/main")
        Fleet.shared.unregister(terminalID: tid)

        XCTAssertEqual(Fleet.shared.allPanes().count, 0)
        XCTAssertNil(Fleet.shared.pane(for: tid))
        XCTAssertNil(Fleet.shared.pane(forWorktree: "/tmp/repo/main"))
    }

    func testUnregisterCleansUpBackendsByPath() {
        let surface = Station()
        Fleet.shared.register(
            station: surface, worktreePath: "/tmp/test-repo/main",
            branch: "main", project: "test", startedAt: nil,
            paneSessionKey: "seahelm-test-main", backend: "seahelmd"
        )

        Fleet.shared.unregister(terminalID: surface.id)

        XCTAssertNil(Fleet.shared.pane(for: surface.id))
        XCTAssertNil(Fleet.shared.pane(forWorktree: "/tmp/test-repo/main"))
    }

    // MARK: - Status Updates



    // MARK: - Detection Updates (type upgrade rules)








    // MARK: - Worktree Lookup

    func testAgentForWorktree() {
        let tid = registerTestPane(path: "/tmp/repo/main")

        let agent = Fleet.shared.pane(forWorktree: "/tmp/repo/main")
        XCTAssertNotNil(agent)
        XCTAssertEqual(agent?.id, tid)
        XCTAssertEqual(agent?.worktreePath, "/tmp/repo/main")
    }

    func testAgentForWorktreeReturnsNilForUnknown() {
        XCTAssertNil(Fleet.shared.pane(forWorktree: "/nonexistent"))
    }



    // MARK: - Ordering

    func testAllAgentsPreservesInsertionOrder() {
        let tidA = registerTestPane(path: "/a", branch: "a")
        let tidB = registerTestPane(path: "/b", branch: "b")
        let tidC = registerTestPane(path: "/c", branch: "c")

        let ids = Fleet.shared.allPanes().map { $0.id }
        XCTAssertEqual(ids, [tidA, tidB, tidC])
    }

    func testReorderWithWorktreePaths() {
        registerTestPane(path: "/a", branch: "a")
        registerTestPane(path: "/b", branch: "b")
        registerTestPane(path: "/c", branch: "c")

        // reorder accepts worktree paths
        Fleet.shared.reorder(paths: ["/c", "/a", "/b"])

        let worktreePaths = Fleet.shared.allPanes().map { $0.worktreePath }
        XCTAssertEqual(worktreePaths, ["/c", "/a", "/b"])
    }

    // MARK: - Project Filtering

    func testAgentsForProject() {
        registerTestPane(path: "/repo1/main", branch: "main", project: "Repo1")
        registerTestPane(path: "/repo2/main", branch: "main", project: "Repo2")
        registerTestPane(path: "/repo1/feature", branch: "feature", project: "Repo1")

        let repo1Agents = Fleet.shared.panesForProject("Repo1")
        XCTAssertEqual(repo1Agents.count, 2)
        XCTAssertTrue(repo1Agents.allSatisfy { $0.project == "Repo1" })
    }

    // MARK: - Total Duration

    func testTotalDurationComputedFromStartedAt() {
        let fiveMinutesAgo = Date().addingTimeInterval(-300)
        let tid = registerTestPane(path: "/tmp/repo/main", startedAt: fiveMinutesAgo)

        let agent = Fleet.shared.pane(for: tid)!
        XCTAssertGreaterThan(agent.totalDuration, 299)
        XCTAssertLessThan(agent.totalDuration, 302)
    }

    func testTotalDurationZeroWhenNoStartedAt() {
        let tid = registerTestPane(path: "/tmp/repo/main", startedAt: nil)

        let agent = Fleet.shared.pane(for: tid)!
        XCTAssertEqual(agent.totalDuration, 0)
    }

    // MARK: - 1:N Worktree Index



}
