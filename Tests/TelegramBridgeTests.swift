import XCTest
@testable import seahelm

final class TelegramBridgeTests: XCTestCase {

    // MARK: - Allowlist

    func testAllowlistMatchesNumericId() {
        let cfg = TelegramConfig(allowedUsers: ["123456789"])
        XCTAssertTrue(cfg.allows(userId: 123_456_789, username: nil))
        XCTAssertFalse(cfg.allows(userId: 987_654_321, username: nil))
    }

    /// `@Someone` and `someone` are the same handle; Telegram usernames are
    /// case-insensitive.
    func testAllowlistMatchesUsernameLoosely() {
        let cfg = TelegramConfig(allowedUsers: ["@Someone"])
        XCTAssertTrue(cfg.allows(userId: 1, username: "someone"))
        XCTAssertTrue(cfg.allows(userId: 1, username: "SOMEONE"))
        XCTAssertFalse(cfg.allows(userId: 1, username: "someone_else"))
    }

    func testAllowlistEntryMatchesEitherIdOrName() {
        let cfg = TelegramConfig(allowedUsers: [" 42 ", "bob"])
        XCTAssertTrue(cfg.allows(userId: 42, username: "nobody"))
        XCTAssertTrue(cfg.allows(userId: 7, username: "Bob"))
    }

    /// The open-chat default: no allowlist means no orders, not all orders.
    func testEmptyAllowlistRejectsEveryone() {
        let cfg = TelegramConfig()
        XCTAssertFalse(cfg.allows(userId: 1, username: "anyone"))
    }

    func testUserWithoutUsernameNeedsNumericEntry() {
        let cfg = TelegramConfig(allowedUsers: ["@bob"])
        XCTAssertFalse(cfg.allows(userId: 42, username: nil))
    }

    // MARK: - Default chat

    /// A private chat's id is the user's id, so a numeric allowlist entry can
    /// stand in for the notification target; a username cannot.
    func testDefaultChatFallsBackToFirstNumericAllowedUser() {
        XCTAssertEqual(TelegramConfig(allowedUsers: ["@bob", "42", "43"]).resolvedDefaultChatId, "42")
        XCTAssertNil(TelegramConfig(allowedUsers: ["@bob"]).resolvedDefaultChatId)
        XCTAssertEqual(TelegramConfig(allowedUsers: ["42"], defaultChatId: "-1001").resolvedDefaultChatId, "-1001")
    }

    func testNumericIdAcceptsNegativeGroupIds() {
        XCTAssertTrue(TelegramConfig.isNumericId("-1001234567890"))
        XCTAssertTrue(TelegramConfig.isNumericId("42"))
        XCTAssertFalse(TelegramConfig.isNumericId("-"))
        XCTAssertFalse(TelegramConfig.isNumericId("@bob"))
        XCTAssertFalse(TelegramConfig.isNumericId(""))
    }

    // MARK: - Config decoding

    func testConfigDecodesSnakeCaseAndDefaults() throws {
        let json = """
        { "bot_token": "1:abc", "allowed_users": ["42"], "auto_connect": false }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(TelegramConfig.self, from: json)
        XCTAssertEqual(cfg.resolvedBotToken, "1:abc")
        XCTAssertEqual(cfg.allowedUsers, ["42"])
        XCTAssertFalse(cfg.resolvedAutoConnect)
        XCTAssertEqual(cfg.resolvedBackfillSeconds, 60)
    }

    func testConfigDecodesFromEmptyObject() throws {
        let cfg = try JSONDecoder().decode(TelegramConfig.self, from: "{}".data(using: .utf8)!)
        XCTAssertTrue(cfg.allowedUsers.isEmpty)
        XCTAssertNil(cfg.resolvedBotToken)
        XCTAssertTrue(cfg.resolvedAutoConnect)
    }

    func testBlankTokenResolvesToNil() {
        XCTAssertNil(TelegramConfig(botToken: "   ").resolvedBotToken)
    }

    // MARK: - Update decoding

    /// A private-chat message as the Bot API actually serialises it.
    func testUpdateDecodesFromBotAPIJSON() throws {
        let json = """
        {"ok":true,"result":[{"update_id":700000001,
          "message":{"message_id":12,"from":{"id":42,"is_bot":false,"first_name":"Matt","username":"matt_c"},
                     "chat":{"id":42,"first_name":"Matt","type":"private"},"date":1757000000,"text":"/status"}}]}
        """.data(using: .utf8)!
        struct Envelope: Decodable { let result: [TelegramUpdate] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let updates = try decoder.decode(Envelope.self, from: json).result
        XCTAssertEqual(updates.count, 1)
        let message = try XCTUnwrap(updates[0].payload)
        XCTAssertEqual(updates[0].updateId, 700_000_001)
        XCTAssertEqual(message.from?.id, 42)
        XCTAssertEqual(message.from?.displayName, "@matt_c")
        XCTAssertTrue(message.chat.isPrivate)
        XCTAssertEqual(message.body, "/status")
        XCTAssertEqual(message.timestamp, Date(timeIntervalSince1970: 1_757_000_000))
    }

    /// A payload Telegram serialises in a shape we cannot decode must still
    /// yield its id, or the poll loop would re-fetch it forever.
    func testUndecodableUpdateStillCarriesItsId() throws {
        let json = """
        {"ok":true,"result":[{"update_id":5,"message":{"message_id":"not-a-number","date":1,"chat":{"id":1,"type":"private"}}},
                             {"update_id":6,"message":{"message_id":2,"date":1,"chat":{"id":1,"type":"private"},"text":"hi"}}]}
        """.data(using: .utf8)!
        let api = TelegramBotAPI(token: "t")
        let updates = try api.decodeUpdatesForTesting(json)
        XCTAssertEqual(updates.map(\.updateId), [5, 6])
        XCTAssertNil(updates[0].payload)
        XCTAssertEqual(updates[1].payload?.body, "hi")
    }

    func testChannelPostIsThePayloadWhenThereIsNoMessage() throws {
        let json = """
        {"update_id":1,"channel_post":{"message_id":3,"sender_chat":{"id":-100,"type":"channel","title":"Alerts"},
         "chat":{"id":-100,"type":"channel","title":"Alerts"},"date":1757000000,"text":"CPU 95%"}}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let update = try decoder.decode(TelegramUpdate.self, from: json)
        XCTAssertNil(update.message)
        XCTAssertEqual(update.payload?.body, "CPU 95%")
        XCTAssertNil(update.payload?.from)
    }

    // MARK: - Command classification

    private func message(_ text: String?,
                         from: TelegramUser? = TelegramUser(id: 42, isBot: false, firstName: "Matt", username: "matt_c"),
                         chat: TelegramChat = TelegramChat(id: 42, type: "private", title: nil, username: nil),
                         senderChat: TelegramChat? = nil,
                         caption: String? = nil) -> TelegramMessage {
        TelegramMessage(messageId: 1, date: 1_757_000_000, chat: chat, from: from,
                        senderChat: senderChat, text: text, caption: caption)
    }

    private let group = TelegramChat(id: -100, type: "supergroup", title: "Team", username: nil)
    private var ownerConfig: TelegramConfig { TelegramConfig(allowedUsers: ["42"]) }

    func testPrivateChatTextFromAllowedUserIsAnOrder() {
        let cmd = TelegramChannel.command(in: message("fix the flaky test"), config: ownerConfig, botUsername: "seahelm_bot")
        XCTAssertEqual(cmd, TelegramChannel.Command(body: "fix the flaky test", senderId: "42", senderName: "@matt_c"))
    }

    func testUnlistedUserIsNeverAnOrder() {
        let stranger = TelegramUser(id: 7, isBot: false, firstName: "X", username: nil)
        XCTAssertNil(TelegramChannel.command(in: message("/status", from: stranger), config: ownerConfig, botUsername: nil))
    }

    /// Channel posts and anonymous admins carry no user, so nothing can vouch
    /// for them.
    func testMessageWithoutSenderIsNeverAnOrder() {
        XCTAssertNil(TelegramChannel.command(in: message("/status", from: nil), config: ownerConfig, botUsername: nil))
    }

    /// A shared group is not a private command line: only `/commands` count.
    func testGroupProseIsNotAnOrderButGroupCommandIs() {
        XCTAssertNil(TelegramChannel.command(in: message("lunch?", chat: group), config: ownerConfig, botUsername: nil))
        let cmd = TelegramChannel.command(in: message("/status", chat: group), config: ownerConfig, botUsername: nil)
        XCTAssertEqual(cmd?.body, "/status")
    }

    /// Telegram appends `@botname` to commands in groups with several bots.
    func testBotMentionSuffixIsStripped() {
        let cmd = TelegramChannel.command(in: message("/order@SeaHelm_Bot #1 run tests", chat: group),
                                          config: ownerConfig, botUsername: "seahelm_bot")
        XCTAssertEqual(cmd?.body, "/order #1 run tests")
        XCTAssertEqual(TelegramChannel.stripBotMention("/status@seahelm_bot", botUsername: "seahelm_bot"), "/status")
        XCTAssertEqual(TelegramChannel.stripBotMention("/status@other_bot", botUsername: "seahelm_bot"), "/status@other_bot")
        XCTAssertEqual(TelegramChannel.stripBotMention("hello @seahelm_bot", botUsername: "seahelm_bot"), "hello @seahelm_bot")
    }

    func testCaptionStandsInForText() {
        let cmd = TelegramChannel.command(in: message(nil, caption: "/idea dark mode"), config: ownerConfig, botUsername: nil)
        XCTAssertEqual(cmd?.body, "/idea dark mode")
    }

    func testEmptyOrWhitespaceTextIsNotAnOrder() {
        XCTAssertNil(TelegramChannel.command(in: message("   "), config: ownerConfig, botUsername: nil))
        XCTAssertNil(TelegramChannel.command(in: message(nil), config: ownerConfig, botUsername: nil))
    }

    // MARK: - Signal sender

    func testSignalSenderPrefersUsernameThenChannelIdentity() {
        XCTAssertEqual(TelegramChannel.signalSender(of: message("x")), "@matt_c")
        let anonymous = TelegramUser(id: 7, isBot: false, firstName: "X", username: nil)
        XCTAssertEqual(TelegramChannel.signalSender(of: message("x", from: anonymous)), "7")
        let channel = TelegramChat(id: -100, type: "channel", title: "Alerts", username: "ops_alerts")
        XCTAssertEqual(TelegramChannel.signalSender(of: message("x", from: nil, chat: channel, senderChat: channel)), "@ops_alerts")
        let untitled = TelegramChat(id: -100, type: "channel", title: "Alerts", username: nil)
        XCTAssertEqual(TelegramChannel.signalSender(of: message("x", from: nil, chat: untitled)), "Alerts")
    }

    // MARK: - Formatting

    func testMarkdownBecomesTelegramHTML() {
        let out = TelegramFormatter.html(from: "✅ **Finished**\nrepo · `main` <ok> & done")
        XCTAssertEqual(out, "✅ <b>Finished</b>\nrepo · <code>main</code> &lt;ok&gt; &amp; done")
    }

    func testFencedBlockBecomesPre() {
        let out = TelegramFormatter.html(from: "before\n```swift\nlet a = 1 < 2\n```\nafter")
        XCTAssertEqual(out, "before\n<pre>let a = 1 &lt; 2\n</pre>\nafter")
    }

    func testWholeLineUnderscoreItalicOnly() {
        XCTAssertEqual(TelegramFormatter.html(from: "_Chat only:_"), "<i>Chat only:</i>")
        XCTAssertEqual(TelegramFormatter.html(from: "is_from_me = 1"), "is_from_me = 1")
    }

    func testInlineMarkersDoNotSpanLines() {
        XCTAssertEqual(TelegramFormatter.html(from: "**a\nb**"), "**a\nb**")
    }

    func testPlainStripsMarkers() {
        XCTAssertEqual(TelegramFormatter.plain(from: "✅ **Finished**\nrepo · `main`"), "✅ Finished\nrepo · main")
        XCTAssertEqual(TelegramFormatter.plain(from: "```\nls -la\n```"), "\nls -la\n")
    }

    /// The 400 fallback resends the same words: tags gone, entities restored.
    func testStripHTMLRoundTripsThePlainText() {
        let source = "✅ **Finished** <ok> & `x`"
        XCTAssertEqual(TelegramFormatter.stripHTML(TelegramFormatter.html(from: source)),
                       "✅ Finished <ok> & x")
    }

    // MARK: - Chunking

    func testShortTextIsOneChunk() {
        XCTAssertEqual(TelegramFormatter.chunk("hello", limit: 100), ["hello"])
    }

    func testChunksSplitOnLineBoundaries() {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let chunks = TelegramFormatter.chunk(text, limit: 40)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.unicodeScalars.count, 40) }
        XCTAssertEqual(chunks.joined(separator: "\n"), text)
    }

    /// A `<pre>` cut in half would fail to parse on both sides; each chunk
    /// must close what it opened and reopen on the next.
    func testOpenPreIsClosedAndReopenedAcrossChunks() {
        let body = (1...12).map { "row \($0)" }.joined(separator: "\n")
        let html = "<pre>" + body + "</pre>"
        let chunks = TelegramFormatter.chunk(html, limit: 48)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertTrue(chunk.hasPrefix("<pre>"), "chunk lost its opening tag: \(chunk)")
            XCTAssertTrue(chunk.hasSuffix("</pre>"), "chunk lost its closing tag: \(chunk)")
            XCTAssertLessThanOrEqual(chunk.unicodeScalars.count, 48)
        }
    }

    func testOverlongLineIsCutHard() {
        let line = String(repeating: "x", count: 100)
        let chunks = TelegramFormatter.chunk(line, limit: 40)
        XCTAssertEqual(chunks.joined(), line)
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.unicodeScalars.count, 40) }
    }

    // MARK: - Errors

    func testFatalErrorsAreTheOnesRetryingCannotFix() {
        XCTAssertTrue(TelegramAPIError.api(code: 401, description: "Unauthorized").isFatal)
        XCTAssertFalse(TelegramAPIError.api(code: 409, description: "Conflict").isFatal, "a previous instance still polling resolves itself")
        XCTAssertFalse(TelegramAPIError.api(code: 429, description: "Too Many Requests").isFatal)
        XCTAssertFalse(TelegramAPIError.network("offline").isFatal)
        XCTAssertTrue(TelegramAPIError.api(code: 400, description: "can't parse entities").isBadRequest)
    }
}
