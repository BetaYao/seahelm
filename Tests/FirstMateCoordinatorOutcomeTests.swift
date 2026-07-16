import XCTest
@testable import seahelm

final class FirstMateCoordinatorOutcomeTests: XCTestCase {
    private func outcome(kind: NormalizedEventKind, changed: Bool, completion: Bool,
                         newStatus: SailorStatus) -> IngestOutcome {
        let info = SailorInfo(id: "t1", worktreePath: "/wt", agentType: .claudeCode,
                              project: "p", branch: "b", status: newStatus, lastMessage: "",
                              commandLine: nil, roundDuration: 0, startedAt: nil, station: nil,
                              channel: nil, taskProgress: TaskProgress())
        return IngestOutcome(info: info, statusChanged: changed, oldStatus: .running,
                             newStatus: newStatus, holdSeconds: 0, isCompletionSignal: completion,
                             event: NormalizedEvent(terminalID: "t1", source: .hook("claude-code"), kind: kind))
    }

    func testHighFrequencyToolUseIsNotEvaluated() {
        var evaluated = false
        let coord = FirstMateCoordinator(config: .default, queue: PendingOrdersQueue(),
            notify: { _ in evaluated = true }, runInspection: { _ in evaluated = true })
        let act = ActivityEvent(tool: "Bash", detail: "ls", isError: false, timestamp: Date())
        coord.handle(outcome(kind: .toolUse(act), changed: false, completion: false, newStatus: .running))
        XCTAssertFalse(evaluated, "tool_use without status change must not reach FirstMate")
    }

    private func questionAction(worktree: String = "/wt") -> FirstMateAction {
        FirstMateAction(kind: .suggestNextOrder, zone: .red, worktreePath: worktree,
                        branch: "b", project: "p", terminalID: "t1",
                        message: "Pick one", payload: FirstMateAction.askUserQuestionPayload,
                        options: ["A", "B"])
    }

    func testToolUseResolvesStaleQuestionCard() {
        let q = PendingOrdersQueue()
        q.upsert(questionAction())
        let coord = FirstMateCoordinator(config: .default, queue: q,
            notify: { _ in }, runInspection: { _ in })
        let act = ActivityEvent(tool: "Bash", detail: "ls", isError: false, timestamp: Date())
        coord.handle(outcome(kind: .toolUse(act), changed: false, completion: false, newStatus: .running))
        XCTAssertTrue(q.all().isEmpty, "answered AskUserQuestion card must clear on next tool use")
    }

    func testAgentStoppedResolvesStaleQuestionCard() {
        let q = PendingOrdersQueue()
        q.upsert(questionAction())
        let coord = FirstMateCoordinator(config: .default, queue: q,
            notify: { _ in }, runInspection: { _ in })
        coord.handle(outcome(kind: .agentStopped(success: true), changed: true,
                             completion: false, newStatus: .idle))
        XCTAssertTrue(q.all().isEmpty, "answered AskUserQuestion card must clear on agent stop")
    }

    func testToolUseKeepsQuestionCardOfOtherWorktree() {
        let q = PendingOrdersQueue()
        q.upsert(questionAction(worktree: "/other"))
        let coord = FirstMateCoordinator(config: .default, queue: q,
            notify: { _ in }, runInspection: { _ in })
        let act = ActivityEvent(tool: "Bash", detail: "ls", isError: false, timestamp: Date())
        coord.handle(outcome(kind: .toolUse(act), changed: false, completion: false, newStatus: .running))
        XCTAssertEqual(q.all().count, 1, "cards of other worktrees must survive")
    }

    func testCompletionSignalIsEvaluated() {
        var inspected = false
        let coord = FirstMateCoordinator(config: .default, queue: PendingOrdersQueue(),
            notify: { _ in }, runInspection: { _ in inspected = true })
        coord.handle(outcome(kind: .agentStopped(success: true), changed: true,
                             completion: true, newStatus: .idle))
        XCTAssertTrue(inspected, "completion must trigger inspect (autoInspect default true)")
    }
}
