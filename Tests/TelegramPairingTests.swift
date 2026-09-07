import XCTest
@testable import seahelm

final class TelegramPairingTests: XCTestCase {

    // MARK: - Code shape

    func testGeneratedCodeIsEightCharactersFromTheAlphabet() {
        for _ in 0..<200 {
            let code = TelegramPairingCode.generate()
            XCTAssertEqual(code.count, TelegramPairingCode.length)
            XCTAssertTrue(code.allSatisfy { TelegramPairingCode.alphabet.contains($0) })
        }
    }

    /// The whole code travels in a `?start=` payload, whose legal characters
    /// are `A-Z a-z 0-9 _ -`. A code that needed escaping would arrive as
    /// something else.
    func testAlphabetIsDeepLinkSafeAndUnambiguous() {
        let legal = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        XCTAssertTrue(TelegramPairingCode.alphabet.allSatisfy { legal.contains($0) })
        for confusable in "01OIL" {
            XCTAssertFalse(TelegramPairingCode.alphabet.contains(confusable),
                           "\(confusable) reads as another character when typed off a screen")
        }
    }

    func testNormalizeStripsCaseAndSeparators() {
        XCTAssertEqual(TelegramPairingCode.normalize("abcd 2345"), "ABCD2345")
        XCTAssertEqual(TelegramPairingCode.normalize("ABCD-2345"), "ABCD2345")
        XCTAssertEqual(TelegramPairingCode.normalize("  abcd2345  "), "ABCD2345")
    }

    func testMatchesIgnoresFormattingButNotContent() {
        XCTAssertTrue(TelegramPairingCode.matches("ABCD2345", "abcd 2345"))
        XCTAssertFalse(TelegramPairingCode.matches("ABCD2345", "ABCD2346"))
        XCTAssertFalse(TelegramPairingCode.matches("ABCD2345", "ABCD234"))
        XCTAssertFalse(TelegramPairingCode.matches("ABCD2345", ""))
    }

    // MARK: - /start parsing

    func testStartPayloadReadsTheDeepLinkArgument() {
        XCTAssertEqual(TelegramPairingCode.startPayload(in: "/start ABCD2345"), "ABCD2345")
        XCTAssertEqual(TelegramPairingCode.startPayload(in: "  /start ABCD2345  "), "ABCD2345")
    }

    /// The Start button on a bot with no deep link sends a bare `/start`. That
    /// is a real message the channel has to answer, so it parses as an empty
    /// payload rather than as "not a start command".
    func testBareStartIsAnEmptyPayloadNotNil() {
        XCTAssertEqual(TelegramPairingCode.startPayload(in: "/start"), "")
    }

    func testNonStartTextIsNotAPayload() {
        XCTAssertNil(TelegramPairingCode.startPayload(in: "/status"))
        XCTAssertNil(TelegramPairingCode.startPayload(in: "start ABCD2345"))
        XCTAssertNil(TelegramPairingCode.startPayload(in: "/started something"))
        XCTAssertNil(TelegramPairingCode.startPayload(in: "please /start it"))
    }

    /// In a group Telegram delivers `/start@my_bot <payload>`; the channel
    /// strips the suffix before parsing, and the two together must survive it.
    func testGroupStartWithBotSuffixParsesAfterStripping() {
        let stripped = TelegramChannel.stripBotMention("/start@my_bot ABCD2345",
                                                       botUsername: "my_bot")
        XCTAssertEqual(TelegramPairingCode.startPayload(in: stripped), "ABCD2345")
    }

    func testDeepLinkNormalizesTheCode() {
        XCTAssertEqual(TelegramPairingCode.deepLink(botUsername: "my_bot", code: "abcd 2345"),
                       "https://t.me/my_bot?start=ABCD2345")
    }

    // MARK: - Session

    func testClaimSucceedsOnceAndOnlyOnce() {
        let session = TelegramPairingSession(code: "ABCD2345")
        XCTAssertTrue(session.claim("abcd2345"))
        // A forwarded link, or a retry, must not buy a second allowlist entry.
        XCTAssertFalse(session.claim("abcd2345"))
    }

    func testClaimRejectsTheWrongCodeWithoutSpendingTheSession() {
        let session = TelegramPairingSession(code: "ABCD2345")
        XCTAssertFalse(session.claim("ZZZZ9999"))
        XCTAssertTrue(session.claim("ABCD2345"))
    }

    func testExpiredCodeCannotBeClaimed() {
        let start = Date()
        let session = TelegramPairingSession(ttl: 60, code: "ABCD2345", now: start)
        XCTAssertFalse(session.claim("ABCD2345", now: start.addingTimeInterval(61)))
        XCTAssertTrue(session.isExpired(now: start.addingTimeInterval(61)))
        XCTAssertFalse(session.isExpired(now: start.addingTimeInterval(59)))
    }

    func testRefreshReplacesTheCodeAndRearmsAConsumedSession() {
        let session = TelegramPairingSession(code: "ABCD2345")
        XCTAssertTrue(session.claim("ABCD2345"))
        let next = session.refresh()
        XCTAssertNotEqual(next, "ABCD2345")
        XCTAssertFalse(session.isExpired())
        XCTAssertFalse(session.claim("ABCD2345"), "the old code must die with the refresh")
        XCTAssertTrue(session.claim(next))
    }

    // MARK: - Token extraction

    /// BotFather answers with a paragraph, and asking for exactly the token is
    /// asking for a truncated paste.
    func testTokenIsFoundInsideBotFathersWholeReply() {
        let reply = """
        Done! Congratulations on your new bot. You will find it at t.me/my_fleet_bot.

        Use this token to access the HTTP API:
        123456789:AAHkm-3xQ7zPQvWq2rT8nB1cD4eF5gH6iJk

        Keep your token secure and store it safely.
        """
        XCTAssertEqual(TelegramSetupWizard.extractToken(from: reply),
                       "123456789:AAHkm-3xQ7zPQvWq2rT8nB1cD4eF5gH6iJk")
    }

    func testBareTokenIsAcceptedUnchanged() {
        let token = "987654321:BBHkm-3xQ7zPQvWq2rT8nB1cD4eF5gH6iJk"
        XCTAssertEqual(TelegramSetupWizard.extractToken(from: "  \(token)\n"), token)
    }

    func testPartialOrAbsentTokenIsRejected() {
        XCTAssertNil(TelegramSetupWizard.extractToken(from: ""))
        XCTAssertNil(TelegramSetupWizard.extractToken(from: "123456789:"))
        // Half a token pasted mid-copy: the secret is 35 characters, and a
        // short tail would only fail later against Telegram.
        XCTAssertNil(TelegramSetupWizard.extractToken(from: "123456789:AAHkm-3xQ7z"))
        XCTAssertNil(TelegramSetupWizard.extractToken(from: "no token here at all"))
    }

    // MARK: - Published command menu

    /// `setMyCommands` is rejected wholesale if any entry is malformed, so the
    /// verb table has to satisfy Telegram's shape before it is sent.
    func testBotCommandsSatisfyTelegramsConstraints() {
        let commands = CommandSpecs.botCommands
        XCTAssertFalse(commands.isEmpty)
        XCTAssertLessThanOrEqual(commands.count, 100)
        for entry in commands {
            XCTAssertTrue((1...32).contains(entry.command.count), entry.command)
            XCTAssertTrue(entry.command.allSatisfy { $0.isLowercase && $0.isLetter || $0.isNumber || $0 == "_" },
                          entry.command)
            XCTAssertTrue((1...256).contains(entry.description.count), entry.command)
        }
        // Desktop-only verbs would list a command whose only answer in a chat
        // is that it does not work there.
        XCTAssertFalse(commands.contains { $0.command == "add" })
    }
}
