import XCTest
@testable import seahelm

final class BridgeCommandRouterTests: XCTestCase {
    func makeRouter(queue: PendingOrdersQueue,
                    created: @escaping (String, String?) -> Void = { _, _ in },
                    selectWorktree: @escaping (String) -> Void = { _ in },
                    selectAgent: @escaping (String) -> Void = { _ in },
                    showOverview: @escaping () -> Void = {},
                    ordered: @escaping (String, String) -> Void = { _, _ in },
                    removeAll: @escaping () -> Void = {},
                    addRepo: @escaping () -> Void = {},
                    removeRepo: @escaping (String) -> Void = { _ in },
                    removeWorktree: @escaping (String) -> Void = { _ in },
                    flagIssue: @escaping (String) -> Void = { _ in },
                    agentCount: @escaping () -> Int = { 0 }) -> BridgeCommandRouter {
        BridgeCommandRouter(queue: queue, createWorktree: created,
                            selectWorktree: selectWorktree, selectAgent: selectAgent,
                            showOverview: showOverview, orderAgent: ordered,
                            removeAll: removeAll, addRepo: addRepo, removeRepo: removeRepo,
                            removeWorktree: removeWorktree,
                            flagIssue: flagIssue,
                            activeSailorCount: agentCount,
                            branchForPath: { _ in "feat-x" }, projectForPath: { _ in "repo" })
    }

    func testRemoveRepoCallsClosureNotQueue() {
        let q = PendingOrdersQueue()
        var removed: String?
        makeRouter(queue: q, removeRepo: { removed = $0 })
            .route(.removeRepo(repoPath: "/workspaces/alpha"))
        XCTAssertEqual(removed, "/workspaces/alpha")
        // Closing a repo is a confirm-then-act flow owned by the host, not a card.
        XCTAssertTrue(q.all().isEmpty)
    }

    /// The two verbs must not cross-fire: one drops a repo (worktrees survive),
    /// the other deletes a worktree from disk.
    func testRemoveWorktreeRoutesToItsOwnClosure() {
        let q = PendingOrdersQueue()
        var deleted: String?
        var droppedRepo: String?
        makeRouter(queue: q, removeRepo: { droppedRepo = $0 }, removeWorktree: { deleted = $0 })
            .route(.removeWorktree(worktreePath: "/repo/feat-x"))
        XCTAssertEqual(deleted, "/repo/feat-x")
        XCTAssertNil(droppedRepo)
        XCTAssertTrue(q.all().isEmpty)
    }

    func testNewWorktreeCallsClosureNotQueue() {
        let q = PendingOrdersQueue()
        var got: (String, String?)?
        makeRouter(queue: q, created: { got = ($0, $1) }).route(.newWorktree(task: "do it"))
        XCTAssertEqual(got?.0, "do it")
        XCTAssertNil(got?.1)
        XCTAssertTrue(q.all().isEmpty)
    }

    func testNewWorktreeWithRepoHintPassesHint() {
        let q = PendingOrdersQueue()
        var got: (String, String?)?
        makeRouter(queue: q, created: { got = ($0, $1) }).route(.newWorktree(task: "fix it", repoHint: "/repos/alpha"))
        XCTAssertEqual(got?.0, "fix it")
        XCTAssertEqual(got?.1, "/repos/alpha")
    }

    func testOrderCallsClosureWithAgentId() {
        let q = PendingOrdersQueue()
        var got: (String, String)?
        makeRouter(queue: q, ordered: { got = ($0, $1) }).route(.orderAgent(agentId: "t1", task: "go"))
        XCTAssertEqual(got?.0, "t1")
        XCTAssertEqual(got?.1, "go")
        XCTAssertTrue(q.all().isEmpty)
    }

    func testSelectWorktreeCallsItsOwnClosure() {
        let q = PendingOrdersQueue()
        var selected: String?
        var agentSelected: String?
        makeRouter(queue: q, selectWorktree: { selected = $0 }, selectAgent: { agentSelected = $0 })
            .route(.selectWorktree(path: "/repo/feat-x"))
        XCTAssertEqual(selected, "/repo/feat-x")
        XCTAssertNil(agentSelected)
    }

    func testSelectAgentCallsItsOwnClosure() {
        let q = PendingOrdersQueue()
        var selected: String?
        makeRouter(queue: q, selectAgent: { selected = $0 }).route(.selectAgent(id: "t2"))
        XCTAssertEqual(selected, "t2")
    }

    /// The desktop's listing is the dashboard, so every list verb navigates there.
    func testListVerbsShowOverview() {
        let q = PendingOrdersQueue()
        for command in [BridgeCommand.listWorktrees, .listAgents] as [BridgeCommand] {
            var shown = false
            makeRouter(queue: q, showOverview: { shown = true }).route(command)
            XCTAssertTrue(shown, "\(command) should show the overview")
        }
        XCTAssertTrue(q.all().isEmpty)
    }

    func testRemoveAllCallsRemoveAllClosure() {
        let q = PendingOrdersQueue()
        var called = false
        makeRouter(queue: q, removeAll: { called = true }).route(.removeAll)
        XCTAssertTrue(called)
        XCTAssertTrue(q.all().isEmpty)
    }

    func testBroadcastEnqueuesWithPayloadAndCount() {
        let q = PendingOrdersQueue()
        makeRouter(queue: q, agentCount: { 3 }).route(.broadcast(task: "run tests"))
        XCTAssertEqual(q.all().count, 1)
        XCTAssertEqual(q.all().first?.action.kind, .broadcastOrder)
        XCTAssertEqual(q.all().first?.action.payload, "run tests")
        XCTAssertTrue(q.all().first?.action.message.contains("3") ?? false)
    }

    func testFlagIssueCallsClosure() {
        let q = PendingOrdersQueue()
        var flagged: String?
        makeRouter(queue: q, flagIssue: { flagged = $0 }).route(.flagIssue(title: "fix the thing"))
        XCTAssertEqual(flagged, "fix the thing")
        XCTAssertTrue(q.all().isEmpty)
    }
}
