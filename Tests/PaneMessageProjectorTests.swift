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
