import XCTest
@testable import seahelm

final class ChatSelectionCommandTests: XCTestCase {
    private let worktrees = [
        WorktreeRef(branch: "main", path: "/repo/main"),
        WorktreeRef(branch: "fix/login", path: "/repo/fix-login"),
        WorktreeRef(branch: "spike", path: "/other/spike"),
    ]

    private let agents = [
        AgentRef(id: "t1", project: "seahelm", branch: "main", status: "Running"),
        AgentRef(id: "t2", project: "seahelm", branch: "fix/login", status: "Idle"),
        AgentRef(id: "t3", project: "other", branch: "spike", status: "Waiting"),
    ]

    private func parse(_ text: String) -> Result<ChatSelectionCommand, BridgeCommandError>? {
        ChatSelectionParser.parse(text, worktrees: worktrees, agents: agents)
    }

    // MARK: - Verb ownership

    func testReturnsNilForForeignVerbs() {
        XCTAssertNil(parse("/new do a thing"))
        XCTAssertNil(parse("/commit @main"))
        XCTAssertNil(parse("/status"))
        XCTAssertNil(parse("/list"))  // renamed to /agents — must fall through to "unknown"
    }

    func testReturnsNilForBareProse() {
        XCTAssertNil(parse("just a message"))
        XCTAssertNil(parse("2"))  // a bare digit stays a prompt, not a selection
    }

    // MARK: - Listing

    func testBareVerbsList() {
        XCTAssertEqual(try? parse("/repo")?.get(), .listRepos)
        XCTAssertEqual(try? parse("/worktrees")?.get(), .listWorktrees)
        XCTAssertEqual(try? parse("/agents")?.get(), .listAgents)
    }

    func testSingularAndPluralBothWork() {
        XCTAssertEqual(try? parse("/repos")?.get(), .listRepos)
        XCTAssertEqual(try? parse("/worktree")?.get(), .listWorktrees)
        XCTAssertEqual(try? parse("/agent")?.get(), .listAgents)
    }

    func testVerbIsCaseInsensitive() {
        XCTAssertEqual(try? parse("/Agents")?.get(), .listAgents)
        XCTAssertEqual(try? parse("/WORKTREES")?.get(), .listWorktrees)
    }

    func testRepoTakesNoArgument() {
        // Listing only — an argument is ignored rather than erroring.
        XCTAssertEqual(try? parse("/repo 2")?.get(), .listRepos)
    }

    // MARK: - Selecting by code

    func testSelectWorktreeByCode() {
        XCTAssertEqual(try? parse("/worktrees 2")?.get(), .selectWorktree(path: "/repo/fix-login"))
    }

    func testSelectAgentByCode() {
        XCTAssertEqual(try? parse("/agents 3")?.get(), .selectAgent(id: "t3"))
    }

    func testCodeIsOneBased() {
        XCTAssertEqual(try? parse("/agents 1")?.get(), .selectAgent(id: "t1"))
    }

    func testOutOfRangeCodeIsUnknownTarget() {
        XCTAssertEqual(parse("/agents 0")?.failureError, .unknownTarget("0"))
        XCTAssertEqual(parse("/agents 4")?.failureError, .unknownTarget("4"))
        XCTAssertEqual(parse("/worktrees 99")?.failureError, .unknownTarget("99"))
    }

    // MARK: - Selecting by name

    func testSelectWorktreeByBranch() {
        XCTAssertEqual(try? parse("/worktrees fix/login")?.get(),
                       .selectWorktree(path: "/repo/fix-login"))
    }

    func testSelectAgentByBranch() {
        XCTAssertEqual(try? parse("/agents spike")?.get(), .selectAgent(id: "t3"))
    }

    func testSelectAgentByProjectSlashBranch() {
        XCTAssertEqual(try? parse("/agents seahelm/fix/login")?.get(), .selectAgent(id: "t2"))
    }

    func testSelectAgentByProjectPicksFirstMatch() {
        XCTAssertEqual(try? parse("/agents seahelm")?.get(), .selectAgent(id: "t1"))
    }

    func testNameIsCaseInsensitive() {
        XCTAssertEqual(try? parse("/worktrees MAIN")?.get(), .selectWorktree(path: "/repo/main"))
    }

    func testLeadingAtIsAccepted() {
        XCTAssertEqual(try? parse("/worktrees @spike")?.get(), .selectWorktree(path: "/other/spike"))
        XCTAssertEqual(try? parse("/agents @spike")?.get(), .selectAgent(id: "t3"))
    }

    func testUnknownNameIsUnknownTarget() {
        XCTAssertEqual(parse("/worktrees nope")?.failureError, .unknownTarget("nope"))
        XCTAssertEqual(parse("/agents nope")?.failureError, .unknownTarget("nope"))
    }

    func testSelectingFromAnEmptyFleetFails() {
        let result = ChatSelectionParser.parse("/agents 1", worktrees: [], agents: [])
        XCTAssertEqual(result?.failureError, .unknownTarget("1"))
    }

    // MARK: - Formatter

    func testRepoListIsNumbered() {
        let out = ChatSelectionFormatter.repoList(["/Users/x/seahelm", "/Users/x/other"])
        XCTAssertEqual(out, """
        **Repos**

        1. seahelm
        2. other
        """)
    }

    func testEmptyRepoList() {
        XCTAssertEqual(ChatSelectionFormatter.repoList([]),
                       "No repos configured. Use `/add` on the desktop.")
    }

    func testWorktreeListMarksCurrent() {
        let out = ChatSelectionFormatter.worktreeList(worktrees, currentPath: "/repo/fix-login")
        XCTAssertTrue(out.contains("1. main\n"))
        XCTAssertTrue(out.contains("2. fix/login  ← current"))
        XCTAssertFalse(out.contains("3. spike  ← current"))
    }

    func testWorktreeListWithNoCurrent() {
        let out = ChatSelectionFormatter.worktreeList(worktrees, currentPath: nil)
        XCTAssertFalse(out.contains("← current"))
    }

    func testAgentListMarksCurrentAndShowsStatus() {
        let out = ChatSelectionFormatter.agentList(agents, currentId: "t1")
        XCTAssertTrue(out.contains("1. seahelm / main — Running  ← current"))
        XCTAssertTrue(out.contains("2. seahelm / fix/login — Idle"))
        XCTAssertFalse(out.contains("Idle  ← current"))
    }

    func testEmptyAgentList() {
        XCTAssertEqual(ChatSelectionFormatter.agentList([], currentId: nil), "No agents registered.")
    }

    /// The codes a listing prints must be the codes the parser accepts back.
    func testListedCodesRoundTripThroughTheParser() {
        for (index, agent) in agents.enumerated() {
            let code = index + 1
            XCTAssertTrue(ChatSelectionFormatter.agentList(agents, currentId: nil)
                .contains("\(code). \(agent.project) / \(agent.branch)"))
            XCTAssertEqual(try? parse("/agents \(code)")?.get(), .selectAgent(id: agent.id))
        }
        for (index, wt) in worktrees.enumerated() {
            let code = index + 1
            XCTAssertTrue(ChatSelectionFormatter.worktreeList(worktrees, currentPath: nil)
                .contains("\(code). \(wt.branch)"))
            XCTAssertEqual(try? parse("/worktrees \(code)")?.get(), .selectWorktree(path: wt.path))
        }
    }
}

private extension Result where Failure == BridgeCommandError {
    var failureError: BridgeCommandError? {
        if case .failure(let err) = self { return err }
        return nil
    }
}
