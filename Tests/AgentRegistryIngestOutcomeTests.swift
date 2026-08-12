import XCTest
@testable import seahelm

final class AgentRegistryIngestOutcomeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentRegistry.shared.registerForTesting(terminalID: "t1", worktreePath: "/wt",
                                          branch: "main", project: "proj")
    }
    override func tearDown() {
        // Stop receiving, then drain any async outcomes still queued on main so they
        // cannot leak into the next test's onOutcome handler (AgentRegistry.shared is a singleton
        // and notifyObservers delivers via DispatchQueue.main.async).
        AgentRegistry.shared.onOutcome = nil
        let drain = expectation(description: "drain main queue")
        DispatchQueue.main.async { drain.fulfill() }
        wait(for: [drain], timeout: 1)
        AgentRegistry.shared.unregister(terminalID: "t1")
        super.tearDown()
    }

    /// Cursor installs a full hook set (`CursorHooksSetup`), so its hook status is
    /// real signal. A `screen_only` authority threw it away, which pinned a working
    /// Cursor pane — and its whole worktree — on Idle whenever a scan frame missed
    /// the spinner.
    func testCursorHookRunningPromotesOverScanIdle() {
        XCTAssertEqual(
            AgentRegistry.arbitrate(scan: .idle, hook: .running, agentType: .cursor), .running,
            "cursor hooks are installed, so a hook running edge must beat a stale scan idle")
    }

    func testCursorManifestIsNotScreenOnly() {
        let authority = ManifestStore.shared.manifest(for: "cursor")?.manifest.authority
        XCTAssertEqual(authority, "session_only",
                       "cursor has real lifecycle hooks; screen_only discards them")
    }

    /// The trailing edge still belongs to the screen: once the scan has seen a
    /// sustained idle past the grace window, a stale hook `.running` is dropped.
    func testCursorScanIdleReclaimsStaleHookRunningAfterGrace() {
        AgentRegistry.hookRunningGrace = 0
        var callCount = 0
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        exp.assertForOverFulfill = false
        AgentRegistry.shared.onOutcome = { o in
            callCount += 1
            if callCount == 2 { captured = o; exp.fulfill() }
        }
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .hook("cursor"),
                                              kind: .userPrompt("do the thing")))
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .scan,
            kind: .screenObserved(status: .idle, message: "", activity: [],
                                  commandLine: nil, agentType: .cursor,
                                  roundDuration: 0, tasks: [])))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.newStatus, .idle)
        AgentRegistry.hookRunningGrace = 3.0
    }

    func testSessionOnlyHookRunningPromotesOverStaleScanIdle() {
        // Leading edge: a hook running edge (prompt submitted) must surface
        // immediately even while the scan still shows the pre-prompt idle prompt —
        // the spinner isn't on screen yet. Within the grace window scan idle does
        // NOT reclaim, so the card flips to running without waiting for the slow scan.
        AgentRegistry.hookRunningGrace = 3.0
        var callCount = 0
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        exp.assertForOverFulfill = false
        AgentRegistry.shared.onOutcome = { o in
            callCount += 1
            if callCount == 2 { captured = o; exp.fulfill() }
        }
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .hook("claude-code"),
                                              kind: .userPrompt("do the thing")))
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .scan,
            kind: .screenObserved(status: .idle, message: "", activity: [],
                                  commandLine: nil, agentType: .claudeCode,
                                  roundDuration: 0, tasks: [])))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.newStatus, .running)
    }

    func testStaleHookRunningReclaimedByScanIdleAfterGrace() {
        // Trailing edge safety: once the grace window has passed (agent genuinely
        // stopped, or Esc/interrupt fired no Stop hook), a scan idle reclaims the
        // status so it does not stick on "running" forever. Grace=0 exercises this
        // deterministically without a wall-clock wait.
        AgentRegistry.hookRunningGrace = 0
        defer { AgentRegistry.hookRunningGrace = 3.0 }
        var callCount = 0
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        exp.assertForOverFulfill = false
        AgentRegistry.shared.onOutcome = { o in
            callCount += 1
            if callCount == 2 { captured = o; exp.fulfill() }
        }
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .hook("claude-code"),
                                              kind: .userPrompt("do the thing")))
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .scan,
            kind: .screenObserved(status: .idle, message: "", activity: [],
                                  commandLine: nil, agentType: .claudeCode,
                                  roundDuration: 0, tasks: [])))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.newStatus, .idle)
    }

    func testUrgentHookSurfacesEvenWhenScreenAuthoritative() {
        // A hook waiting/error must never be hidden by the authority rule.
        var callCount = 0
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        exp.assertForOverFulfill = false
        AgentRegistry.shared.onOutcome = { o in
            callCount += 1
            if callCount == 2 { captured = o; exp.fulfill() }
        }
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .scan,
            kind: .screenObserved(status: .idle, message: "", activity: [],
                                  commandLine: nil, agentType: .claudeCode,
                                  roundDuration: 0, tasks: [])))
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .hook("claude-code"),
                                              kind: .awaitingInput("approve?")))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.newStatus, .waiting)
    }

    func testStaleHookWaitingReclaimedByScanRunningAfterGrace() {
        // The bug: AskUserQuestion sets hook `.waiting`; the user answers in the
        // pane and the agent works for minutes, but the card stays "Needs input".
        // `.waiting` is urgent, so it outranks every scan, and only a hook could
        // clear it — one undelivered clearing hook stranded the card forever.
        // A scan that positively sees the agent working must reclaim it, exactly
        // as a scan `.idle` reclaims a stale hook `.running`.
        AgentRegistry.hookWaitingGrace = 0
        defer { AgentRegistry.hookWaitingGrace = 3.0 }
        var callCount = 0
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        exp.assertForOverFulfill = false
        AgentRegistry.shared.onOutcome = { o in
            callCount += 1
            if callCount == 2 { captured = o; exp.fulfill() }
        }
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .hook("claude-code"),
                                              kind: .question(prompt: "which repo?", options: ["a", "b"], followups: [])))
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .scan,
            kind: .screenObserved(status: .running, message: "", activity: [],
                                  commandLine: nil, agentType: .claudeCode,
                                  roundDuration: 0, tasks: [])))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.newStatus, .running)
    }

    func testHookWaitingHoldsAgainstScanRunningWithinGrace() {
        // Guard the reclaim's other side: PreToolUse(AskUserQuestion) fires before
        // the question has replaced the spinner on screen, so the next scan can
        // still carry a pre-question "running" frame. Within the grace window that
        // stale frame must NOT clear the question.
        AgentRegistry.hookWaitingGrace = 3.0
        var callCount = 0
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        exp.assertForOverFulfill = false
        AgentRegistry.shared.onOutcome = { o in
            callCount += 1
            if callCount == 2 { captured = o; exp.fulfill() }
        }
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .hook("claude-code"),
                                              kind: .question(prompt: "which repo?", options: ["a", "b"], followups: [])))
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .scan,
            kind: .screenObserved(status: .running, message: "", activity: [],
                                  commandLine: nil, agentType: .claudeCode,
                                  roundDuration: 0, tasks: [])))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.newStatus, .waiting)
    }

    func testHookWaitingClearedByNextToolUse() {
        // The happy path that was *supposed* to clear it: the answer is followed by
        // the agent's next tool call, whose PreToolUse asserts running. The leading
        // scan establishes agentType — without it the pane falls back to the generic
        // "agent" manifest (screen_only), which is not the claude path under test.
        var callCount = 0
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        exp.assertForOverFulfill = false
        AgentRegistry.shared.onOutcome = { o in
            callCount += 1
            if callCount == 3 { captured = o; exp.fulfill() }
        }
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .scan,
            kind: .screenObserved(status: .running, message: "", activity: [],
                                  commandLine: nil, agentType: .claudeCode,
                                  roundDuration: 0, tasks: [])))
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .hook("claude-code"),
                                              kind: .question(prompt: "which repo?", options: ["a", "b"], followups: [])))
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .hook("claude-code"),
                                              kind: .toolUse(ActivityEvent(tool: "Bash", detail: "grep",
                                                                           isError: false, timestamp: Date()))))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.newStatus, .running)
    }

    func testScreenObservedCarriesRoundDurationAndTasks() {
        // Regression test for C1/C2: roundDuration and tasks must flow through ingest(.screenObserved)
        let stubTask = TaskItem(id: "t-1", subject: "Write tests", status: .inProgress)
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        AgentRegistry.shared.onOutcome = { o in captured = o; exp.fulfill() }
        AgentRegistry.shared.ingest(NormalizedEvent(
            terminalID: "t1", source: .scan,
            kind: .screenObserved(status: .running, message: "", activity: [],
                                  commandLine: nil, agentType: .claudeCode,
                                  roundDuration: 42.5, tasks: [stubTask])))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.info.roundDuration, 42.5)
        XCTAssertEqual(captured?.info.tasks.count, 1)
        XCTAssertEqual(captured?.info.tasks.first?.id, "t-1")
    }

    func testAgentStoppedFailureIsCompletionWithError() {
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        AgentRegistry.shared.onOutcome = { o in captured = o; exp.fulfill() }
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: "t1", source: .hook("claude-code"),
                                              kind: .agentStopped(success: false)))
        wait(for: [exp], timeout: 2)
        XCTAssertTrue(captured?.isCompletionSignal ?? false)
        XCTAssertEqual(captured?.newStatus, .error)
    }
}
