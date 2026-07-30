import XCTest
@testable import seahelm

final class IMessageBridgeTests: XCTestCase {

    // MARK: - Allowlist

    func testAllowlistMatchesExactHandle() {
        let cfg = IMessageConfig(allowedHandles: ["+8613800138000"])
        XCTAssertTrue(cfg.allows(handle: "+8613800138000"))
    }

    /// Messages stores E.164 but users type the local number; both must match,
    /// or the owner gets locked out of their own bridge.
    func testAllowlistIgnoresCountryCodeAndFormatting() {
        let cfg = IMessageConfig(allowedHandles: ["13800138000"])
        XCTAssertTrue(cfg.allows(handle: "+86 138-0013-8000"))
    }

    func testAllowlistIsCaseInsensitiveForAppleIDs() {
        let cfg = IMessageConfig(allowedHandles: ["Someone@Example.com"])
        XCTAssertTrue(cfg.allows(handle: "someone@example.com"))
    }

    func testAllowlistRejectsUnknownHandle() {
        let cfg = IMessageConfig(allowedHandles: ["+8613800138000"])
        XCTAssertFalse(cfg.allows(handle: "+8613900139000"))
    }

    /// The open-inbox default: no allowlist means no commands, not all commands.
    func testEmptyAllowlistRejectsEveryone() {
        let cfg = IMessageConfig()
        XCTAssertFalse(cfg.allows(handle: "+8613800138000"))
        XCTAssertFalse(cfg.allows(handle: "someone@example.com"))
    }

    func testEmptyHandleIsRejected() {
        let cfg = IMessageConfig(allowedHandles: ["+8613800138000"])
        XCTAssertFalse(cfg.allows(handle: ""))
    }

    func testDefaultRecipientFallsBackToFirstAllowedHandle() {
        let cfg = IMessageConfig(allowedHandles: ["+8613800138000", "b@example.com"])
        XCTAssertEqual(cfg.resolvedDefaultRecipient, "+8613800138000")

        let explicit = IMessageConfig(allowedHandles: ["+8613800138000"], defaultRecipient: "b@example.com")
        XCTAssertEqual(explicit.resolvedDefaultRecipient, "b@example.com")
    }

    // MARK: - Config decoding

    func testConfigDecodesSnakeCaseAndDefaults() throws {
        let json = """
        { "allowed_handles": ["+8613800138000"], "auto_connect": false }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(IMessageConfig.self, from: json)
        XCTAssertEqual(cfg.allowedHandles, ["+8613800138000"])
        XCTAssertFalse(cfg.resolvedAutoConnect)
        XCTAssertEqual(cfg.resolvedBackfillSeconds, 60)
    }

    func testConfigDecodesFromEmptyObject() throws {
        let cfg = try JSONDecoder().decode(IMessageConfig.self, from: "{}".data(using: .utf8)!)
        XCTAssertTrue(cfg.allowedHandles.isEmpty)
        XCTAssertTrue(cfg.resolvedAutoConnect)
    }

    // MARK: - AppleScript escaping

    /// A raw newline in an AppleScript string literal is a syntax error, and an
    /// unescaped quote would let message text break out of the literal.
    func testEscapeQuotesBackslashesAndNewlines() {
        XCTAssertEqual(IMessageSender.escape("say \"hi\""), "say \\\"hi\\\"")
        XCTAssertEqual(IMessageSender.escape("a\\b"), "a\\\\b")
        XCTAssertEqual(IMessageSender.escape("one\ntwo"), "one\\ntwo")
        XCTAssertEqual(IMessageSender.escape("one\r\ntwo"), "one\\ntwo")
    }

    func testEmptyTargetIsRejectedBeforeRunningAnyScript() {
        XCTAssertThrowsError(try IMessageSender.send("hi", to: "  "))
    }

    // MARK: - Markdown flattening

    func testMarkdownEmphasisStrippedForIMessage() {
        let out = IMessageChannel.flatten("✅ **Finished**\nrepo · `main`", format: .markdown)
        XCTAssertEqual(out, "✅ Finished\nrepo · main")
    }

    func testPlainTextPassesThroughUntouched() {
        let raw = "**not markdown**"
        XCTAssertEqual(IMessageChannel.flatten(raw, format: .text), raw)
    }

    // MARK: - Body decoding

    func testPlainTextColumnWins() {
        XCTAssertEqual(IMessageBodyDecoder.decode(text: "/status", attributedBody: nil), "/status")
    }

    func testWhitespaceOnlyTextFallsThroughToNil() {
        XCTAssertNil(IMessageBodyDecoder.decode(text: "   \n", attributedBody: nil))
    }

    /// macOS 13+ leaves `text` NULL and puts the body in `attributedBody`.
    func testAttributedBodyIsDecodedWhenTextIsNil() throws {
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: NSAttributedString(string: "/new fix the flaky test"),
            requiringSecureCoding: false
        )
        XCTAssertEqual(IMessageBodyDecoder.decode(text: nil, attributedBody: archived),
                       "/new fix the flaky test")
    }

    /// Inline attachments arrive as U+FFFC; an attachment-only message carries
    /// no command and must not reach the router as a stray blank line.
    func testObjectReplacementCharactersStripped() {
        XCTAssertNil(IMessageBodyDecoder.decode(text: "\u{fffc}", attributedBody: nil))
        XCTAssertEqual(IMessageBodyDecoder.decode(text: "\u{fffc}/status", attributedBody: nil), "/status")
    }

    func testGarbageAttributedBodyDoesNotCrash() {
        XCTAssertNil(IMessageBodyDecoder.decode(text: nil, attributedBody: Data([0x00, 0x01, 0x02])))
    }

    /// Real Messages.app SMS archives (Aliyun / 106* shortcodes) are *not* a
    /// clean `NSKeyedArchiver` root of `NSAttributedString` — `forReadingFrom:`
    /// fails — and their typedstream length sits behind class-ref bytes
    /// (`…NSString \x01\x95\x84\x01 + \x81 <u16le> <utf8>`). The old scavenger
    /// treated the first byte ≥ 0x20 as length, hit `0x95`, and dropped the
    /// message. That is why an Alibaba Cloud alert SMS that only lived in
    /// `attributedBody` never fired a rule even though the body regex matched.
    func testMessagesTypedstreamAttributedBodyIsScavenged() {
        let body = "【阿里云】尊敬的may_cauc@aliyun.com - 1317424610922997 , 华南1(深圳)的云数据库RDS版  发生告警  ，cpu_usage平均值>=90  当前值: 90.94  告警规则high-cpu 请登录云监控查看"
        let utf8 = Data(body.utf8)
        XCTAssertGreaterThan(utf8.count, 0x80, "fixture must need the 0x81 extended length")

        var blob = Data("xNSString".utf8)                         // marker with junk ahead
        blob.append(contentsOf: [0x01, 0x95, 0x84, 0x01, 0x2b])   // class refs + '+'
        blob.append(0x81)                                          // extended length
        blob.append(UInt8(utf8.count & 0xff))
        blob.append(UInt8((utf8.count >> 8) & 0xff))
        blob.append(utf8)
        blob.append(contentsOf: [0x00, 0x02])                      // trailing archive junk

        XCTAssertEqual(IMessageBodyDecoder.decode(text: nil, attributedBody: blob), body)
    }

    // MARK: - Prefixes

    func testCommandPrefixIsStrippedCaseInsensitively() {
        let cfg = IMessageConfig()
        XCTAssertEqual(cfg.commandBody(of: "sea status"), "status")
        XCTAssertEqual(cfg.commandBody(of: "Sea   status"), "status")
        XCTAssertEqual(cfg.commandBody(of: "  sea /new fix the test  "), "/new fix the test")
    }

    /// Without a separator `seahelm` would read as the prefix plus `helm`.
    func testPrefixRequiresASeparator() {
        let cfg = IMessageConfig()
        XCTAssertNil(cfg.commandBody(of: "seahelm is nice"))
        XCTAssertNil(cfg.commandBody(of: "seagull"))
    }

    /// A bare prefix carries no order.
    func testBarePrefixIsNotACommand() {
        let cfg = IMessageConfig()
        XCTAssertNil(cfg.commandBody(of: "sea"))
        XCTAssertNil(cfg.commandBody(of: "sea   "))
    }

    func testUnprefixedTextIsNotACommand() {
        XCTAssertNil(IMessageConfig().commandBody(of: "remember to buy milk"))
    }

    func testReplyStampIsIdempotent() {
        let cfg = IMessageConfig()
        XCTAssertEqual(cfg.stampReply("done"), "helm done")
        XCTAssertEqual(cfg.stampReply("helm done"), "helm done")
        XCTAssertTrue(cfg.isOwnReply("helm ✅ Finished"))
        XCTAssertFalse(cfg.isOwnReply("sea status"))
    }

    func testPrefixesAreConfigurable() {
        let cfg = IMessageConfig(commandPrefix: "yo", replyPrefix: "bot")
        XCTAssertEqual(cfg.commandBody(of: "yo status"), "status")
        XCTAssertNil(cfg.commandBody(of: "sea status"))
        XCTAssertEqual(cfg.stampReply("done"), "bot done")
    }

    func testPrefixDecodingAndBlankFallback() throws {
        let json = """
        { "command_prefix": "yo", "reply_prefix": "  " }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(IMessageConfig.self, from: json)
        XCTAssertEqual(cfg.resolvedCommandPrefix, "yo")
        XCTAssertEqual(cfg.resolvedReplyPrefix, "helm")
    }

    // MARK: - Chat GUID

    func testCounterpartExtractedFromDirectChatGuid() {
        XCTAssertEqual(IMessageConfig.counterpart(ofChatGuid: "iMessage;-;+8613800138000"),
                       "+8613800138000")
        XCTAssertEqual(IMessageConfig.counterpart(ofChatGuid: "SMS;-;10690000"), "10690000")
    }

    /// A group thread is not a private command line.
    func testCounterpartIsNilForGroupChat() {
        XCTAssertNil(IMessageConfig.counterpart(ofChatGuid: "iMessage;+;chat1234567890"))
        XCTAssertNil(IMessageConfig.counterpart(ofChatGuid: nil))
    }

    // MARK: - Command classification

    private func row(_ text: String,
                     fromMe: Bool = false,
                     sender: String = "+8613800138000",
                     chatGuid: String? = "iMessage;-;+8613800138000",
                     isGroup: Bool = false) -> IMessageRow {
        IMessageRow(rowId: 1, guid: "guid", sender: fromMe ? "" : sender,
                    chatGuid: chatGuid, isGroup: isGroup, text: text,
                    date: Date(), isFromMe: fromMe)
    }

    private var ownerConfig: IMessageConfig {
        IMessageConfig(allowedHandles: ["+8613800138000"])
    }

    /// The single-Apple-ID case: the command syncs over as an outgoing row with
    /// no sender, and the chat is the only thing left to authorise against.
    func testOwnCommandIsAcceptedAndAttributedToTheChat() {
        let cmd = IMessageChannel.command(in: row("sea status", fromMe: true), config: ownerConfig)
        XCTAssertEqual(cmd, IMessageChannel.Command(body: "status", sender: "+8613800138000"))
    }

    /// The echo guard — without it every reply becomes the next command.
    func testOwnReplyIsNotACommand() {
        XCTAssertNil(IMessageChannel.command(in: row("helm ✅ Finished", fromMe: true),
                                             config: ownerConfig))
    }

    /// Texting yourself is also how people keep notes; only prefixed lines count.
    func testOwnUnprefixedNoteIsIgnored() {
        XCTAssertNil(IMessageChannel.command(in: row("买牛奶", fromMe: true), config: ownerConfig))
    }

    func testOwnCommandInGroupChatIsRejected() {
        let r = row("sea status", fromMe: true, chatGuid: "iMessage;+;chat123", isGroup: true)
        XCTAssertNil(IMessageChannel.command(in: r, config: ownerConfig))
    }

    /// A thread with someone not on the allowlist is not a command line, even
    /// though the message is technically "from me".
    func testOwnCommandInUnlistedThreadIsRejected() {
        let r = row("sea status", fromMe: true, chatGuid: "iMessage;-;+8613900139000")
        XCTAssertNil(IMessageChannel.command(in: r, config: ownerConfig))
    }

    func testIncomingCommandFromAllowedSenderIsAccepted() {
        let cmd = IMessageChannel.command(in: row("sea status"), config: ownerConfig)
        XCTAssertEqual(cmd, IMessageChannel.Command(body: "status", sender: "+8613800138000"))
    }

    func testIncomingCommandFromUnlistedSenderIsRejected() {
        let r = row("sea status", sender: "+8613900139000")
        XCTAssertNil(IMessageChannel.command(in: r, config: ownerConfig))
    }

    /// Alerts and ordinary texts stay out of the command path — they are the
    /// rule engine's input, not orders.
    func testIncomingUnprefixedMessageIsNotACommand() {
        XCTAssertNil(IMessageChannel.command(in: row("【阿里云】CPU 使用率 95%"), config: ownerConfig))
    }

    // MARK: - Database probe

    func testProbeReportsMissingDatabase() {
        let db = IMessageChatDB(path: "/tmp/seahelm-nonexistent-chat.db")
        XCTAssertEqual(db.probe(), .missing)
    }
}
