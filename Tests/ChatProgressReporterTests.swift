import XCTest
@testable import seahelm

final class ChatProgressReporterTests: XCTestCase {

    private var store: CommandSessionStore!
    private var reporter: ChatProgressReporter!
    private var sent: [(chat: String, text: String)] = []
    private var edited: [(chat: String, id: String, text: String)] = []
    private var removed: [(chat: String, id: String)] = []
    private var scheduled: [(delay: TimeInterval, work: (Date) -> Void)] = []
    /// What the next send reports back as the message id.
    private var nextMessageId: String? = "100"

    private let paneId = "T1"
    private let sessionKey = "seahelm-task-alpha"
    private var paneKey: String { PaneHandleRegistry.key(sessionKey: sessionKey, paneId: paneId) }

    override func setUp() {
        super.setUp()
        sent = []; edited = []; removed = []; scheduled = []; nextMessageId = "100"
        store = CommandSessionStore(url: nil, legacyMailURL: nil)
        reporter = ChatProgressReporter(sessions: store)
        reporter.send = { [weak self] chat, text, done in
            self?.sent.append((chat, text))
            done(self?.nextMessageId)
        }
        reporter.edit = { [weak self] chat, id, text in self?.edited.append((chat, id, text)) }
        reporter.remove = { [weak self] chat, id in self?.removed.append((chat, id)) }
        reporter.identify = { [weak self] _ in self.map { ($0.paneKey, 26) } }
        reporter.schedule = { [weak self] delay, work in self?.scheduled.append((delay, work)) }
    }

    // MARK: - Fixtures

    private func bindChat(_ chatId: String) {
        store.bind(CommandSession.key(surface: "telegram", id: chatId),
                   toPaneKey: paneKey, paneId: paneId, worktreePath: "/repo/alpha")
    }

    private func pane(activity: [ActivityEvent] = [], status: AgentStatus = .running) -> PaneInfo {
        var info = PaneInfo(id: paneId, worktreePath: "/repo/alpha", agentType: .claudeCode,
                            project: "alpha", branch: "feat-x", status: status,
                            lastMessage: "", commandLine: nil, roundDuration: 0, startedAt: nil,
                            station: nil, channel: nil, taskProgress: TaskProgress())
        info.activityEvents = activity
        return info
    }

    private func tool(_ name: String, _ detail: String = "") -> ActivityEvent {
        ActivityEvent(tool: name, detail: detail, isError: false, timestamp: Date())
    }

    private func outcome(_ info: PaneInfo, statusChanged: Bool = false,
                         newStatus: AgentStatus = .running, completion: Bool = false) -> IngestOutcome {
        IngestOutcome(info: info, statusChanged: statusChanged, oldStatus: .running,
                      newStatus: newStatus, holdSeconds: 0, isCompletionSignal: completion,
                      event: NormalizedEvent(terminalID: paneId, source: .hook("claude-code"),
                                             kind: .toolUse(tool("Bash"))))
    }

    private func ingest(_ o: IngestOutcome, at offset: TimeInterval) {
        reporter.ingest(o, now: start.addingTimeInterval(offset))
    }

    /// One tool event on a running pane.
    private func working(_ toolName: String = "Bash", _ detail: String = "") -> IngestOutcome {
        outcome(pane(activity: [tool(toolName, detail)]))
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func said(_ text: String, kind: MessageKind = .assistant) -> MessageEvent {
        MessageEvent(seq: 0, paneId: paneId, paneSessionKey: sessionKey, kind: kind, ts: start, text: text)
    }

    private func called(_ tool: String, _ detail: String, failed: Bool = false) -> MessageEvent {
        MessageEvent(seq: 0, paneId: paneId, paneSessionKey: sessionKey, kind: .tool, ts: start,
                     tool: tool, detail: detail, isError: failed)
    }

    private func stream(_ message: MessageEvent, at offset: TimeInterval) {
        reporter.ingest(message, now: start.addingTimeInterval(offset))
    }

    // MARK: - When the line appears

    /// A turn that ends in seconds must leave no trace: posting a line and
    /// taking it back again is worse than never having posted it.
    func testAShortTurnNeverPostsAnything() {
        bindChat("555")
        ingest(working(), at: 0)
        ingest(working("Read"), at: 4)
        ingest(outcome(pane(status: .idle), statusChanged: true, newStatus: .idle), at: 8)
        XCTAssertTrue(sent.isEmpty, "\(sent)")
        XCTAssertTrue(removed.isEmpty)
    }

    func testALongTurnPostsOnceAndThenEditsInPlace() {
        bindChat("555")
        ingest(working("Bash", "pnpm test"), at: 0)
        ingest(working("Bash", "pnpm test"), at: 20)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.chat, "555")
        XCTAssertTrue(sent[0].text.contains("#26 alpha/feat-x"), sent[0].text)
        XCTAssertTrue(sent[0].text.contains("20s"), sent[0].text)

        // Nothing was said either time, so what moves the line on is the clock.
        ingest(working("Read", "main.swift"), at: 30)
        XCTAssertEqual(sent.count, 1, "the line is edited, never re-sent")
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(edited[0].id, "100")
        XCTAssertTrue(edited[0].text.contains("30s"), edited[0].text)
        XCTAssertFalse(edited[0].text.contains("main.swift"), edited[0].text)
    }

    /// Only chats that asked to watch this pane. A fleet listener hears
    /// completions, not a running commentary on every pane in the fleet.
    func testAnUnboundChatGetsNoLine() {
        ingest(working(), at: 0)
        ingest(working(), at: 20)
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - Throttling

    func testEditsAreThrottledAndNeverRepeatTheSameWords() {
        bindChat("555")
        ingest(working(), at: 0)
        ingest(working("Bash", "one"), at: 20)   // posts
        ingest(working("Bash", "two"), at: 21)   // too soon
        XCTAssertTrue(edited.isEmpty, "\(edited)")

        ingest(working("Bash", "two"), at: 24)   // past the window
        XCTAssertEqual(edited.count, 1)

        // Same tool, same second-count: nothing to say, so nothing is said.
        ingest(working("Bash", "two"), at: 24)
        XCTAssertEqual(edited.count, 1)
    }

    // MARK: - When the turn ends

    func testTheLineIsTakenBackWhenTheTurnEnds() {
        bindChat("555")
        ingest(working(), at: 0)
        ingest(working(), at: 20)
        ingest(outcome(pane(status: .idle), statusChanged: true, newStatus: .idle), at: 40)
        XCTAssertEqual(removed.map(\.id), ["100"])

        // And the next turn starts clean rather than editing a message that is gone.
        ingest(working(), at: 100)
        ingest(working(), at: 120)
        XCTAssertEqual(sent.count, 2)
    }

    /// The send is asynchronous. A turn that ends while it is in flight must
    /// still take back the message that lands afterwards.
    func testALineThatArrivesAfterItsTurnEndedIsStillTakenBack() {
        bindChat("555")
        var late: ((String?) -> Void)?
        reporter.send = { [weak self] chat, text, done in
            self?.sent.append((chat, text))
            late = done
        }
        ingest(working(), at: 0)
        ingest(working(), at: 20)
        XCTAssertEqual(sent.count, 1)

        ingest(outcome(pane(status: .idle), statusChanged: true, newStatus: .idle), at: 25)
        XCTAssertTrue(removed.isEmpty, "nothing to take back yet — no id")

        late?("100")
        XCTAssertEqual(removed.map(\.id), ["100"])
    }

    /// A send that reported no id (the bridge was down) must not be edited or
    /// deleted by id later, and must not wedge the pane's line forever.
    func testASendThatFailedDoesNotWedgeTheLine() {
        bindChat("555")
        nextMessageId = nil
        ingest(working(), at: 0)
        ingest(working("Read"), at: 20)
        XCTAssertEqual(sent.count, 1)
        ingest(working("Edit"), at: 30)
        XCTAssertEqual(sent.count, 2, "with no id to edit, the next update posts afresh")
        XCTAssertTrue(edited.isEmpty)
    }

    // MARK: - The stream

    /// The words between tool calls are what a phone could not see before:
    /// the line carries them, and only them — the calls they sit between would
    /// drown them at the width a phone has.
    func testTheLineShowsWhatTheAgentSaidThisTurn() {
        bindChat("555")
        ingest(working(), at: 0)
        stream(said("The server path looks right; checking the client."), at: 5)
        stream(called("Bash", "grep -n pane.event index.html"), at: 6)
        stream(said("It was the client."), at: 7)
        ingest(working(), at: 13)
        XCTAssertEqual(sent.count, 1)
        let text = sent[0].text
        XCTAssertTrue(text.hasPrefix("⏳ **#26 alpha/feat-x** · 13s\n\n"), text)
        XCTAssertTrue(text.hasSuffix("The server path looks right; checking the client.\nIt was the client."), text)
        XCTAssertFalse(text.contains("grep -n"), "a call must not reach the line: \(text)")
    }

    /// A row alone keeps the line current: prose streamed from the transcript
    /// arrives with no outcome of its own.
    func testARowEditsTheLineWithoutWaitingForAnOutcome() {
        bindChat("555")
        ingest(working(), at: 0)
        ingest(working(), at: 13)
        stream(said("Running the full suite now."), at: 20)
        XCTAssertEqual(edited.count, 1)
        XCTAssertTrue(edited[0].text.hasSuffix("Running the full suite now."), edited[0].text)
    }

    /// The reply that closed the last turn is streamed after its Stop. It must
    /// not open the next turn's line.
    func testRowsOutsideATurnAreNotShown() {
        bindChat("555")
        stream(said("Last turn's answer."), at: 0)
        ingest(working(), at: 1)
        stream(said("New work."), at: 2)
        ingest(working(), at: 14)
        XCTAssertEqual(sent.count, 1)
        XCTAssertFalse(sent[0].text.contains("Last turn's answer."), sent[0].text)
        XCTAssertTrue(sent[0].text.contains("New work."), sent[0].text)

        ingest(outcome(pane(), completion: true), at: 20)
        stream(said("Final reply."), at: 20)
        ingest(working(), at: 30)
        ingest(working(), at: 43)
        XCTAssertEqual(sent.count, 2)
        XCTAssertFalse(sent[1].text.contains("New work."), "each turn starts clean: \(sent[1].text)")
        XCTAssertFalse(sent[1].text.contains("Final reply."), sent[1].text)
    }

    func testOnlyTheLatestRowsAreShown() {
        bindChat("555")
        ingest(working(), at: 0)
        for n in 1...8 { stream(said("step \(n) done"), at: 1) }
        ingest(working(), at: 13)
        let text = sent[0].text
        XCTAssertFalse(text.contains("step 2 done"), text)
        for n in 3...8 { XCTAssertTrue(text.contains("step \(n) done"), text) }
    }

    /// A row that lands inside the throttle is not dropped: it goes up once the
    /// interval is over, even if nothing else happens — a long build is quiet.
    func testAHeldBackRowIsPutUpWhenTheIntervalIsOver() {
        bindChat("555")
        ingest(working(), at: 0)
        ingest(working(), at: 13)
        stream(said("Building."), at: 14)
        stream(said("Now the tests."), at: 15)
        XCTAssertTrue(edited.isEmpty)
        XCTAssertEqual(scheduled.count, 1, "one flush per pane, however many rows it holds")
        scheduled[0].work(start.addingTimeInterval(16))
        XCTAssertEqual(edited.count, 1)
        guard edited.count == 1 else { return }
        XCTAssertTrue(edited[0].text.hasSuffix("Building.\nNow the tests."), edited[0].text)
    }

    func testAFlushAfterTheTurnEndedPutsNothingUp() {
        bindChat("555")
        ingest(working(), at: 0)
        ingest(working(), at: 13)
        stream(called("Bash", "make"), at: 14)
        ingest(outcome(pane(status: .idle), statusChanged: true, newStatus: .idle), at: 15)
        scheduled.forEach { $0.work(start.addingTimeInterval(16)) }
        XCTAssertTrue(edited.isEmpty)
        XCTAssertEqual(removed.count, 1)
    }

    func testRowsAreWhatTheAgentSaidAndNothingElse() {
        XCTAssertEqual(ChatProgressReporter.row(for: said("  Looking at it.\n")), "Looking at it.")
        XCTAssertEqual(ChatProgressReporter.row(for: said("Weighing it.", kind: .thinking)), "Weighing it.")
        let long = ChatProgressReporter.row(for: said("a\nb " + String(repeating: "x", count: 300)))
        XCTAssertEqual(long?.count, 200)
        for kind: MessageKind in [.user, .status, .decision, .notice] {
            XCTAssertNil(ChatProgressReporter.row(for: said("x", kind: kind)), kind.rawValue)
        }
    }

    /// Tool calls drowned the sentence they were context for: four truncated
    /// shell commands around the one line that was the point. They stay on the
    /// timeline, where there is room to read them.
    func testAToolCallIsNotALineOfTheProgressMessage() {
        XCTAssertNil(ChatProgressReporter.row(for: called("Bash", "ls")))
        XCTAssertNil(ChatProgressReporter.row(for: called("Bash", "false", failed: true)))
    }

    // MARK: - The line

    func testTheLineNamesThePaneAndForHowLong() {
        let text = ChatProgressReporter.line(
            for: pane(), handle: 26, feed: ["Running the tests."],
            since: start, now: start.addingTimeInterval(95))
        XCTAssertTrue(text.contains("#26 alpha/feat-x"), text)
        XCTAssertTrue(text.contains("Running the tests."), text)
        XCTAssertTrue(text.contains("1m"), text)
    }

    /// A turn that has said nothing yet is still worth a line — it says the
    /// pane is alive and for how long, which is the whole point.
    func testTheLineStandsWithNothingSaidYet() {
        let text = ChatProgressReporter.line(for: pane(), handle: 3,
                                             since: start, now: start.addingTimeInterval(30))
        XCTAssertTrue(text.contains("#3 alpha/feat-x"), text)
        XCTAssertTrue(text.contains("30s"), text)
    }

    /// Screen-scanned activity was the same tool noise arriving by another
    /// road, and it filled the gap the head is meant to describe.
    func testScannedToolActivityNoLongerFillsTheLine() {
        let text = ChatProgressReporter.line(
            for: pane(activity: [tool("Bash", "pnpm test")]), handle: 26,
            since: start, now: start.addingTimeInterval(95))
        XCTAssertFalse(text.contains("pnpm test"), text)
    }

    /// Whole units only: a line that ticks every second is a message edit every
    /// second, and Telegram would rightly refuse most of them.
    func testElapsedIsCoarse() {
        XCTAssertEqual(ChatProgressReporter.elapsed(0.4), "0s")
        XCTAssertEqual(ChatProgressReporter.elapsed(59.9), "59s")
        XCTAssertEqual(ChatProgressReporter.elapsed(60), "1m")
        XCTAssertEqual(ChatProgressReporter.elapsed(3_600), "1h0m")
        XCTAssertEqual(ChatProgressReporter.elapsed(3_930), "1h5m")
    }

    func testAToolDetailIsFlattenedAndCut() {
        let long = ChatProgressReporter.truncated("a\nb " + String(repeating: "x", count: 200))
        XCTAssertFalse(long.contains("\n"))
        XCTAssertEqual(long.count, 120)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    // MARK: - When a turn is over

    func testEveryWayATurnStopsEndsTheLine() {
        XCTAssertTrue(ChatProgressReporter.endsTurn(outcome(pane(), completion: true)))
        for status: AgentStatus in [.idle, .waiting, .error] {
            XCTAssertTrue(ChatProgressReporter.endsTurn(
                outcome(pane(), statusChanged: true, newStatus: status)), status.rawValue)
        }
    }

    /// Still working is not the end of anything, and neither is a status that
    /// was re-reported rather than changed.
    func testWorkingOnDoesNotEndTheLine() {
        XCTAssertFalse(ChatProgressReporter.endsTurn(outcome(pane())))
        XCTAssertFalse(ChatProgressReporter.endsTurn(
            outcome(pane(), statusChanged: false, newStatus: .idle)))
    }
}
