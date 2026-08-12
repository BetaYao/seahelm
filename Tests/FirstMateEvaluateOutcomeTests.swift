import XCTest
@testable import seahelm

/// Tests the unified `FirstMate.evaluate(_ outcome:config:)` entry that folds
/// the agent-suggestion path into the pure rule engine (no longer special-cased
/// in FirstMateCoordinator).
final class FirstMateEvaluateOutcomeTests: XCTestCase {
    private func outcome(kind: NormalizedEventKind, source: EventSource = .hook("claude-code"),
                         changed: Bool = false,
                         completion: Bool = false, newStatus: AgentStatus = .running,
                         hold: Double = 0,
                         lastMessage: String = "",
                         lastAssistantMessage: String = "") -> IngestOutcome {
        var info = PaneInfo(id: "t1", worktreePath: "/wt", agentType: .claudeCode,
                              project: "p", branch: "b", status: newStatus, lastMessage: lastMessage,
                              commandLine: nil, roundDuration: 0, startedAt: nil, station: nil,
                              channel: nil, taskProgress: TaskProgress())
        info.lastAssistantMessage = lastAssistantMessage
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

    /// Cursor often runs `seahelm-suggest` as a Shell tool. The viewport scanner then
    /// leaves `lastMessage == "Shell"` — that must not become the card summary when
    /// the real assistant prose never landed in `lastAssistantMessage`.
    func testSuggestIgnoresShellToolLabelAsSummary() {
        let acts = FirstMate.evaluate(
            outcome(kind: .suggest(options: ["打开架构页", "继续改"]),
                    lastMessage: "Shell"),
            config: .default)
        XCTAssertEqual(acts.first?.options, ["打开架构页", "继续改"])
        XCTAssertEqual(acts.first?.message, "",
                       "tool chrome is not the agent's answer")
    }

    func testSuggestPrefersAssistantProseOverShellLabel() {
        let prose = "当前分支已与远端同步，无新提交。"
        let acts = FirstMate.evaluate(
            outcome(kind: .suggest(options: ["打开架构页"]),
                    lastMessage: "Shell",
                    lastAssistantMessage: prose),
            config: .default)
        XCTAssertEqual(acts.first?.message, prose)
    }

    func testSuggestSummaryStripsSentinelAndKeepsBullets() {
        let prose = """
        澄清完成，且未修改 Issue 或业务代码。

        已新增：

        - CONTEXT.md：记录 Dashboard 权限、指标、周期、空状态。
        - docs/adr/0001.md：明确员工端必须经后端聚合接口读取指标。

        ::seahelm-suggest:: 生成 Issue 规格 | 查看澄清结论 | 开始实施
        """
        let summary = FirstMate.suggestionSummaryText(from: prose)
        XCTAssertTrue(summary.contains("澄清完成"))
        XCTAssertTrue(summary.contains("- CONTEXT.md"))
        XCTAssertTrue(summary.contains("- docs/adr/0001.md"))
        XCTAssertFalse(summary.contains("::seahelm-suggest::"))
    }

    func testJunkSuggestionSummaryDetectsToolChrome() {
        XCTAssertTrue(FirstMate.isJunkSuggestionSummary("Shell"))
        XCTAssertTrue(FirstMate.isJunkSuggestionSummary("Bash"))
        XCTAssertTrue(FirstMate.isJunkSuggestionSummary("seahelm-suggest 'a' 'b'"))
        XCTAssertFalse(FirstMate.isJunkSuggestionSummary("当前分支已与远端同步"))
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
