import XCTest
@testable import seahelm

/// The island's two pages (the surfaces design, states 2 and 3).
final class IslandFirstMateTests: XCTestCase {
    private func order(_ id: String) -> Card {
        Card(id: id, kind: .suggestion, terminalID: "t", worktreePath: "/w", message: "Next?", options: ["go"])
    }

    func testOpensOnTheCardsWhenAnyWaitElseOnTheConversation() {
        let model = IslandModel()
        model.open(reason: .click)
        XCTAssertEqual(model.page, .conversation)
        model.close()
        model.orders = [order("a")]
        model.open(reason: .hover)
        XCTAssertEqual(model.page, .suggestions)
        model.close()
        model.open(reason: .click, page: .conversation)
        XCTAssertEqual(model.page, .conversation, "⌘J and the command bar go straight to the conversation")
    }

    func testTheLastCardDealtWithLeavesTheConversation() {
        let model = IslandModel()
        model.orders = [order("a")]
        model.open(reason: .click)
        model.orders = []
        XCTAssertEqual(model.page, .conversation)
        XCTAssertFalse(model.pendingCommandFocus, "and does not take the keyboard")
    }

    func testEscapeGoesBackToTheCardsThenShuts() {
        let model = IslandModel()
        model.orders = [order("a")]
        model.open(reason: .click, page: .conversation)
        XCTAssertTrue(model.escape())
        XCTAssertEqual(model.page, .suggestions)
        XCTAssertTrue(model.isOpened)
        XCTAssertTrue(model.escape())
        XCTAssertFalse(model.isOpened)
        XCTAssertFalse(model.escape())
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
        XCTAssertEqual(items.map(\.kind), [
            .user("Anything red?"), .thinking("Checking CI"), .tools("Bash ×2 · Read"),
            .assistant("PR #12 is red: a flaky test."), .note("Stopped with an error"),
        ])
        XCTAssertEqual(items[2].id, 4, "a run is keyed by its first call, so it stays put as it grows")
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
            .event(headline: "pr.merged · rule cleanup-merged", full: prompt),
            .event(headline: "The user approved: Delete x", full: "[seahelm] The user approved: Delete x"),
        ])
    }
}
