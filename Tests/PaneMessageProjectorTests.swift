import XCTest
@testable import seahelm

final class PaneMessageProjectorTests: XCTestCase {
    private func outcome(
        kind: NormalizedEventKind,
        statusChanged: Bool = false,
        old: AgentStatus = .idle,
        new: AgentStatus = .running,
        isCompletion: Bool = false,
        assistant: String = "",
        paneId: String = "t1"
    ) -> IngestOutcome {
        var info = PaneInfo(
            id: paneId, worktreePath: "/wt", agentType: .cursor,
            project: "p", branch: "main", status: new,
            lastMessage: "", commandLine: nil, roundDuration: 0,
            startedAt: nil, station: nil, channel: nil,
            taskProgress: TaskProgress())
        info.lastAssistantMessage = assistant
        let event = NormalizedEvent(terminalID: paneId, source: .hook("cursor"), kind: kind)
        return IngestOutcome(
            info: info, statusChanged: statusChanged,
            oldStatus: old, newStatus: new, holdSeconds: 0,
            isCompletionSignal: isCompletion, event: event, seq: 1)
    }

    func testUserPromptEmitsUser() {
        let o = outcome(kind: .userPrompt("ship it"))
        let (evs, _) = PaneMessageProjector.project(
            outcome: o, config: .default, coalesce: .empty, now: Date())
        XCTAssertEqual(evs.map(\.kind), [.user])
        XCTAssertEqual(evs.first?.text, "ship it")
    }

    func testToolUseEmitsTool() {
        let tool = ActivityEvent(tool: "Read", detail: "a.swift", isError: false, timestamp: Date())
        let o = outcome(kind: .toolUse(tool))
        let (evs, _) = PaneMessageProjector.project(
            outcome: o, config: .default, coalesce: .empty, now: Date())
        XCTAssertEqual(evs.first?.kind, .tool)
        XCTAssertEqual(evs.first?.tool, "Read")
        XCTAssertEqual(evs.first?.detail, "a.swift")
    }

    func testCoalesceIdenticalTools() {
        let tool = ActivityEvent(tool: "Shell", detail: "ls", isError: false, timestamp: Date())
        let o = outcome(kind: .toolUse(tool))
        let (first, c1) = PaneMessageProjector.project(
            outcome: o, config: .default, coalesce: .empty, now: Date())
        XCTAssertEqual(first.count, 1)
        let (second, c2) = PaneMessageProjector.project(
            outcome: o, config: .default, coalesce: c1, now: Date())
        XCTAssertTrue(second.isEmpty, "duplicate tool should coalesce into state only")
        XCTAssertEqual(c2.lastCount, 2)
    }

    func testAssistantOnlyOnCompletion() {
        let idle = outcome(kind: .agentStopped(success: true),
                           statusChanged: true, old: .running, new: .idle,
                           isCompletion: true, assistant: "done")
        let (evs, _) = PaneMessageProjector.project(
            outcome: idle, config: .default, coalesce: .empty, now: Date())
        XCTAssertTrue(evs.contains(where: { $0.kind == .assistant && $0.text == "done" }))
        XCTAssertTrue(evs.contains(where: { $0.kind == .status }))
    }

    func testLeavingUnknownIsNotAStatusRow() {
        let registered = outcome(kind: .screenObserved(
            status: .idle, message: "", activity: [], commandLine: nil,
            agentType: .claudeCode, roundDuration: 0, tasks: []),
            statusChanged: true, old: .unknown, new: .idle)
        let (evs, _) = PaneMessageProjector.project(
            outcome: registered, config: .default, coalesce: .empty, now: Date())
        XCTAssertTrue(evs.isEmpty)
    }

    func testNoAssistantWithoutCompletionSignal() {
        let o = outcome(kind: .toolUse(ActivityEvent(
            tool: "Read", detail: "x", isError: false, timestamp: Date())),
                        assistant: "stale prose")
        let (evs, _) = PaneMessageProjector.project(
            outcome: o, config: .default, coalesce: .empty, now: Date())
        XCTAssertFalse(evs.contains(where: { $0.kind == .assistant }))
    }

    func testScreenFallbackOffIgnoresScanSoup() {
        var cfg = MessageConfig.default
        cfg.screenFallback = false
        let o = outcome(kind: .screenObserved(
            status: .running, message: "Shell", activity: [],
            commandLine: nil, agentType: .cursor, roundDuration: 1, tasks: []))
        let (evs, _) = PaneMessageProjector.project(
            outcome: o, config: cfg, coalesce: .empty, now: Date())
        XCTAssertTrue(evs.filter { $0.kind == .notice || $0.kind == .assistant }.isEmpty)
    }

    private let approval = NormalizedEventKind.question(
        prompt: "Claude Code requires approval", options: ["1. Yes", "2. No"], followups: [])

    func testRescannedQuestionEmitsOneDecision() {
        let (first, c1) = PaneMessageProjector.project(
            outcome: outcome(kind: approval, statusChanged: true, old: .running, new: .waiting),
            config: .default, coalesce: .empty, now: Date())
        XCTAssertEqual(first.filter { $0.kind == .decision }.count, 1)

        var coal = c1
        for _ in 0..<3 {
            let (again, next) = PaneMessageProjector.project(
                outcome: outcome(kind: approval, old: .waiting, new: .waiting),
                config: .default, coalesce: coal, now: Date())
            XCTAssertTrue(again.isEmpty, "a dialog still on screen is the same decision")
            coal = next
        }
    }

    func testNotificationDoesNotReopenDecision() {
        let (_, c1) = PaneMessageProjector.project(
            outcome: outcome(kind: approval, statusChanged: true, old: .running, new: .waiting),
            config: .default, coalesce: .empty, now: Date())
        let (_, c2) = PaneMessageProjector.project(
            outcome: outcome(kind: .notification(level: "info", text: "Claude needs your permission"),
                             old: .waiting, new: .waiting),
            config: .default, coalesce: c1, now: Date())
        let (again, _) = PaneMessageProjector.project(
            outcome: outcome(kind: approval, old: .waiting, new: .waiting),
            config: .default, coalesce: c2, now: Date())
        XCTAssertFalse(again.contains { $0.kind == .decision })
    }

    func testSameQuestionAfterToolRunIsNewDecision() {
        let (_, c1) = PaneMessageProjector.project(
            outcome: outcome(kind: approval, statusChanged: true, old: .running, new: .waiting),
            config: .default, coalesce: .empty, now: Date())
        let tool = ActivityEvent(tool: "Bash", detail: "ls", isError: false, timestamp: Date())
        let (_, c2) = PaneMessageProjector.project(
            outcome: outcome(kind: .toolUse(tool), old: .waiting, new: .waiting),
            config: .default, coalesce: c1, now: Date())
        let (next, _) = PaneMessageProjector.project(
            outcome: outcome(kind: approval, old: .waiting, new: .waiting),
            config: .default, coalesce: c2, now: Date())
        XCTAssertEqual(next.filter { $0.kind == .decision }.count, 1)
    }

    func testSameQuestionAfterRunningAgainIsNewDecision() {
        let (_, c1) = PaneMessageProjector.project(
            outcome: outcome(kind: approval, statusChanged: true, old: .running, new: .waiting),
            config: .default, coalesce: .empty, now: Date())
        let (_, c2) = PaneMessageProjector.project(
            outcome: outcome(kind: scan(.running), statusChanged: true, old: .waiting, new: .running),
            config: .default, coalesce: c1, now: Date())
        let (next, _) = PaneMessageProjector.project(
            outcome: outcome(kind: approval, statusChanged: true, old: .running, new: .waiting),
            config: .default, coalesce: c2, now: Date())
        XCTAssertEqual(next.filter { $0.kind == .decision }.count, 1)
    }

    /// What one Claude approval dialog produced on every 2s poll: the scan says
    /// Idle, then the dialog says Waiting. It used to add a decision and two
    /// status rows each time.
    func testIdleWaitingFlickerDuringOneApprovalIsOneDecision() {
        var coal = PaneMessageProjector.CoalesceState.empty
        var all: [MessageEvent] = []
        let (first, c0) = PaneMessageProjector.project(
            outcome: outcome(kind: approval, statusChanged: true, old: .idle, new: .waiting),
            config: .default, coalesce: coal, now: Date())
        all += first
        coal = c0
        for _ in 0..<8 {
            for (kind, old, new) in [(scan(.idle), AgentStatus.waiting, AgentStatus.idle),
                                     (approval, .idle, .waiting)] {
                let (evs, next) = PaneMessageProjector.project(
                    outcome: outcome(kind: kind, statusChanged: true, old: old, new: new),
                    config: .default, coalesce: coal, now: Date())
                all += evs
                coal = next
            }
        }
        XCTAssertEqual(all.filter { $0.kind == .decision }.count, 1)
        XCTAssertTrue(all.filter { $0.kind == .status }.isEmpty)
    }

    func testOnlyTurnEdgesAreStatusRows() {
        let rows: [(AgentStatus, AgentStatus, Bool)] = [
            (.idle, .running, true), (.running, .idle, true), (.running, .waiting, true),
            (.waiting, .running, true), (.idle, .error, true), (.running, .error, true),
            (.idle, .waiting, false), (.waiting, .idle, false), (.unknown, .running, false),
        ]
        for (old, new, expected) in rows {
            XCTAssertEqual(PaneMessageProjector.isTurnEdge(from: old, to: new), expected, "\(old) → \(new)")
        }
    }

    private func scan(_ status: AgentStatus) -> NormalizedEventKind {
        .screenObserved(status: status, message: "", activity: [], commandLine: nil,
                        agentType: .claudeCode, roundDuration: 0, tasks: [])
    }

    func testDifferentQuestionIsNewDecision() {
        let (_, c1) = PaneMessageProjector.project(
            outcome: outcome(kind: approval, statusChanged: true, old: .running, new: .waiting),
            config: .default, coalesce: .empty, now: Date())
        let other = NormalizedEventKind.question(
            prompt: "Claude Code requires approval", options: ["1. Yes", "2. Always", "3. No"],
            followups: [])
        let (next, _) = PaneMessageProjector.project(
            outcome: outcome(kind: other, old: .waiting, new: .waiting),
            config: .default, coalesce: c1, now: Date())
        XCTAssertEqual(next.filter { $0.kind == .decision }.count, 1)
    }

    func testToolAliasApplied() {
        var cfg = MessageConfig.default
        cfg.toolAliases = ["run_terminal_cmd": "Shell"]
        let tool = ActivityEvent(tool: "run_terminal_cmd", detail: "ls",
                                 isError: false, timestamp: Date())
        let o = outcome(kind: .toolUse(tool))
        let (evs, _) = PaneMessageProjector.project(
            outcome: o, config: cfg, coalesce: .empty, now: Date())
        XCTAssertEqual(evs.first?.tool, "Shell")
    }
}
