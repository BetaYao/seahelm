import XCTest
@testable import seahelm

final class CommandParserTests: XCTestCase {

    private func makeMessage(content: String) -> InboundMessage {
        InboundMessage(
            channelId: "test-ch",
            senderId: "user1",
            senderName: "Test User",
            chatId: nil,
            chatType: .direct,
            content: content,
            messageId: "msg-1",
            timestamp: Date(),
            replyTo: nil,
            metadata: nil
        )
    }

    func testParseIdeaCommand() {
        let msg = makeMessage(content: "/idea 做一个登录页")
        let cmd = CommandParser.parse(msg)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.command, "idea")
        XCTAssertEqual(cmd?.args, "做一个登录页")
    }

    func testParseStatusCommand() {
        let msg = makeMessage(content: "/status")
        let cmd = CommandParser.parse(msg)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.command, "status")
        XCTAssertEqual(cmd?.args, "")
    }

    func testParseListCommand() {
        let msg = makeMessage(content: "/list")
        let cmd = CommandParser.parse(msg)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.command, "list")
    }

    func testParseSendCommand() {
        let msg = makeMessage(content: "/send my-project run tests")
        let cmd = CommandParser.parse(msg)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.command, "send")
        XCTAssertEqual(cmd?.args, "my-project run tests")
    }

    func testParseHelpCommand() {
        let msg = makeMessage(content: "/help")
        let cmd = CommandParser.parse(msg)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.command, "help")
    }

    func testNonCommandReturnsNil() {
        let msg = makeMessage(content: "hello world")
        let cmd = CommandParser.parse(msg)
        XCTAssertNil(cmd)
    }

    func testEmptyMessageReturnsNil() {
        let msg = makeMessage(content: "")
        let cmd = CommandParser.parse(msg)
        XCTAssertNil(cmd)
    }

    func testSlashOnlyReturnsNil() {
        let msg = makeMessage(content: "/")
        let cmd = CommandParser.parse(msg)
        XCTAssertNil(cmd)
    }

    func testCommandIsCaseInsensitive() {
        let msg = makeMessage(content: "/STATUS")
        let cmd = CommandParser.parse(msg)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.command, "status")
    }

    func testCommandWithLeadingWhitespace() {
        let msg = makeMessage(content: "  /idea  trim this  ")
        let cmd = CommandParser.parse(msg)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.command, "idea")
        XCTAssertEqual(cmd?.args, "trim this")
    }

    func testPreservesRawMessage() {
        let msg = makeMessage(content: "/idea test")
        let cmd = CommandParser.parse(msg)
        XCTAssertEqual(cmd?.rawMessage.messageId, "msg-1")
    }
}
