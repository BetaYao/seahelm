import XCTest
@testable import seahelm

final class SuggestOrderTests: XCTestCase {
    /// `terminalID` defaults to "t1"; pass a second one to model a split pane —
    /// two panes of the same worktree share `worktreePath` but never a terminal.
    private func suggestOutcome(options: [String], terminalID: String = "t1") -> IngestOutcome {
        let info = SailorInfo(id: terminalID, worktreePath: "/wt", agentType: .claudeCode,
                              project: "p", branch: "b", status: .idle, lastMessage: "",
                              commandLine: nil, roundDuration: 0, startedAt: nil, station: nil,
                              channel: nil, taskProgress: TaskProgress())
        return IngestOutcome(info: info, statusChanged: false, oldStatus: .idle, newStatus: .idle,
                             holdSeconds: 0, isCompletionSignal: false,
                             event: NormalizedEvent(terminalID: terminalID, source: .hook("seahelm-suggest"),
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

    func testNewSuggestReplacesOldForSamePane() {
        let queue = PendingOrdersQueue()
        let coord = FirstMateCoordinator(config: .default, queue: queue,
            notify: { _ in }, runInspection: { _ in })
        coord.handle(suggestOutcome(options: ["old"]))
        coord.handle(suggestOutcome(options: ["new1", "new2"]))
        XCTAssertEqual(queue.all().count, 1)
        XCTAssertEqual(queue.all().first?.action.options, ["new1", "new2"])
    }

    /// Two panes of one worktree each get a card; neither displaces the other.
    func testSuggestFromSiblingPaneDoesNotReplaceTheFirst() {
        let queue = PendingOrdersQueue()
        let coord = FirstMateCoordinator(config: .default, queue: queue,
            notify: { _ in }, runInspection: { _ in })
        coord.handle(suggestOutcome(options: ["from t1"], terminalID: "t1"))
        coord.handle(suggestOutcome(options: ["from t2"], terminalID: "t2"))
        XCTAssertEqual(queue.all().count, 2, "each pane should hold its own suggestion card")
        XCTAssertEqual(queue.all().map(\.action.terminalID), ["t1", "t2"])
    }

    func testEmptyOptionsEnqueuesNothing() {
        let queue = PendingOrdersQueue()
        let coord = FirstMateCoordinator(config: .default, queue: queue,
            notify: { _ in }, runInspection: { _ in })
        coord.handle(suggestOutcome(options: []))
        XCTAssertTrue(queue.all().isEmpty)
    }

    private func userPromptOutcome(terminalID: String) -> IngestOutcome {
        let info = SailorInfo(id: terminalID, worktreePath: "/wt", agentType: .claudeCode,
                              project: "p", branch: "b", status: .idle, lastMessage: "",
                              commandLine: nil, roundDuration: 0, startedAt: nil, station: nil,
                              channel: nil, taskProgress: TaskProgress())
        return IngestOutcome(info: info, statusChanged: false, oldStatus: .idle,
                             newStatus: .idle, holdSeconds: 0, isCompletionSignal: false,
                             event: NormalizedEvent(terminalID: terminalID, source: .hook("claude-code"),
                                                    kind: .userPrompt("hi")))
    }

    func testUserPromptClearsExistingSuggestOrder() {
        let queue = PendingOrdersQueue()
        let coord = FirstMateCoordinator(config: .default, queue: queue,
            notify: { _ in }, runInspection: { _ in })
        coord.handle(suggestOutcome(options: ["run tests"]))
        XCTAssertEqual(queue.all().count, 1, "suggest order should be enqueued")
        coord.handle(userPromptOutcome(terminalID: "t1"))
        XCTAssertTrue(queue.all().isEmpty, "suggest order should be cleared on userPrompt")
    }

    /// Typing in one pane must not clear a sibling pane's suggestions.
    func testUserPromptDoesNotClearSiblingPanesSuggestOrder() {
        let queue = PendingOrdersQueue()
        let coord = FirstMateCoordinator(config: .default, queue: queue,
            notify: { _ in }, runInspection: { _ in })
        coord.handle(suggestOutcome(options: ["run tests"], terminalID: "t2"))
        coord.handle(userPromptOutcome(terminalID: "t1"))
        XCTAssertEqual(queue.all().count, 1, "t2's card should survive a prompt typed in t1")
        XCTAssertEqual(queue.all().first?.action.terminalID, "t2")
    }

    func testResolveSuggestDirectly() {
        let queue = PendingOrdersQueue()
        let action = FirstMateAction(kind: .suggestNextOrder, zone: .red, worktreePath: "/wt",
                                     branch: "b", project: "p", terminalID: "t",
                                     message: "suggestions", options: ["a"])
        queue.upsert(action)
        XCTAssertEqual(queue.all().count, 1)
        queue.resolveSuggest(terminalID: "t")
        XCTAssertTrue(queue.all().isEmpty)
    }
}
