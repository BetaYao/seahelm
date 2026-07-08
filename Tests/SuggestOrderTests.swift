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
            notify: { _ in }, runInspection: { _ in })
        coord.handle(suggestOutcome(options: ["run tests", "open PR"]))
        XCTAssertEqual(queue.all().count, 1)
        XCTAssertEqual(queue.all().first?.action.kind, .suggestNextOrder)
        XCTAssertEqual(queue.all().first?.action.zone, .red)
        XCTAssertEqual(queue.all().first?.action.options, ["run tests", "open PR"])
    }

    func testNewSuggestReplacesOldForSameWorktree() {
        let queue = PendingOrdersQueue()
        let coord = FirstMateCoordinator(config: .default, queue: queue,
            notify: { _ in }, runInspection: { _ in })
        coord.handle(suggestOutcome(options: ["old"]))
        coord.handle(suggestOutcome(options: ["new1", "new2"]))
        XCTAssertEqual(queue.all().count, 1)
        XCTAssertEqual(queue.all().first?.action.options, ["new1", "new2"])
    }

    func testEmptyOptionsEnqueuesNothing() {
        let queue = PendingOrdersQueue()
        let coord = FirstMateCoordinator(config: .default, queue: queue,
            notify: { _ in }, runInspection: { _ in })
        coord.handle(suggestOutcome(options: []))
        XCTAssertTrue(queue.all().isEmpty)
    }

    func testUserPromptClearsExistingSuggestOrder() {
        let queue = PendingOrdersQueue()
        let coord = FirstMateCoordinator(config: .default, queue: queue,
            notify: { _ in }, runInspection: { _ in })
        // Enqueue a suggest order for /wt
        coord.handle(suggestOutcome(options: ["run tests"]))
        XCTAssertEqual(queue.all().count, 1, "suggest order should be enqueued")
        // Now send a userPrompt for the same worktree
        let info = SailorInfo(id: "t1", worktreePath: "/wt", agentType: .claudeCode,
                              project: "p", branch: "b", status: .idle, lastMessage: "",
                              commandLine: nil, roundDuration: 0, startedAt: nil, station: nil,
                              channel: nil, taskProgress: TaskProgress())
        let promptOutcome = IngestOutcome(info: info, statusChanged: false, oldStatus: .idle,
                                         newStatus: .idle, holdSeconds: 0, isCompletionSignal: false,
                                         event: NormalizedEvent(terminalID: "t1", source: .hook("claude-code"),
                                                                kind: .userPrompt("hi")))
        coord.handle(promptOutcome)
        XCTAssertTrue(queue.all().isEmpty, "suggest order should be cleared on userPrompt")
    }

    func testResolveSuggestDirectly() {
        let queue = PendingOrdersQueue()
        let action = FirstMateAction(kind: .suggestNextOrder, zone: .red, worktreePath: "/wt",
                                     branch: "b", project: "p", terminalID: "t",
                                     message: "suggestions", options: ["a"])
        queue.upsert(action)
        XCTAssertEqual(queue.all().count, 1)
        queue.resolveSuggest(worktreePath: "/wt")
        XCTAssertTrue(queue.all().isEmpty)
    }
}
