import XCTest
@testable import seahelm

/// A forum topic is a second coordinate on a chat, and it travels inside the
/// chat-id string so that every seam downstream — sessions, notices, progress
/// lines — keeps treating an address as opaque. These are the rules that makes
/// safe.
final class TelegramChatAddressTests: XCTestCase {

    private func message(chatId: Int64,
                         type: String = "supergroup",
                         threadId: Int?,
                         isTopicMessage: Bool?) -> TelegramMessage {
        TelegramMessage(messageId: 1, date: 1_757_000_000,
                        chat: TelegramChat(id: chatId, type: type, title: "Team", username: nil,
                                           isForum: true),
                        from: TelegramUser(id: 42, isBot: false, firstName: "Matt", username: "matt_c"),
                        senderChat: nil, text: "hi", caption: nil,
                        messageThreadId: threadId, isTopicMessage: isTopicMessage)
    }

    // MARK: - Encoding

    func testTopicMessageCarriesItsThread() {
        let address = TelegramChatAddress.of(message(chatId: -1_001_234_567_890, threadId: 42,
                                                     isTopicMessage: true))
        XCTAssertEqual(address, "-1001234567890#42")
    }

    func testChatWithoutTopicIsJustTheChatId() {
        let address = TelegramChatAddress.of(message(chatId: -100, threadId: nil, isTopicMessage: nil))
        XCTAssertEqual(address, "-100")
    }

    /// General is the chat at large: Telegram numbers it 1, stamps nothing on
    /// messages posted there, and answers a send with `message_thread_id: 1`
    /// with "message thread not found".
    func testGeneralTopicIsNotAThread() {
        let address = TelegramChatAddress.of(message(chatId: -100, threadId: 1, isTopicMessage: true))
        XCTAssertEqual(address, "-100")
        XCTAssertNil(TelegramChatAddress.encode(chatId: "-100", threadId: 1).firstIndex(of: "#"))
    }

    /// `message_thread_id` is also set on an ordinary reply chain in a plain
    /// group, where sending it back is an error. `is_topic_message` is what
    /// separates the two.
    func testReplyChainInAPlainGroupIsNotATopic() {
        let address = TelegramChatAddress.of(message(chatId: -100, type: "group", threadId: 77,
                                                     isTopicMessage: nil))
        XCTAssertEqual(address, "-100")
    }

    /// Since Bot API 10.0 a private chat has topics of its own, and a threaded
    /// send to one is rejected outright.
    func testPrivateChatTopicIsNotAThread() {
        let address = TelegramChatAddress.of(message(chatId: 42, type: "private", threadId: 5,
                                                     isTopicMessage: true))
        XCTAssertEqual(address, "42")
    }

    // MARK: - Splitting

    func testSplitReturnsChatAndThread() {
        let (chat, thread) = TelegramChatAddress.split("-1001234567890#42")
        XCTAssertEqual(chat, "-1001234567890")
        XCTAssertEqual(thread, 42)
    }

    func testSplitLeavesAPlainChatIdAlone() {
        let (chat, thread) = TelegramChatAddress.split("-1001234567890")
        XCTAssertEqual(chat, "-1001234567890")
        XCTAssertNil(thread)
    }

    /// A malformed address fails as one bad `sendMessage` Telegram explains,
    /// not as a silent delivery to a chat id invented by truncating it.
    func testSplitKeepsAnUnparseableAddressWhole() {
        let (chat, thread) = TelegramChatAddress.split("-100#abc")
        XCTAssertEqual(chat, "-100#abc")
        XCTAssertNil(thread)
    }

    func testRoundTrip() {
        for thread in [nil, 2, 99] as [Int?] {
            let (chat, back) = TelegramChatAddress.split(
                TelegramChatAddress.encode(chatId: "-100", threadId: thread))
            XCTAssertEqual(chat, "-100")
            XCTAssertEqual(back, thread)
        }
    }

    func testChatIdDropsTheTopic() {
        XCTAssertEqual(TelegramChatAddress.chatId(of: "-100#42"), "-100")
        XCTAssertEqual(TelegramChatAddress.chatId(of: "-100"), "-100")
    }

    // MARK: - What the address buys

    /// The point of the whole exercise: two topics in one group are two
    /// sessions, so a `/go` in one cannot redirect the other.
    func testTwoTopicsInOneGroupAreTwoSessions() {
        let store = CommandSessionStore(url: nil, legacyMailURL: nil)
        let first = CommandSession.key(surface: "telegram", id: "-100#7")
        let second = CommandSession.key(surface: "telegram", id: "-100#8")

        store.bind(first, toPaneKey: "pane-a", paneId: "a", worktreePath: "/tmp/a")
        store.bind(second, toPaneKey: "pane-b", paneId: "b", worktreePath: "/tmp/b")

        XCTAssertEqual(store.session(for: first).boundPaneId, "a")
        XCTAssertEqual(store.session(for: second).boundPaneId, "b")
        XCTAssertEqual(store.session(for: first).id, "-100#7")
    }

    // MARK: - One copy per room

    /// The duplicate that shipped: a `/go` in the group, another in a topic and
    /// the pane's own topic are three bindings in one room.
    func testOneAddressPerChatKeepsThePanesOwnTopic() {
        let kept = TelegramChatAddress.oneAddressPerChat(
            ["-100", "-100#46", "-100#102"], preferring: "-100#102")
        XCTAssertEqual(kept, ["-100#102"])
    }

    /// With no topic of its own, the most specific place still wins over the
    /// chat at large.
    func testATopicBeatsTheChatAtLarge() {
        XCTAssertEqual(TelegramChatAddress.oneAddressPerChat(["-100", "-100#46"], preferring: nil),
                       ["-100#46"])
    }

    /// Other chats are other conversations — a private chat bound to the same
    /// pane still hears it.
    func testOtherChatsAreUntouched() {
        let kept = TelegramChatAddress.oneAddressPerChat(
            ["-100", "-100#46", "42", "-200#7"], preferring: "-100#46")
        XCTAssertEqual(kept, ["-100#46", "-200#7", "42"])
    }

    func testEmptyAndSingleAreUnchanged() {
        XCTAssertEqual(TelegramChatAddress.oneAddressPerChat([], preferring: nil), [])
        XCTAssertEqual(TelegramChatAddress.oneAddressPerChat(["-100"], preferring: nil), ["-100"])
    }

    /// A preferred address for a chat that is not in the list changes nothing.
    func testPreferredNotPresentIsIgnored() {
        XCTAssertEqual(TelegramChatAddress.oneAddressPerChat(["-100#4"], preferring: "-100#99"),
                       ["-100#4"])
    }

    // MARK: - A thread that is gone

    /// Telegram's wording for a thread that no longer exists, which is what a
    /// message aimed at a deleted topic comes back as.
    func testMissingThreadIsRecognised() {
        XCTAssertTrue(TelegramAPIError.api(code: 400, description: "Bad Request: message thread not found")
            .isMissingThread)
        XCTAssertFalse(TelegramAPIError.api(code: 400, description: "Bad Request: chat not found")
            .isMissingThread)
        XCTAssertFalse(TelegramAPIError.api(code: 403, description: "message thread not found")
            .isMissingThread)
    }
}
