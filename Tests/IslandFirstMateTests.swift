import XCTest
@testable import seahelm

/// The island's shared First Mate and card timeline.
final class IslandFirstMateTests: XCTestCase {
    private func order(_ id: String, kind: Card.Kind = .suggestion) -> Card {
        Card(id: id, kind: kind, terminalID: "t", worktreePath: "/w", message: "Next?", options: ["go"])
    }

    func testUserOpenStartsUnfilteredAtTheBottom() {
        let model = IslandModel()
        model.orders = [order("a", kind: .question)]
        model.open(reason: .click)
        XCTAssertFalse(model.isFilteringTimeline)
        XCTAssertNil(model.timelineScrollTarget)
        XCTAssertTrue(model.isOpened)
    }

    func testTheLastWaitingCardTurnsOffTheFilterWithoutChangingTheTimeline() {
        let model = IslandModel()
        model.open(reason: .click)
        model.orders = [order("a", kind: .question)]
        model.toggleTimelineFilter()
        XCTAssertTrue(model.isFilteringTimeline)
        model.orders = []
        XCTAssertFalse(model.isFilteringTimeline)
        XCTAssertTrue(model.isOpened)
        XCTAssertFalse(model.pendingCommandFocus)
    }

    func testEscapeClearsTheFilterThenCloses() {
        let model = IslandModel()
        model.orders = [order("a", kind: .question)]
        model.open(reason: .click)
        model.toggleTimelineFilter()
        XCTAssertTrue(model.escape())
        XCTAssertFalse(model.isFilteringTimeline)
        XCTAssertTrue(model.isOpened)
        XCTAssertTrue(model.escape())
        XCTAssertFalse(model.isOpened)
        XCTAssertFalse(model.escape())
    }

    func testSendingTurnsOffFilterAndReturnsToTimelineBottom() {
        let model = IslandModel()
        model.orders = [order("a", kind: .question)]
        model.open(reason: .click)
        model.toggleTimelineFilter()
        model.didSendMessage()
        XCTAssertFalse(model.isFilteringTimeline)
        XCTAssertNil(model.timelineScrollTarget)
    }

    func testTimelineRefreshDoesNotRequestScrollWhenUserIsNotAtBottom() {
        let model = IslandModel()
        model.open(reason: .click)
        let requestBeforeRefresh = model.timelineScrollRequest

        model.timelineDidRefresh(previousScrollIDs: ["user:1"],
                                 currentScrollIDs: ["user:1", "assistant:2"],
                                 isAtBottom: false)

        XCTAssertEqual(model.timelineScrollRequest, requestBeforeRefresh)
    }

    func testTimelineRefreshFollowsNewRowsOnlyWhenAlreadyAtBottom() {
        let model = IslandModel()
        model.open(reason: .click)
        let requestBeforeRefresh = model.timelineScrollRequest

        model.timelineDidRefresh(previousScrollIDs: ["user:1"],
                                 currentScrollIDs: ["user:1", "assistant:2"],
                                 isAtBottom: true)
        XCTAssertEqual(model.timelineScrollRequest, requestBeforeRefresh + 1)

        model.timelineDidRefresh(previousScrollIDs: ["user:1", "assistant:2"],
                                 currentScrollIDs: ["user:1", "assistant:2"],
                                 isAtBottom: true)
        XCTAssertEqual(model.timelineScrollRequest, requestBeforeRefresh + 1)
    }

    func testAutoOpenTargetsAndHighlightsTheNewCard() {
        let model = IslandModel()
        model.open(reason: .event, targetCardID: "new-card")
        XCTAssertFalse(model.isFilteringTimeline)
        XCTAssertEqual(model.timelineScrollTarget, "card:new-card")
        XCTAssertEqual(model.timelineHighlightCardID, "new-card")
        XCTAssertEqual(model.consumeTimelineHighlightCardID(), "new-card")
        XCTAssertNil(model.consumeTimelineHighlightCardID())
        model.close()
        model.open(reason: .click)
        XCTAssertNil(model.timelineScrollTarget)
        XCTAssertNil(model.timelineHighlightCardID)
    }

    func testOpenedHeightUsesSixtyPercentWithFiveHundredTwentyMinimum() {
        XCTAssertEqual(IslandModel.openedContentHeight(forVisibleHeight: 700), 520)
        XCTAssertEqual(IslandModel.openedContentHeight(forVisibleHeight: 1_000), 600)
        let measured = IslandModel.openedContentHeight(forVisibleHeight: 700, chromeHeight: 245)
        XCTAssertEqual(measured, 625)
        XCTAssertGreaterThanOrEqual(measured - 245, IslandModel.minimumTimelineHeight)
    }

    func testIslandLanguageComesFromFirstMateConfigAndDefaultsToEnglish() {
        XCTAssertEqual(IslandLanguage.fromConfigData(Data(#"{"first_mate_language":"zh"}"#.utf8)), .chinese)
        XCTAssertEqual(IslandLanguage.fromConfigData(Data(#"{"first_mate_language":"en"}"#.utf8)), .english)
        XCTAssertEqual(IslandLanguage.fromConfigData(Data(#"{"first_mate_language":"fr"}"#.utf8)), .english)
        XCTAssertEqual(IslandLanguage.fromConfigData(nil), .english)
        XCTAssertEqual(IslandLanguage.chinese.todoCount(2), "待办 2")
        XCTAssertEqual(IslandLanguage.english.composerPlaceholder, "Ask First Mate — / for a command")
    }

    func testFilterVisibilityFollowsWaitingCountAndSuggestionsDoNotCount() {
        let model = IslandModel()
        XCTAssertFalse(model.shouldShowTimelineFilter)
        model.orders = [order("suggestion")]
        XCTAssertEqual(model.pendingCardCount, 0)
        XCTAssertFalse(model.shouldShowTimelineFilter)
        model.orders = [order("suggestion"), order("question", kind: .question)]
        XCTAssertEqual(model.pendingCardCount, 1)
        XCTAssertTrue(model.shouldShowTimelineFilter)
    }

    func testCmdJFocusKeepsTheOpenIslandAndReturnsToTheBottom() {
        let model = IslandModel()
        model.orders = [order("question", kind: .question)]
        model.open(reason: .click)
        model.toggleTimelineFilter()
        model.focusFirstMateComposer()
        XCTAssertTrue(model.isOpened)
        XCTAssertFalse(model.isFilteringTimeline)
        XCTAssertTrue(model.pendingCommandFocus)
        XCTAssertNil(model.timelineScrollTarget)
    }

    func testTimelineRevisionTracksMessageAndCardInputs() {
        let model = IslandModel()
        let messages = [MessageEvent(seq: 1, paneId: "fm", paneSessionKey: "k", kind: .user,
                                    ts: Date(timeIntervalSince1970: 1), text: "hello")]
        model.mateMessages = messages
        XCTAssertEqual(model.timelineRevision, 1)
        model.mateMessages = messages
        XCTAssertEqual(model.timelineRevision, 1)
        model.orders = [order("card", kind: .question)]
        XCTAssertEqual(model.timelineRevision, 2)
        model.liveCardSourceLabels = ["card": "#7 · saas-mono"]
        XCTAssertEqual(model.timelineRevision, 3)
    }

    func testCardFixtureRowsDecodeAndMergeAtTheirFirstPosition() throws {
        let opened: [String: Any] = [
            "seq": 10, "pane_id": "fm", "pane_session_key": "seahelm-first-mate",
            "kind": "card", "ts": 100.0, "card_id": "c-1", "card_kind": "approval",
            "source": ["pane": "#7", "label": "#7 · saas-mono"],
            "text": "Delete 3 worktrees", "options": ["Approve", "Keep"], "state": "pending",
        ]
        let answered: [String: Any] = [
            "seq": 13, "pane_id": "fm", "pane_session_key": "seahelm-first-mate",
            "kind": "card", "ts": 102.0, "card_id": "c-1", "state": "answered",
            "option": "Approve", "via": "island",
        ]
        let messages = try XCTUnwrap([opened, answered].compactMap { MessageEvent(dict: $0) })
        XCTAssertEqual(messages[0].cardSourceLabel, "#7 · saas-mono")
        XCTAssertEqual(messages[0].cardOptions, ["Approve", "Keep"])
        XCTAssertEqual(messages[1].cardState, .answered)
        let roundTrip = try XCTUnwrap(MessageEvent(dict: messages[0].dict))
        XCTAssertEqual(roundTrip.cardId, "c-1")
        XCTAssertEqual(roundTrip.cardSourcePane, "#7")
        XCTAssertEqual(roundTrip.cardState, .pending)
        let items = ConversationItem.items(from: [
            MessageEvent(seq: 9, paneId: "fm", paneSessionKey: "k", kind: .user, ts: Date(timeIntervalSince1970: 99), text: "Review"),
            messages[0], messages[1],
        ])
        let cards = items.compactMap { item -> CardTimelineEntry? in
            guard case let .card(entry) = item.kind else { return nil }
            return entry
        }
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].sequence, 10)
        XCTAssertEqual(cards[0].state, .answered)
        XCTAssertEqual(cards[0].option, "Approve")
        XCTAssertEqual(cards[0].via, "island")
        XCTAssertEqual(items.map(\.id), [9, 10])
    }

    func testDecisionReplyIsNotDuplicatedBesideItsLiveFirstMateCard() throws {
        let card = try XCTUnwrap(Card(json: [
            "id": "fm-choice", "kind": "suggestion", "pane_session_key": FirstMatePane.sessionName,
            "project": "seahelm", "message": "Choose the next step", "options": ["Approve", "Keep"],
        ], terminalID: { _, _ in "fm" }))
        let reply = MessageEvent(seq: 12, paneId: "fm", paneSessionKey: FirstMatePane.sessionName,
                                 kind: .decision, ts: Date(), text: "Approve · Keep")
        let items = ConversationItem.items(from: [reply], liveCards: [card])
        XCTAssertEqual(items.count, 1)
        guard case let .card(entry) = items[0].kind else {
            return XCTFail("The live First Mate card should replace the decision chips")
        }
        XCTAssertEqual(entry.id, "fm-choice")
        XCTAssertEqual(entry.sourceLabel, "First Mate")

        var row = MessageEvent(seq: 11, paneId: "fm", paneSessionKey: FirstMatePane.sessionName,
                               kind: .card, ts: Date(), text: card.message)
        row.cardId = card.id
        row.cardKind = card.kind.rawValue
        row.cardSourceLabel = "First Mate"
        row.cardOptions = card.options
        row.cardState = .pending
        let itemsWithRow = ConversationItem.items(from: [row, reply], liveCards: [card])
        XCTAssertEqual(itemsWithRow.count, 1)
        guard case let .card(rowEntry) = itemsWithRow[0].kind else {
            return XCTFail("The durable card row should replace the matching decision chips")
        }
        XCTAssertEqual(rowEntry.id, card.id)
    }

    func testLiveCardUsesFleetSourceLabelBeforeItsTimelineRowArrives() throws {
        let card = try XCTUnwrap(Card(json: [
            "id": "pane-question", "kind": "question", "pane_session_key": "pane-session",
            "project": "saas-mono", "branch": "feature/island", "worktree_path": "/repo/worktrees/island",
            "message": "Pick one", "options": ["A", "B"],
        ], terminalID: { _, _ in "pane-id" }))
        let items = ConversationItem.items(from: [], liveCards: [card],
                                           sourceLabels: [card.id: "#7 · saas-mono"])
        guard case let .card(entry) = try XCTUnwrap(items.first).kind else {
            return XCTFail("Expected a live card row")
        }
        XCTAssertEqual(entry.sourceLabel, "#7 · saas-mono")
        let fallback = ConversationItem.items(from: [], liveCards: [card])
        guard case let .card(fallbackEntry) = try XCTUnwrap(fallback.first).kind else {
            return XCTFail("Expected a fallback live card row")
        }
        XCTAssertEqual(fallbackEntry.sourceLabel, "feature/island")
    }

    func testLiveCardBodyRevealNavigatesToItsPaneButFirstMateCardsStayInTheTimeline() throws {
        let worktreeCard = try XCTUnwrap(Card(json: [
            "id": "worktree-question", "kind": "question", "pane_session_key": "worktree-pane",
            "project": "seahelm", "worktree_path": "/repo/worktrees/feature", "message": "Pick one",
            "options": ["A", "B"],
        ], terminalID: { _, _ in "terminal-7" }))
        let firstMateCard = try XCTUnwrap(Card(json: [
            "id": "first-mate-proposal", "kind": "proposal", "pane_session_key": FirstMatePane.sessionName,
            "project": "seahelm", "message": "Choose a next step", "options": ["Continue", "Stop"],
        ], terminalID: { _, _ in "first-mate" }))

        let model = IslandModel()
        var revealed: [Card] = []
        model.onRevealCardSource = { revealed.append($0) }
        model.open(reason: .click)
        model.revealCard(worktreeCard)
        XCTAssertEqual(revealed.map(\.id), [worktreeCard.id])
        XCTAssertFalse(model.isOpened, "A worktree card returns to its pane in the dashboard")

        model.orders = [order("pending", kind: .question)]
        model.open(reason: .click)
        model.toggleTimelineFilter()
        let requestBeforeReveal = model.timelineScrollRequest
        model.revealCard(firstMateCard)
        XCTAssertEqual(revealed.map(\.id), [worktreeCard.id], "First Mate cards do not navigate to a worktree")
        XCTAssertTrue(model.isOpened)
        XCTAssertFalse(model.isFilteringTimeline)
        XCTAssertNil(model.timelineScrollTarget, "The First Mate conversation is shown at its bottom")
        XCTAssertEqual(model.timelineScrollRequest, requestBeforeReveal + 1)
    }

    func testWaitingCardMessageFoldsToThreeLinesAndSuggestionsUseCompactOptions() {
        let longMessage = (1...20).map { "Final message line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(OpenedSurfaceView.cardPreviewLines, 3)
        XCTAssertTrue(OpenedSurfaceView.cardMessageNeedsExpansion(longMessage))
        XCTAssertFalse(OpenedSurfaceView.cardMessageNeedsExpansion("Choose the next step"))
        XCTAssertEqual(IslandCardOptionStyle.forKind(.suggestion), .compactChips)
        XCTAssertEqual(IslandCardOptionStyle.forKind(.question), .fullWidthRows)
        XCTAssertEqual(IslandCardOptionStyle.forKind(.choice), .fullWidthRows)
        XCTAssertEqual(IslandCardOptionStyle.forKind(.approval), .fullWidthRows)
    }

    func testFleetCardSourceLabelUsesWorktreeNameInsteadOfProject() {
        let path = "/repo/worktrees/island-timeline"
        let pane = PaneRef(handle: 7, id: "pane-id", sessionKey: "pane-session",
                           project: "seahelm", branch: "feature/island-timeline", worktreePath: path,
                           type: "Claude", title: "Timeline")
        let worktree = WorktreeRef(repo: "seahelm", branch: pane.branch, path: path)
        let index = FleetIndex(panes: [pane], worktrees: [worktree])
        XCTAssertEqual(index.cardSourceLabel(for: pane), "#7 · feature/island-timeline")

        let detached = PaneRef(handle: nil, id: "detached", project: "seahelm", branch: "",
                               worktreePath: "/repo/worktrees/review", type: "Claude", title: "Review")
        XCTAssertEqual(FleetIndex(panes: [detached]).cardSourceLabel(for: detached), "review")
    }

    func testCardStatesRenderAsAnsweredOrQuietHistory() throws {
        func fixture(_ id: String, _ state: String, option: String? = nil) -> MessageEvent {
            var row: [String: Any] = [
                "seq": 1, "pane_id": "fm", "pane_session_key": "k", "kind": "card", "ts": 10.0,
                "card_id": id, "card_kind": "approval", "source": ["label": "First Mate"],
                "text": "Delete worktree", "state": state,
            ]
            if let option { row["option"] = option }
            return MessageEvent(dict: row)!
        }
        let rows = [fixture("answered", "answered", option: "Approve"),
                    fixture("expired", "expired"), fixture("gone", "gone"), fixture("dismissed", "dismissed")]
        let entries = CardTimelineEntry.merged(from: rows)
        XCTAssertEqual(entries.map(\.state), [.answered, .expired, .gone, .dismissed])
        var answered = entries[0]
        answered.updatedAt = .distantPast
        XCTAssertEqual(OpenedSurfaceView.cardSummary(answered, now: Date(timeIntervalSince1970: 10), isChinese: false),
                       "✓ You chose Approve: Delete worktree")
        answered.via = "telegram"
        XCTAssertEqual(OpenedSurfaceView.cardSummary(answered, now: Date(timeIntervalSince1970: 10), isChinese: false),
                       "✓ Chose Approve on Telegram: Delete worktree")
        XCTAssertEqual(OpenedSurfaceView.cardSummary(answered, now: Date(timeIntervalSince1970: 10), isChinese: true),
                       "✓ 在 Telegram 选择了「Approve」：Delete worktree")
        XCTAssertTrue(OpenedSurfaceView.cardSummary(entries[1], now: Date(timeIntervalSince1970: 10), isChinese: false).contains("expired"))
        XCTAssertTrue(OpenedSurfaceView.cardSummary(entries[2], now: Date(timeIntervalSince1970: 10), isChinese: true).contains("已结束"))
        XCTAssertTrue(OpenedSurfaceView.cardSummary(entries[3], now: Date(timeIntervalSince1970: 10), isChinese: false).contains("dismissed"))
        let pending = CardTimelineEntry.merged(from: [fixture("pending", "pending")])[0]
        XCTAssertEqual(pending.effectiveState(liveCard: order("pending", kind: .approval)), .pending)
        XCTAssertEqual(pending.effectiveState(liveCard: nil), .gone)
    }

    func testFilterKeepsWaitingCardsAndCollapsesHiddenRuns() {
        func message(_ seq: UInt64, _ kind: MessageKind, text: String? = nil) -> MessageEvent {
            MessageEvent(seq: seq, paneId: "fm", paneSessionKey: "k", kind: kind,
                         ts: Date(timeIntervalSince1970: Double(seq)), text: text)
        }
        func cardRow(_ seq: UInt64, _ id: String, _ kind: String) -> MessageEvent {
            var event = message(seq, .card, text: "Card \(id)")
            event.cardId = id
            event.cardKind = kind
            event.cardSourceLabel = "First Mate"
            event.cardState = .pending
            event.cardOptions = ["Yes", "No"]
            return event
        }
        let live = [order("todo-1", kind: .question), order("suggestion"), order("todo-2", kind: .approval)]
        let items = ConversationItem.items(from: [
            message(1, .user, text: "Old prompt"), cardRow(2, "todo-1", "question"),
            message(3, .assistant, text: "Old reply"), cardRow(4, "suggestion", "suggestion"),
            message(5, .note, text: "Hidden note"), cardRow(6, "todo-2", "approval"),
        ], liveCards: live)
        let rows = OpenedSurfaceView.timelineRows(from: items, filtering: true, liveCards: live)
        let shownCardIDs = rows.compactMap { row -> String? in
            guard case let .item(item) = row.kind, case let .card(card) = item.kind else { return nil }
            return card.id
        }
        XCTAssertEqual(shownCardIDs, ["todo-1", "suggestion", "todo-2"])
        let collapsed = rows.compactMap { row -> [ConversationItem]? in
            guard case let .collapsedMessages(items) = row.kind else { return nil }
            return items
        }
        XCTAssertEqual(collapsed.map { $0.map(\.messageCount) }, [[1], [1], [1]])

        let afterPaneTyping = OpenedSurfaceView.timelineRows(
            from: items, filtering: false, liveCards: live.filter { $0.id != "suggestion" }
        )
        XCTAssertFalse(afterPaneTyping.contains { row in
            guard case let .item(item) = row.kind, case let .card(card) = item.kind else { return false }
            return card.id == "suggestion"
        })
    }

    func testCollapsedMessageRunKeepsItsIdentityWhenMoreMessagesArrive() throws {
        func user(_ seq: UInt64, _ text: String) -> MessageEvent {
            MessageEvent(seq: seq, paneId: "fm", paneSessionKey: "k", kind: .user,
                         ts: Date(timeIntervalSince1970: Double(seq)), text: text)
        }
        func waitingCard(_ seq: UInt64) -> MessageEvent {
            var event = MessageEvent(seq: seq, paneId: "fm", paneSessionKey: "k", kind: .card,
                                     ts: Date(timeIntervalSince1970: Double(seq)), text: "Wait")
            event.cardId = "wait"
            event.cardKind = "question"
            event.cardState = .pending
            return event
        }
        let live = [order("wait", kind: .question)]
        let before = ConversationItem.items(from: [user(1, "one"), user(2, "two"), waitingCard(3)], liveCards: live)
        let after = ConversationItem.items(from: [user(1, "one"), user(2, "two"), user(3, "three"), waitingCard(4)], liveCards: live)
        let beforeRun = try XCTUnwrap(OpenedSurfaceView.timelineRows(from: before, filtering: true, liveCards: live).first)
        let afterRun = try XCTUnwrap(OpenedSurfaceView.timelineRows(from: after, filtering: true, liveCards: live).first)
        XCTAssertEqual(beforeRun.id, "messages:event:1")
        XCTAssertEqual(afterRun.id, beforeRun.id)
    }

    func testTodoCountExcludesSuggestionsAndFourSuggestionsFoldBehindMore() {
        let model = IslandModel()
        model.orders = [order("s1"), order("q1", kind: .question), order("s2"), order("q2", kind: .approval)]
        XCTAssertEqual(model.pendingCardCount, 2)

        var rows: [MessageEvent] = []
        let suggestions = (1...4).map { order("suggestion-\($0)") }
        for (index, card) in suggestions.enumerated() {
            var row = MessageEvent(seq: UInt64(index + 1), paneId: "fm", paneSessionKey: "k", kind: .card,
                                   ts: Date(timeIntervalSince1970: Double(index)), text: card.message)
            row.cardId = card.id
            row.cardKind = card.kind.rawValue
            row.cardState = .pending
            rows.append(row)
        }
        let items = ConversationItem.items(from: rows, liveCards: suggestions)
        let display = OpenedSurfaceView.timelineRows(from: items, filtering: false, liveCards: suggestions)
        XCTAssertEqual(display.filter { if case .moreSuggestions = $0.kind { return true }; return false }.count, 1)
        XCTAssertEqual(display.compactMap { row -> String? in
            guard case let .item(item) = row.kind, case let .card(card) = item.kind else { return nil }
            return card.id
        }.count, 3)
    }

    func testConversationFoldsToolRunsAndLeavesTurnEdgesOut() {
        func m(_ seq: UInt64, _ kind: MessageKind, text: String? = nil, tool: String? = nil, status: String? = nil) -> MessageEvent {
            var e = MessageEvent(seq: seq, paneId: "fm", paneSessionKey: "seahelm-first-mate", kind: kind, ts: Date(), text: text)
            e.tool = tool
            e.status = status
            return e
        }
        let items = ConversationItem.items(from: [
            m(1, .user, text: "Anything red?"),
            m(2, .status, status: "Running"),
            m(3, .thinking, text: "Checking CI"),
            m(4, .tool, tool: "Bash"), m(5, .tool, tool: "Bash"), m(6, .tool, tool: "Read"),
            m(7, .assistant, text: "PR #12 is red: a flaky test."),
            m(8, .status, status: "Idle"),
            m(9, .status, status: "Error"),
        ])
        // The calls fold into the reply they led to, not a row of their own.
        XCTAssertEqual(items.map(\.kind), [
            .user("Anything red?"), .thinking("Checking CI"),
            .assistant("PR #12 is red: a flaky test.", tools: "Bash ×2 · Read"), .note("Stopped with an error"),
        ])
    }

    /// Calls with no reply after them yet are the turn still going: one row,
    /// keyed by its first call so it stays put as it grows.
    func testTrailingToolRunIsItsOwnRow() {
        let items = ConversationItem.items(from: [
            MessageEvent(seq: 1, paneId: "fm", paneSessionKey: "k", kind: .user, ts: Date(), text: "Check CI"),
            { var e = MessageEvent(seq: 2, paneId: "fm", paneSessionKey: "k", kind: .tool, ts: Date(), text: nil); e.tool = "Bash"; return e }(),
            { var e = MessageEvent(seq: 3, paneId: "fm", paneSessionKey: "k", kind: .tool, ts: Date(), text: nil); e.tool = "Bash"; return e }(),
        ])
        XCTAssertEqual(items.map(\.kind), [.user("Check CI"), .tools("Bash ×2")])
        XCTAssertEqual(items[1].id, 2)
    }

    /// First Mate's suggestion reads as its options, drawn as buttons.
    func testASuggestionIsADecision() {
        let items = ConversationItem.items(from: [
            MessageEvent(seq: 1, paneId: "fm", paneSessionKey: "k", kind: .decision, ts: Date(), text: "Approve delete · Keep worktree"),
            MessageEvent(seq: 2, paneId: "fm", paneSessionKey: "k", kind: .decision, ts: Date(), text: "Which repo?"),
        ])
        XCTAssertEqual(items.map(\.kind), [.decision(["Approve delete", "Keep worktree"]), .note("Which repo?")])
    }

    /// A line seahelm-core wrote itself (a sweep report) is a note, its ` · `
    /// kept: not buttons.
    func testACoreNoteIsOneLineOfNote() {
        let text = "Deleted 2 worktrees by habit: a (delete-merged-clean) · b (delete-merged-clean). Branches kept."
        let items = ConversationItem.items(from: [
            MessageEvent(seq: 1, paneId: "fm", paneSessionKey: "k", kind: .note, ts: Date(), text: text),
        ])
        XCTAssertEqual(items.map(\.kind), [.note(text)])
        XCTAssertEqual(MessageEvent(dict: ["seq": 1, "pane_id": "fm", "kind": "note", "ts": 1.0, "text": text])?.kind, .note)
    }

    /// Activity in the app's windows reaches the core at most once a minute.
    func testActivityIsReportedAtMostOnceAMinute() {
        var t = ActivityThrottle()
        let start = Date()
        XCTAssertTrue(t.shouldReport(at: start))
        XCTAssertFalse(t.shouldReport(at: start.addingTimeInterval(30)))
        XCTAssertFalse(t.shouldReport(at: start.addingTimeInterval(59.9)))
        XCTAssertTrue(t.shouldReport(at: start.addingTimeInterval(60)))
    }

    /// The daily brief is one block, its lines kept.
    func testTheBriefIsOneBlock() {
        let text = "First Mate · daily brief · away 13 h\nDone: deleted 3 worktrees by habit — a · b · c\nWaiting on you (1 card): these 2 worktrees look done:"
        let items = ConversationItem.items(from: [
            MessageEvent(seq: 1, paneId: "fm", paneSessionKey: "k", kind: .brief, ts: Date(), text: text),
        ])
        XCTAssertEqual(items.map(\.kind), [.brief(text)])
        XCTAssertEqual(MessageEvent(dict: ["seq": 1, "pane_id": "fm", "kind": "brief", "ts": 1.0, "text": text])?.kind, .brief)
    }

    /// A suggestion is recorded before the reply it closes; it goes under it.
    func testASuggestionGoesUnderItsReply() {
        let items = ConversationItem.items(from: [
            MessageEvent(seq: 1, paneId: "fm", paneSessionKey: "k", kind: .user, ts: Date(), text: "[seahelm event] pr.merged · rule cleanup-merged"),
            MessageEvent(seq: 2, paneId: "fm", paneSessionKey: "k", kind: .decision, ts: Date(), text: "Delete · Keep"),
            MessageEvent(seq: 3, paneId: "fm", paneSessionKey: "k", kind: .assistant, ts: Date(), text: "Safe to delete."),
            MessageEvent(seq: 4, paneId: "fm", paneSessionKey: "k", kind: .decision, ts: Date(), text: "A · B"),
        ])
        XCTAssertEqual(items.map(\.id), [1, 3, 2, 4], "the reply first, its choices under it; a trailing one stays last")
    }

    func testFoldedReplyDropsBlankLines() {
        XCTAssertEqual(OpenedSurfaceView.preview("Para one.\n\n- a\n\n- b"), "Para one.\n- a\n- b")
        XCTAssertTrue(OpenedSurfaceView.isLongReply("one\n\ntwo"), "blank lines dropped means there is more to show")
    }

    func testLongRepliesFoldToThreeLines() {
        XCTAssertFalse(OpenedSurfaceView.isLongReply("one\ntwo\nthree"))
        XCTAssertEqual(FirstMateEventText.parse("[seahelm event] ci.failed · rule fix-ci").style, .ciFailed)
        XCTAssertTrue(OpenedSurfaceView.isLongReply("one\ntwo\nthree\nfour"))
        XCTAssertTrue(OpenedSurfaceView.isLongReply(String(repeating: "x", count: 200)))
    }

    func testNoticesStayOutAndRepliesReadAsMarkdown() {
        let items = ConversationItem.items(from: [
            MessageEvent(seq: 1, paneId: "fm", paneSessionKey: "k", kind: .notice, ts: Date(), text: "Claude is waiting for your input"),
        ])
        XCTAssertTrue(items.isEmpty)
        let rendered = OpenedSurfaceView.markdown("**Needed from you:**\n- add the label")
        XCTAssertEqual(String(rendered.characters), "Needed from you:\n- add the label")
    }

    func testWhatSeahelmHandsFirstMateIsOneLine() {
        let prompt = "[seahelm event] pr.merged · rule cleanup-merged\nrepo: /r\nworktree: /w (branch x)"
        let items = ConversationItem.items(from: [
            MessageEvent(seq: 1, paneId: "fm", paneSessionKey: "k", kind: .user, ts: Date(), text: prompt),
            MessageEvent(seq: 2, paneId: "fm", paneSessionKey: "k", kind: .user, ts: Date(), text: "[seahelm] The user approved: Delete x"),
        ])
        XCTAssertEqual(items.map(\.kind), [
            .event(headline: "PR merged · x", full: prompt, style: .merged),
            .event(headline: "The user approved: Delete x", full: "[seahelm] The user approved: Delete x", style: .outcome),
        ])
    }

    /// The headline says what happened and to what, not which rule fired.
    func testEventHeadlinesReadAsWhatHappened() {
        let pr = "repo: /r\nworktree: /w (branch fix/x)\nPR: #11401 https://github.com/o/r/pull/11401 — failing"
        XCTAssertEqual(FirstMateEventText.headline("[seahelm event] ci.failed · rule fix-ci\n" + pr), "CI failed · PR #11401")
        XCTAssertEqual(FirstMateEventText.headline("[seahelm event] pr.merged · rule cleanup-merged\n" + pr), "PR #11401 merged")
        XCTAssertEqual(FirstMateEventText.headline("[seahelm event] ci.failed · rule fix-ci\nworktree: /w (branch main)"), "CI failed · main")
        XCTAssertEqual(FirstMateEventText.headline("[seahelm event] schedule · rule triage-issues\nrepo: /r"), "Scheduled · triage-issues")
        XCTAssertEqual(FirstMateEventText.headline("[seahelm event] issue.opened · rule x"), "issue.opened · rule x")
    }
}
