import XCTest
@testable import seahelm

final class BridgeCommandRouterTests: XCTestCase {
    func makeRouter(queue: PendingOrdersQueue,
                    created: @escaping (String) -> Void = { _ in },
                    ordered: @escaping (String, String) -> Void = { _, _ in },
                    committed: @escaping (String) -> Void = { _ in },
                    agentCount: @escaping () -> Int = { 0 }) -> BridgeCommandRouter {
        BridgeCommandRouter(queue: queue, createWorktree: created, orderExisting: ordered,
                            commit: committed, activeSailorCount: agentCount,
                            branchForPath: { _ in "feat-x" }, projectForPath: { _ in "repo" })
    }

    func testNewWorktreeCallsClosureNotQueue() {
        let q = PendingOrdersQueue()
        var got: String?
        makeRouter(queue: q, created: { got = $0 }).route(.newWorktree(task: "do it"))
        XCTAssertEqual(got, "do it")
        XCTAssertTrue(q.all().isEmpty)
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

    func testReturnEnqueuesRed() {
        let q = PendingOrdersQueue()
        makeRouter(queue: q).route(.returnToPort(worktreePath: "/p"))
        XCTAssertEqual(q.all().count, 1)
        XCTAssertEqual(q.all().first?.action.kind, .returnToPort)
        XCTAssertEqual(q.all().first?.action.worktreePath, "/p")
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
