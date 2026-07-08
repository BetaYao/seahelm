import XCTest
@testable import seahelm

final class FirstMateCoordinatorTests: XCTestCase {
    private func tx(_ new: SailorStatus, hold: Double = 0, completion: Bool = false) -> StatusTransition {
        StatusTransition(worktreePath: "/wt/x", branch: "b", project: "p", terminalID: "t",
                         oldStatus: .running, newStatus: new, holdSeconds: hold,
                         isCompletionSignal: completion)
    }

    func testGreenWatchErrorCallsNotify() {
        var notified: [FirstMateActionKind] = []
        let q = PendingOrdersQueue()
        let c = FirstMateCoordinator(config: .default, queue: q,
            notify: { notified.append($0.kind) }, runInspection: { _ in })
        c.handle(tx(.error))
        XCTAssertEqual(notified, [.watchError])
        XCTAssertTrue(q.all().isEmpty)
    }

    func testCompletionRunsInspection() {
        var inspected = 0
        let c = FirstMateCoordinator(config: .default, queue: PendingOrdersQueue(),
            notify: { _ in }, runInspection: { if $0.kind == .inspect { inspected += 1 } })
        c.handle(tx(.idle, completion: true))
        XCTAssertEqual(inspected, 1)
    }

    func testBareIdleEnqueuesNothing() {
        let q = PendingOrdersQueue()
        let c = FirstMateCoordinator(config: .default, queue: q,
            notify: { _ in }, runInspection: { _ in })
        c.handle(tx(.idle, completion: false))
        XCTAssertTrue(q.all().isEmpty, "bare idle no longer auto-suggests")
    }
}
