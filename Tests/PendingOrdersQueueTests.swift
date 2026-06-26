import XCTest
@testable import seahelm

final class PendingOrdersQueueTests: XCTestCase {
    private func action(_ kind: FirstMateActionKind, wt: String = "/wt/x") -> FirstMateAction {
        FirstMateAction(kind: kind, zone: .red, worktreePath: wt, branch: "b",
                        project: "p", terminalID: "t", message: "m")
    }

    func testEnqueueAddsOrder() {
        let q = PendingOrdersQueue()
        q.enqueue(action(.suggestNextOrder))
        XCTAssertEqual(q.all().count, 1)
    }

    func testDuplicateSameWorktreeAndKindKeepsOne() {
        let q = PendingOrdersQueue()
        q.enqueue(action(.suggestNextOrder))
        q.enqueue(action(.suggestNextOrder))
        XCTAssertEqual(q.all().count, 1)
    }

    func testDifferentWorktreesCoexist() {
        let q = PendingOrdersQueue()
        q.enqueue(action(.suggestNextOrder, wt: "/wt/a"))
        q.enqueue(action(.suggestNextOrder, wt: "/wt/b"))
        XCTAssertEqual(q.all().count, 2)
    }

    func testResolveRemovesAndAllowsReenqueue() {
        let q = PendingOrdersQueue()
        q.enqueue(action(.suggestNextOrder))
        let id = q.all()[0].id
        q.resolve(id: id)
        XCTAssertTrue(q.all().isEmpty)
        q.enqueue(action(.suggestNextOrder))
        XCTAssertEqual(q.all().count, 1)
    }

    func testOnChangeFiresOnEnqueueAndResolve() {
        let q = PendingOrdersQueue()
        var count = 0
        q.addObserver({ count += 1 })
        q.enqueue(action(.suggestNextOrder))
        let id = q.all()[0].id
        q.resolve(id: id)
        XCTAssertEqual(count, 2)
    }
}
