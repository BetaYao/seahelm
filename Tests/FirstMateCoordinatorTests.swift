import XCTest
@testable import seahelm

final class FirstMateCoordinatorTests: XCTestCase {
    private func tx(_ new: AgentStatus, hold: Double = 0, completion: Bool = false) -> StatusTransition {
        StatusTransition(worktreePath: "/wt/x", branch: "b", project: "p", terminalID: "t",
                         oldStatus: .running, newStatus: new, holdSeconds: hold,
                         isCompletionSignal: completion)
    }

    func testGreenWatchErrorCallsNotify() {
        var notified: [FirstMateActionKind] = []
        let q = PendingOrdersQueue()
        let c = FirstMateCoordinator(config: .default, queue: q,
            notify: { notified.append($0.kind) }, runInspection: { _ in },
            hasOrders: { _ in true })
        c.handle(tx(.error))
        XCTAssertEqual(notified, [.watchError])
        XCTAssertTrue(q.all().isEmpty)
    }

    func testCompletionRunsInspection() {
        var inspected = 0
        let c = FirstMateCoordinator(config: .default, queue: PendingOrdersQueue(),
            notify: { _ in }, runInspection: { if $0.kind == .inspect { inspected += 1 } },
            hasOrders: { _ in false })
        c.handle(tx(.idle, completion: true))
        XCTAssertEqual(inspected, 1)
    }

    func testSuggestNextOrderEnqueuedOnlyWhenOrdersExist() {
        let q1 = PendingOrdersQueue()
        let c1 = FirstMateCoordinator(config: .default, queue: q1,
            notify: { _ in }, runInspection: { _ in }, hasOrders: { _ in false })
        c1.handle(tx(.idle, completion: false))
        XCTAssertTrue(q1.all().isEmpty, "no orders → no enqueue")

        let q2 = PendingOrdersQueue()
        let c2 = FirstMateCoordinator(config: .default, queue: q2,
            notify: { _ in }, runInspection: { _ in }, hasOrders: { _ in true })
        c2.handle(tx(.idle, completion: false))
        XCTAssertEqual(q2.all().map(\.action.kind), [.suggestNextOrder])
    }
}
