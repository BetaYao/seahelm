import XCTest
@testable import seahelm

/// OSC 7501 records (`ProgramStatusStore`) and how the live root record takes
/// part in status arbitration. Spec rules are cited as rev 0.4 sections.
final class ProgramStatusTests: XCTestCase {
    private typealias R = ProgramStatusReport

    // MARK: - Records

    /// "Each report replaces its record entirely": a key not re-sent is gone.
    func testReportReplacesWholeRecord() {
        var store = ProgramStatusStore()
        store.apply(R(state: .blocked, kind: .permission, app: "claude-code", msg: "approve Bash"))
        store.apply(R(state: .working, app: "claude-code"))
        XCTAssertEqual(store.root?.state, .working)
        XCTAssertNil(store.root?.report.kind)
        XCTAssertEqual(store.root?.report.msg, "")
    }

    func testClearWithIdRemovesThatSubtreeOnly() {
        var store = ProgramStatusStore()
        store.apply(R(state: .working, app: "deploy"))
        store.apply(R(state: .working, id: "us-east"))
        store.apply(R(state: .working, id: "us-east/db"))
        store.apply(R(state: .working, id: "us-eastern"))
        store.apply(R(state: .clear, id: "us-east"))
        XCTAssertEqual(Set(store.records.keys), ["", "us-eastern"])
    }

    func testClearWithoutIdRemovesEverything() {
        var store = ProgramStatusStore()
        store.apply(R(state: .working))
        store.apply(R(state: .done, id: "a"))
        XCTAssertTrue(store.apply(R(state: .clear)))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(store.apply(R(state: .clear)), "clearing nothing is not a change")
    }

    /// `app` comes from the nearest ancestor that has one — the root included.
    func testAppIsInheritedFromNearestAncestor() {
        var store = ProgramStatusStore()
        store.apply(R(state: .working, app: "deploy"))
        store.apply(R(state: .working, id: "eu", app: "terraform"))
        store.apply(R(state: .working, id: "eu/vpc"))
        store.apply(R(state: .working, id: "us/vpc"))
        XCTAssertEqual(store.records["eu/vpc"]?.app, "terraform")
        XCTAssertEqual(store.records["us/vpc"]?.app, "deploy")
    }

    /// On a new prompt `working` and `blocked` die (and `idle` may); `done` and
    /// `error` survive but describe a program that is gone, so they stop being live.
    func testPromptReturnedEndsTheProgramsRecords() {
        var store = ProgramStatusStore()
        store.apply(R(state: .done, app: "claude-code"))
        store.apply(R(state: .working, id: "a"))
        store.apply(R(state: .blocked, id: "b"))
        store.apply(R(state: .idle, id: "c"))
        store.apply(R(state: .error, id: "d"))
        XCTAssertNotNil(store.liveRoot)

        store.promptReturned()
        XCTAssertEqual(Set(store.records.keys), ["", "d"])
        XCTAssertNil(store.liveRoot)

        store.apply(R(state: .idle, app: "claude-code"))
        XCTAssertEqual(store.liveRoot?.state, .idle, "a report means a program is running again")
    }

    func testEvictsLeastRecentlyUpdatedPastTheLimit() {
        var store = ProgramStatusStore()
        for i in 0...ProgramStatusStore.maxRecords {
            store.apply(R(state: .working, id: "r\(i)"))
        }
        store.apply(R(state: .working, id: "r0"))   // r0 refreshed, so r1 is the oldest
        store.apply(R(state: .working, id: "extra"))
        XCTAssertEqual(store.records.count, ProgramStatusStore.maxRecords)
        XCTAssertNotNil(store.records["r0"])
        XCTAssertNil(store.records["r1"])
    }

    func testDisplayTextLosesBidiAndInvisibleFormatting() {
        let r = R(state: .blocked, title: "a\u{202E}b", msg: "rm\u{200B} -rf\u{2066}x")
        XCTAssertEqual(r.title, "ab")
        XCTAssertEqual(r.msg, "rm -rfx")
    }

    func testRecordMapsToAgentStatusAndMessage() {
        func record(_ r: R) -> ProgramStatusRecord {
            var store = ProgramStatusStore()
            store.apply(r)
            return store.root!
        }
        XCTAssertEqual(record(R(state: .working)).agentStatus, .running)
        XCTAssertEqual(record(R(state: .blocked)).agentStatus, .waiting)
        XCTAssertEqual(record(R(state: .done)).agentStatus, .idle)
        XCTAssertEqual(record(R(state: .idle)).agentStatus, .idle)
        XCTAssertEqual(record(R(state: .error)).agentStatus, .error)
        XCTAssertEqual(record(R(state: .blocked, kind: .question)).message, "Needs an answer")
        XCTAssertEqual(record(R(state: .blocked, kind: .permission, msg: "approve Bash: ls")).message,
                       "approve Bash: ls")
        XCTAssertEqual(record(R(state: .working)).message, "")
    }

    // MARK: - Arbitration

    /// The program's own statement beats every inference, urgent ones included:
    /// a scan that still shows the permission dialog it just answered is stale.
    func testLiveProgramStatusDecides() {
        let d = AgentRegistry.arbitrateDetailed(scan: .waiting, hook: .error,
                                                agentType: .claudeCode, program: .running)
        XCTAssertEqual(d.status, .running)
        XCTAssertEqual(d.decidedBy, "osc7501")
    }

    func testUnknownProgramStatusLeavesTheOtherRulesAlone() {
        XCTAssertEqual(AgentRegistry.arbitrate(scan: .idle, hook: .running, agentType: .claudeCode,
                                               program: .unknown), .running)
    }

    // MARK: - Ingest

    private let tid = "program-status-t1"

    override func setUp() {
        super.setUp()
        AgentRegistry.shared.registerForTesting(terminalID: tid, worktreePath: "/wt",
                                                branch: "main", project: "proj")
    }

    override func tearDown() {
        AgentRegistry.shared.onOutcome = nil
        let drain = expectation(description: "drain main queue")
        DispatchQueue.main.async { drain.fulfill() }
        wait(for: [drain], timeout: 1)
        AgentRegistry.shared.unregister(terminalID: tid)
        super.tearDown()
    }

    private func ingest(_ report: R?) {
        var store = ProgramStatusStore()
        if let report { store.apply(report) }
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: tid, source: .osc7501,
                                                    kind: .programStatus(store.liveRoot)))
    }

    func testBlockedReportDrivesStatusAndMessageThenYieldsWhenGone() {
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: tid, source: .scan,
            kind: .screenObserved(status: .running, message: "", activity: [], commandLine: nil,
                                  agentType: .claudeCode, roundDuration: 0, tasks: [])))
        ingest(R(state: .blocked, kind: .permission, app: "claude-code", msg: "approve Bash: ls"))
        XCTAssertEqual(AgentRegistry.shared.pane(for: tid)?.status, .waiting)
        XCTAssertEqual(AgentRegistry.shared.pane(for: tid)?.lastMessage, "approve Bash: ls")

        ingest(nil)
        XCTAssertEqual(AgentRegistry.shared.pane(for: tid)?.programStatus, .unknown)
        XCTAssertEqual(AgentRegistry.shared.pane(for: tid)?.status, .running, "back to the scan")
    }

    /// Claude Code's SessionStart hook flips a new pane to running, then its 7501
    /// `idle` lands: that edge is a launch, not a finished turn, and must not
    /// announce itself. A `done` still does.
    func testIdleFromTheProgramIsNotACompletionNotice() {
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: tid, source: .hook("claude-code"),
                                                    kind: .sessionStarted(label: "Session started")))
        ingest(R(state: .idle, app: "claude-code"))
        let pane = AgentRegistry.shared.pane(for: tid)
        XCTAssertEqual(pane?.status, .idle)
        XCTAssertEqual(pane?.programState, .idle)
        XCTAssertTrue(TabCoordinator.programSaysAtRest(newStatus: .idle, programState: pane?.programState))
        XCTAssertFalse(TabCoordinator.programSaysAtRest(newStatus: .idle, programState: .done))
        XCTAssertFalse(TabCoordinator.programSaysAtRest(newStatus: .idle, programState: nil),
                       "without 7501 the other completion rules decide")
        XCTAssertFalse(TabCoordinator.programSaysAtRest(newStatus: .waiting, programState: .idle))
    }

    /// Without hooks, `done` after `working` is the turn's completion; with hooks
    /// the Stop hook already is, and 7501 must not notify a second time.
    func testDoneIsACompletionOnlyWithoutHooks() {
        var outcomes: [IngestOutcome] = []
        let exp = expectation(description: "outcomes")
        exp.expectedFulfillmentCount = 4
        AgentRegistry.shared.onOutcome = { outcomes.append($0); exp.fulfill() }

        ingest(R(state: .working))
        ingest(R(state: .done))
        AgentRegistry.shared.ingest(NormalizedEvent(terminalID: tid, source: .hook("claude-code"),
                                                    kind: .userPrompt("go")))
        ingest(R(state: .working))
        wait(for: [exp], timeout: 2)

        XCTAssertTrue(outcomes[1].isCompletionSignal, "done without hooks completes the turn")
        let again = expectation(description: "done with hooks")
        AgentRegistry.shared.onOutcome = { o in
            XCTAssertFalse(o.isCompletionSignal, "the Stop hook owns completion here")
            again.fulfill()
        }
        ingest(R(state: .done))
        wait(for: [again], timeout: 2)
    }
}
