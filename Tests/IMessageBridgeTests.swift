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

    // MARK: - Database probe

    func testProbeReportsMissingDatabase() {
        let db = IMessageChatDB(path: "/tmp/seahelm-nonexistent-chat.db")
        XCTAssertEqual(db.probe(), .missing)
    }
}
