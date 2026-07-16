import XCTest
@testable import seahelm

final class BridgeCommandRouterTests: XCTestCase {
    func makeRouter(queue: PendingOrdersQueue,
                    created: @escaping (String, String?) -> Void = { _, _ in },
                    ordered: @escaping (String, String) -> Void = { _, _ in },
                    committed: @escaping (String) -> Void = { _ in },
                    returnWorktree: @escaping (String) -> Void = { _ in },
                    returnAll: @escaping () -> Void = {},
                    addRepo: @escaping () -> Void = {},
                    removeRepo: @escaping (String) -> Void = { _ in },
                    removeWorktree: @escaping (String) -> Void = { _ in },
                    agentCount: @escaping () -> Int = { 0 }) -> BridgeCommandRouter {
        BridgeCommandRouter(queue: queue, createWorktree: created, orderExisting: ordered,
                            commit: committed, returnWorktree: returnWorktree,
                            returnAll: returnAll, addRepo: addRepo, removeRepo: removeRepo,
                            removeWorktree: removeWorktree,
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

    func testOrderCallsClosure() {
        let q = PendingOrdersQueue()
        var got: (String, String)?
        makeRouter(queue: q, ordered: { got = ($0, $1) }).route(.orderExisting(worktreePath: "/p", task: "go"))
        XCTAssertEqual(got?.0, "/p")
        XCTAssertEqual(got?.1, "go")
        XCTAssertTrue(q.all().isEmpty)
    }

    func testCommitCallsClosureNotQueue() {
        let q = PendingOrdersQueue()
        var got: String?
        makeRouter(queue: q, committed: { got = $0 }).route(.commit(worktreePath: "/repo"))
        XCTAssertEqual(got, "/repo")
        XCTAssertTrue(q.all().isEmpty)
    }

    func testReturnToPortCallsReturnWorktreeClosure() {
        let q = PendingOrdersQueue()
        var got: String?
        makeRouter(queue: q, returnWorktree: { got = $0 }).route(.returnToPort(worktreePath: "/p"))
        XCTAssertEqual(got, "/p")
        XCTAssertTrue(q.all().isEmpty)
    }

    func testReturnAllCallsReturnAllClosure() {
        let q = PendingOrdersQueue()
        var called = false
        makeRouter(queue: q, returnAll: { called = true }).route(.returnAll)
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
}
