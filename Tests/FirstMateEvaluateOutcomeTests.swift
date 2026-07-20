import XCTest
@testable import seahelm

/// Tests the unified `FirstMate.evaluate(_ outcome:config:)` entry that folds
/// the agent-suggestion path into the pure rule engine (no longer special-cased
/// in FirstMateCoordinator).
final class FirstMateEvaluateOutcomeTests: XCTestCase {
    private func outcome(kind: NormalizedEventKind, source: EventSource = .hook("claude-code"),
                         changed: Bool = false,
                         completion: Bool = false, newStatus: SailorStatus = .running,
                         hold: Double = 0) -> IngestOutcome {
        let info = SailorInfo(id: "t1", worktreePath: "/wt", agentType: .claudeCode,
                              project: "p", branch: "b", status: newStatus, lastMessage: "",
                              commandLine: nil, roundDuration: 0, startedAt: nil, station: nil,
                              channel: nil, taskProgress: TaskProgress())
        return IngestOutcome(info: info, statusChanged: changed, oldStatus: .running,
                             newStatus: newStatus, holdSeconds: hold, isCompletionSignal: completion,
                             event: NormalizedEvent(terminalID: "t1", source: source, kind: kind))
    }

    func testSuggestEventEmitsRedSuggestNextOrderWithOptions() {
        let acts = FirstMate.evaluate(outcome(kind: .suggest(options: ["a", "b"])), config: .default)
        XCTAssertEqual(acts.map(\.kind), [.suggestNextOrder])
        XCTAssertEqual(acts.first?.zone, .red)
        XCTAssertEqual(acts.first?.options, ["a", "b"])
    }

    func testEmptySuggestEmitsNothing() {
        let acts = FirstMate.evaluate(outcome(kind: .suggest(options: [])), config: .default)
        XCTAssertTrue(acts.isEmpty)
    }

    func testQuestionEventEmitsCardWithPromptAndPayloadMarker() {
        let acts = FirstMate.evaluate(
            outcome(kind: .question(prompt: "Pick one?", options: ["A", "B"], followups: [])), config: .default)
        XCTAssertEqual(acts.map(\.kind), [.suggestNextOrder])
        XCTAssertEqual(acts.first?.zone, .red)
        XCTAssertEqual(acts.first?.message, "Pick one?")
        XCTAssertEqual(acts.first?.options, ["A", "B"])
        XCTAssertEqual(acts.first?.payload, "ask-user-question")
    }

    func testEmptyQuestionOptionsEmitsNothing() {
        let acts = FirstMate.evaluate(
            outcome(kind: .question(prompt: "Pick?", options: [], followups: [])), config: .default)
        XCTAssertTrue(acts.isEmpty)
    }

    func testScreenChoiceUsesViewportPayloadMarker() {
        let acts = FirstMate.evaluate(
            outcome(kind: .question(prompt: "Codex requires approval",
                                    options: ["Yes", "No"], followups: []),
                    source: .scan),
            config: .default)
        XCTAssertEqual(acts.first?.payload, FirstMateAction.screenChoicePayload)
    }

    func testStatusTransitionRoutedThroughOutcomeEntry() {
        let acts = FirstMate.evaluate(outcome(kind: .agentStopped(success: false),
                                              changed: true, newStatus: .error), config: .default)
        XCTAssertEqual(acts.map(\.kind), [.watchError])
        XCTAssertEqual(acts.first?.zone, .green)
    }

    func testNoStatusChangeNoCompletionEmitsNothing() {
        let act = ActivityEvent(tool: "Bash", detail: "ls", isError: false, timestamp: Date())
        let acts = FirstMate.evaluate(outcome(kind: .toolUse(act), changed: false), config: .default)
        XCTAssertTrue(acts.isEmpty)
    }

    func testDisabledEmitsNothingForSuggest() {
        var cfg = FirstMateConfig.default; cfg.enabled = false
        let acts = FirstMate.evaluate(outcome(kind: .suggest(options: ["a"])), config: cfg)
        XCTAssertTrue(acts.isEmpty)
    }
}
