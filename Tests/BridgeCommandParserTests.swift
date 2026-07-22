import XCTest
@testable import seahelm

final class BridgeCommandParserTests: XCTestCase {
    let wts = [
        CabinRef(repo: "alpha", branch: "feat-x", path: "/repo/feat-x"),
        CabinRef(repo: "beta", branch: "fix-y", path: "/repo/fix-y"),
    ]
    let repos = ["/workspaces/alpha", "/workspaces/beta"]
    let agents = [
        // One listing is one worktree's agents, so they share a repo and branch —
        // that is why those head the reply and only the titles vary per row.
        AgentRef(id: "t1", project: "alpha", branch: "feat-x",
                 type: "Claude", title: "Wire up the parser"),
        AgentRef(id: "t2", project: "alpha", branch: "feat-x",
                 type: "Codex", title: "Chase the flaky test"),
    ]

    private func parse(_ text: String) -> Result<BridgeCommand, BridgeCommandError> {
        BridgeCommandParser.parse(text, worktrees: wts, agents: agents, repoPaths: repos)
    }

    // MARK: - Bare prose

    func testNoPrefixIsNewWorktree() {
        XCTAssertEqual(BridgeCommandParser.parse("add dark mode", worktrees: wts),
                       .success(.newWorktree(task: "add dark mode")))
    }

    func testEmptyIsError() {
        XCTAssertEqual(BridgeCommandParser.parse("   ", worktrees: wts), .failure(.emptyTask))
    }

    // MARK: - /task

    func testBareTaskLists() {
        XCTAssertEqual(parse("/task"), .success(.listWorktrees))
    }

    func testTaskWithDescriptionCreates() {
        XCTAssertEqual(parse("/task build login"), .success(.newWorktree(task: "build login")))
    }

    func testTaskWithAtRepoExtractsHint() {
        XCTAssertEqual(parse("/task @alpha build login"),
                       .success(.newWorktree(task: "build login", repoHint: "/workspaces/alpha")))
    }

    func testTaskAtRepoUnknownIgnored() {
        XCTAssertEqual(parse("/task @nope build login"),
                       .success(.newWorktree(task: "build login", repoHint: nil)))
    }

    func testTaskAtRepoCaseInsensitive() {
        XCTAssertEqual(parse("/task @ALPHA x"),
                       .success(.newWorktree(task: "x", repoHint: "/workspaces/alpha")))
    }

    func testTaskHashSelectsByCode() {
        XCTAssertEqual(parse("/task #2"), .success(.selectWorktree(path: "/repo/fix-y")))
    }

    func testTaskHashSelectsByBranch() {
        XCTAssertEqual(parse("/task #feat-x"), .success(.selectWorktree(path: "/repo/feat-x")))
    }

    func testTaskHashIsCaseInsensitive() {
        XCTAssertEqual(parse("/task #FEAT-X"), .success(.selectWorktree(path: "/repo/feat-x")))
    }

    func testTaskHashOutOfRangeFails() {
        XCTAssertEqual(parse("/task #9"), .failure(.unknownTarget("9")))
        XCTAssertEqual(parse("/task #0"), .failure(.unknownTarget("0")))
    }

    func testTaskHashUnknownNameFails() {
        XCTAssertEqual(parse("/task #nope"), .failure(.unknownTarget("nope")))
    }

    /// The `#` is what separates selecting from creating — without it a
    /// description that happens to be a digit must still start work.
    func testTaskWithoutHashIsAlwaysCreate() {
        XCTAssertEqual(parse("/task 2"), .success(.newWorktree(task: "2")))
        XCTAssertEqual(parse("/task feat-x"), .success(.newWorktree(task: "feat-x")))
    }

    func testTaskEmptyDescriptionAfterRepoFails() {
        XCTAssertEqual(BridgeCommandParser.parse("/task @alpha", worktrees: wts, repoPaths: repos),
                       .success(.newWorktree(task: "@alpha", repoHint: "/workspaces/alpha")))
    }

    // MARK: - /agents

    func testBareAgentsLists() {
        XCTAssertEqual(parse("/agents"), .success(.listAgents))
        XCTAssertEqual(parse("/agent"), .success(.listAgents))
    }

    func testAgentsSelectsByCode() {
        XCTAssertEqual(parse("/agents 2"), .success(.selectAgent(id: "t2")))
    }

    /// The `#` is optional here: `/agents` has no create form to disambiguate from.
    func testAgentsAcceptsHashPrefix() {
        XCTAssertEqual(parse("/agents #2"), .success(.selectAgent(id: "t2")))
    }

    func testAgentsSelectsByBranch() {
        XCTAssertEqual(parse("/agents feat-x"), .success(.selectAgent(id: "t1")))
    }

    func testAgentsSelectsByProjectSlashBranch() {
        XCTAssertEqual(parse("/agents alpha/feat-x"), .success(.selectAgent(id: "t1")))
    }

    func testAgentsUnknownFails() {
        XCTAssertEqual(parse("/agents nope"), .failure(.unknownTarget("nope")))
        XCTAssertEqual(parse("/agents 9"), .failure(.unknownTarget("9")))
    }

    // MARK: - /order

    func testOrderResolvesAgentByCode() {
        XCTAssertEqual(parse("/order #1 run tests"),
                       .success(.orderAgent(agentId: "t1", task: "run tests")))
    }

    /// Agents in one listing share a branch, so a name match resolves to the
    /// first — codes (`#2`) are the selector that distinguishes siblings.
    func testOrderResolvesAgentByName() {
        XCTAssertEqual(parse("/order feat-x run tests"),
                       .success(.orderAgent(agentId: "t1", task: "run tests")))
    }

    func testOrderUnknownAgent() {
        XCTAssertEqual(parse("/order #9 do it"), .failure(.unknownTarget("9")))
    }

    func testOrderMissingTask() {
        XCTAssertEqual(parse("/order #1"), .failure(.emptyTask))
    }

    func testOrderMissingEverything() {
        XCTAssertEqual(parse("/order"), .failure(.missingArgument("order")))
    }

    // MARK: - Retired verbs

    func testRetiredVerbsAreUnknown() {
        XCTAssertEqual(parse("/new build login"), .failure(.unknownCommand("new")))
        XCTAssertEqual(parse("/remove @feat-x"), .failure(.unknownCommand("remove")))
        XCTAssertEqual(parse("/commit @feat-x"), .failure(.unknownCommand("commit")))
        XCTAssertEqual(parse("/send alpha do it"), .failure(.unknownCommand("send")))
        XCTAssertEqual(parse("/list"), .failure(.unknownCommand("list")))
        XCTAssertEqual(parse("/worktrees"), .failure(.unknownCommand("worktrees")))
    }

    // MARK: - /broadcast, /add

    func testBroadcast() {
        XCTAssertEqual(parse("/broadcast ship it"), .success(.broadcast(task: "ship it")))
    }

    func testBroadcastEmpty() {
        XCTAssertEqual(parse("/broadcast"), .failure(.emptyTask))
    }

    func testAdd() {
        XCTAssertEqual(parse("/add"), .success(.addRepo))
    }

    // MARK: - /flag

    func testFlagWithDescription() {
        XCTAssertEqual(parse("/flag dark mode is broken"),
                       .success(.flagIssue(title: "dark mode is broken")))
    }

    func testFlagEmptyFails() {
        XCTAssertEqual(parse("/flag"), .failure(.emptyTask))
    }

    func testUnknownCommand() {
        XCTAssertEqual(parse("/frobnicate"), .failure(.unknownCommand("frobnicate")))
    }

    // MARK: - /return (was /remove)

    func testBareReturnSweeps() {
        XCTAssertEqual(parse("/return"), .success(.removeAll))
    }

    func testReturnRepoNameDropsRepo() {
        XCTAssertEqual(parse("/return @alpha"), .success(.removeRepo(repoPath: "/workspaces/alpha")))
    }

    func testReturnBranchNameDeletesWorktree() {
        XCTAssertEqual(parse("/return @feat-x"), .success(.removeWorktree(worktreePath: "/repo/feat-x")))
    }

    func testReturnAcceptsBareName() {
        XCTAssertEqual(parse("/return feat-x"), .success(.removeWorktree(worktreePath: "/repo/feat-x")))
    }

    func testReturnIsCaseInsensitive() {
        XCTAssertEqual(parse("/return @FEAT-X"), .success(.removeWorktree(worktreePath: "/repo/feat-x")))
        XCTAssertEqual(parse("/return @Alpha"), .success(.removeRepo(repoPath: "/workspaces/alpha")))
    }

    /// Dropping a repo leaves the worktree on disk, so it is the recoverable guess.
    func testReturnPrefersRepoOnNameCollision() {
        let collidingWts = [CabinRef(repo: "alpha", branch: "alpha", path: "/repo/alpha")]
        XCTAssertEqual(
            BridgeCommandParser.parse("/return @alpha", worktrees: collidingWts, repoPaths: repos),
            .success(.removeRepo(repoPath: "/workspaces/alpha")))
    }

    func testReturnUnknownTargetFails() {
        XCTAssertEqual(parse("/return @nope"), .failure(.unknownTarget("nope")))
    }

    // MARK: - Verb casing

    func testVerbIsCaseInsensitive() {
        XCTAssertEqual(parse("/TASK"), .success(.listWorktrees))
        XCTAssertEqual(parse("/Return"), .success(.removeAll))
    }

    // MARK: - Formatter ↔ parser agreement

    /// The codes a listing prints must be the codes the parser accepts back.
    func testListedCodesRoundTrip() {
        let taskList = BridgeCommandFormatter.worktreeList(wts, currentPath: nil)
        for (index, wt) in wts.enumerated() {
            XCTAssertTrue(taskList.contains("\(index + 1). \(wt.repo) / \(wt.branch)"))
            XCTAssertEqual(parse("/task #\(index + 1)"), .success(.selectWorktree(path: wt.path)))
        }

        let agentList = BridgeCommandFormatter.agentList(agents, currentId: nil)
        for (index, agent) in agents.enumerated() {
            XCTAssertTrue(agentList.contains("\(index + 1). \(agent.type) — \(agent.title)"))
            XCTAssertEqual(parse("/agents \(index + 1)"), .success(.selectAgent(id: agent.id)))
        }
    }

    func testFormatterMarksCurrent() {
        XCTAssertTrue(BridgeCommandFormatter.worktreeList(wts, currentPath: "/repo/fix-y")
            .contains("2. beta / fix-y  ← current"))
        XCTAssertTrue(BridgeCommandFormatter.agentList(agents, currentId: "t1")
            .contains("1. Claude — Wire up the parser  ← current"))
    }

    /// Repo and branch head the reply instead of repeating on every row, since a
    /// listing only ever covers one worktree's agents.
    func testAgentListHeadsWithRepoAndBranch() {
        let list = BridgeCommandFormatter.agentList(agents, currentId: nil)
        XCTAssertTrue(list.contains("**Agents** - alpha - feat-x"), list)
        XCTAssertFalse(list.contains("1. alpha / feat-x"), "repo/branch should not repeat per row: \(list)")
    }

    func testFormatterEmptyStates() {
        XCTAssertEqual(BridgeCommandFormatter.agentList([], currentId: nil), "No agents in this task.")
        XCTAssertTrue(BridgeCommandFormatter.worktreeList([], currentPath: nil).contains("No tasks"))
    }
}
