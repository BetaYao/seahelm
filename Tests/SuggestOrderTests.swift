import XCTest
@testable import seahelm

final class SuggestOrderTests: XCTestCase {
    private func suggestOutcome(options: [String]) -> IngestOutcome {
        let info = SailorInfo(id: "t1", worktreePath: "/wt", agentType: .claudeCode,
                              project: "p", branch: "b", status: .idle, lastMessage: "",
                              commandLine: nil, roundDuration: 0, startedAt: nil, station: nil,
                              channel: nil, taskProgress: TaskProgress())
        return IngestOutcome(info: info, statusChanged: false, oldStatus: .idle, newStatus: .idle,
                             holdSeconds: 0, isCompletionSignal: false,
                             event: NormalizedEvent(terminalID: "t1", source: .hook("seahelm-suggest"),
                                                    kind: .suggest(options: options)))
    }

    func testSuggestOutcomeEnqueuesRedOrderWithOptions() {
        let queue = PendingOrdersQueue()
        let coord = FirstMateCoordinator(config: .default, queue: queue,
            notify: { _ in }, runInspection: { _ in }, hasOrders: { _ in true })
        coord.handle(suggestOutcome(options: ["run tests", "open PR"]))
        XCTAssertEqual(queue.all().count, 1)
        XCTAssertEqual(queue.all().first?.action.kind, .suggestNextOrder)
        XCTAssertEqual(queue.all().first?.action.zone, .red)
        XCTAssertEqual(queue.all().first?.action.options, ["run tests", "open PR"])
    }

    func testNewSuggestReplacesOldForSameWorktree() {
        let queue = PendingOrdersQueue()
        let coord = FirstMateCoordinator(config: .default, queue: queue,
            notify: { _ in }, runInspection: { _ in }, hasOrders: { _ in true })
        coord.handle(suggestOutcome(options: ["old"]))
        coord.handle(suggestOutcome(options: ["new1", "new2"]))
        XCTAssertEqual(queue.all().count, 1)
        XCTAssertEqual(queue.all().first?.action.options, ["new1", "new2"])
    }

    func testEmptyOptionsEnqueuesNothing() {
        let queue = PendingOrdersQueue()
        let coord = FirstMateCoordinator(config: .default, queue: queue,
            notify: { _ in }, runInspection: { _ in }, hasOrders: { _ in true })
        coord.handle(suggestOutcome(options: []))
        XCTAssertTrue(queue.all().isEmpty)
    }
}
