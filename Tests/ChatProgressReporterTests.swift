import XCTest
@testable import seahelm

final class ChatProgressReporterTests: XCTestCase {

    private var store: CommandSessionStore!
    private var reporter: ChatProgressReporter!
    private var sent: [(chat: String, text: String)] = []
    private var edited: [(chat: String, id: String, text: String)] = []
    private var removed: [(chat: String, id: String)] = []
    /// What the next send reports back as the message id.
    private var nextMessageId: String? = "100"

    private let paneId = "T1"
    private let sessionKey = "seahelm-task-alpha"
    private var paneKey: String { PaneHandleRegistry.key(sessionKey: sessionKey, paneId: paneId) }

    override func setUp() {
        super.setUp()
        sent = []; edited = []; removed = []; nextMessageId = "100"
        store = CommandSessionStore(url: nil, legacyMailURL: nil)
        reporter = ChatProgressReporter(sessions: store)
        reporter.send = { [weak self] chat, text, done in
            self?.sent.append((chat, text))
            done(self?.nextMessageId)
        }
        reporter.edit = { [weak self] chat, id, text in self?.edited.append((chat, id, text)) }
        reporter.remove = { [weak self] chat, id in self?.removed.append((chat, id)) }
        reporter.identify = { [weak self] _ in self.map { ($0.paneKey, 26) } }
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
        XCTAssertTrue(sent[0].text.contains("Bash — pnpm test"), sent[0].text)

        ingest(working("Read", "main.swift"), at: 30)
        XCTAssertEqual(sent.count, 1, "the line is edited, never re-sent")
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(edited[0].id, "100")
        XCTAssertTrue(edited[0].text.contains("Read — main.swift"), edited[0].text)
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

    // MARK: - The line

    func testTheLineNamesThePaneWhatItIsDoingAndForHowLong() {
        let text = ChatProgressReporter.line(
            for: pane(activity: [tool("Bash", "pnpm test")]), handle: 26,
            since: start, now: start.addingTimeInterval(95))
        XCTAssertTrue(text.contains("#26 alpha/feat-x"), text)
        XCTAssertTrue(text.contains("Bash — pnpm test"), text)
        XCTAssertTrue(text.contains("1m"), text)
    }

    /// A turn that has reported no tool yet is still worth a line — it says the
    /// pane is alive, which is the whole point.
    func testTheLineStandsWithoutAnyToolYet() {
        let text = ChatProgressReporter.line(for: pane(), handle: 3,
                                             since: start, now: start.addingTimeInterval(30))
        XCTAssertTrue(text.contains("#3 alpha/feat-x"), text)
        XCTAssertTrue(text.contains("30s"), text)
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
