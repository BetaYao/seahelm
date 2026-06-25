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
            notify: { _ in evaluated = true }, runInspection: { _ in evaluated = true },
            hasOrders: { _ in true })
        let act = ActivityEvent(tool: "Bash", detail: "ls", isError: false, timestamp: Date())
        coord.handle(outcome(kind: .toolUse(act), changed: false, completion: false, newStatus: .running))
        XCTAssertFalse(evaluated, "tool_use without status change must not reach FirstMate")
    }

    func testCompletionSignalIsEvaluated() {
        var inspected = false
        let coord = FirstMateCoordinator(config: .default, queue: PendingOrdersQueue(),
            notify: { _ in }, runInspection: { _ in inspected = true },
            hasOrders: { _ in true })
        coord.handle(outcome(kind: .agentStopped(success: true), changed: true,
                             completion: true, newStatus: .idle))
        XCTAssertTrue(inspected, "completion must trigger inspect (autoInspect default true)")
    }
}
