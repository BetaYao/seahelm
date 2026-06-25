import XCTest
@testable import seahelm

final class WeComFrameParserTests: XCTestCase {

    // MARK: - Parse Incoming Frames

    func testParseMessageCallback() {
        let json = """
        {
            "cmd": "aibot_msg_callback",
            "headers": { "req_id": "req-001" },
            "body": {
                "msgid": "msg-123",
                "aibotid": "aib-001",
                "chatid": "group-456",
                "chattype": "group",
                "from": { "userid": "matt", "name": "Matt" },
                "msgtype": "text",
                "text": { "content": "@Bot /status" }
            }
        }
        """.data(using: .utf8)!

        let frame = WeComFrameParser.parse(json)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.cmd, "aibot_msg_callback")
        XCTAssertEqual(frame?.reqId, "req-001")
    }

    func testParseEventCallback() {
        let json = """
        {
            "cmd": "aibot_event_callback",
            "headers": { "req_id": "req-002" },
            "body": {
                "event_type": "enter_chat",
                "chatid": "group-456"
            }
        }
        """.data(using: .utf8)!

        let frame = WeComFrameParser.parse(json)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.cmd, "aibot_event_callback")
    }

    func testParseInvalidJSON() {
        let json = "not json".data(using: .utf8)!
        XCTAssertNil(WeComFrameParser.parse(json))
    }

    func testParseMissingCmd() {
        let json = """
        { "headers": { "req_id": "r1" }, "body": {} }
        """.data(using: .utf8)!
        XCTAssertNil(WeComFrameParser.parse(json))
    }

    // MARK: - Frame → InboundMessage

    func testToInboundMessageText() {
        let json = """
        {
            "cmd": "aibot_msg_callback",
            "headers": { "req_id": "req-001" },
            "body": {
                "msgid": "msg-123",
                "aibotid": "aib-001",
                "chatid": "group-456",
                "chattype": "group",
                "from": { "userid": "matt", "name": "Matt" },
                "msgtype": "text",
                "text": { "content": "@Bot /idea new feature" }
            }
        }
        """.data(using: .utf8)!

        let frame = WeComFrameParser.parse(json)!
        let msg = WeComFrameParser.toInboundMessage(frame, channelId: "wecom-1")
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.channelId, "wecom-1")
        XCTAssertEqual(msg?.senderId, "matt")
        XCTAssertEqual(msg?.senderName, "Matt")
        XCTAssertEqual(msg?.chatId, "group-456")
        XCTAssertEqual(msg?.chatType, .group)
        XCTAssertEqual(msg?.content, "/idea new feature")
        XCTAssertEqual(msg?.messageId, "msg-123")
    }

    func testToInboundMessageStripsMention() {
        let json = """
        {
            "cmd": "aibot_msg_callback",
            "headers": { "req_id": "req-001" },
            "body": {
                "msgid": "msg-123",
                "chattype": "group",
                "from": { "userid": "matt", "name": "Matt" },
                "msgtype": "text",
                "text": { "content": "@Bot hello world" }
            }
        }
        """.data(using: .utf8)!

        let frame = WeComFrameParser.parse(json)!
        let msg = WeComFrameParser.toInboundMessage(frame, channelId: "ch")
        XCTAssertEqual(msg?.content, "hello world")
    }

    func testToInboundMessageDirectChat() {
        let json = """
        {
            "cmd": "aibot_msg_callback",
            "headers": { "req_id": "req-001" },
            "body": {
                "msgid": "msg-456",
                "chattype": "single",
                "from": { "userid": "matt", "name": "Matt" },
                "msgtype": "text",
                "text": { "content": "/help" }
            }
        }
        """.data(using: .utf8)!

        let frame = WeComFrameParser.parse(json)!
        let msg = WeComFrameParser.toInboundMessage(frame, channelId: "ch")
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.chatType, .direct)
        XCTAssertNil(msg?.chatId)
    }

    func testNonMessageFrameReturnsNil() {
        let json = """
        {
            "cmd": "aibot_event_callback",
            "headers": { "req_id": "req-001" },
            "body": { "event_type": "enter_chat" }
        }
        """.data(using: .utf8)!

        let frame = WeComFrameParser.parse(json)!
        let msg = WeComFrameParser.toInboundMessage(frame, channelId: "ch")
        XCTAssertNil(msg)
    }

    // MARK: - OutboundMessage → Send Frame

    func testToSendFrame() {
        let outbound = OutboundMessage(
            channelId: "ch", targetChatId: "group-1",
            content: "Hello!", format: .text
        )
        let data = WeComFrameParser.toSendFrame(outbound, botId: "aib-001")
        XCTAssertNotNil(data)

        let json = try? JSONSerialization.jsonObject(with: data!) as? [String: Any]
        XCTAssertEqual(json?["cmd"] as? String, "aibot_send_msg")
        let body = json?["body"] as? [String: Any]
        XCTAssertEqual(body?["chatid"] as? String, "group-1")
    }

    func testToSendFrameMarkdown() {
        let outbound = OutboundMessage(
            channelId: "ch", targetChatId: "group-1",
            content: "**bold**", format: .markdown
        )
        let data = WeComFrameParser.toSendFrame(outbound, botId: "aib-001")
        XCTAssertNotNil(data)

        let json = try? JSONSerialization.jsonObject(with: data!) as? [String: Any]
        let body = json?["body"] as? [String: Any]
        XCTAssertEqual(body?["msgtype"] as? String, "markdown")
    }

    // MARK: - Subscribe Frame

    func testSubscribeFrame() {
        let data = WeComFrameParser.subscribeFrame(botId: "aib-001", secret: "s3cr3t")
        XCTAssertNotNil(data)

        let json = try? JSONSerialization.jsonObject(with: data!) as? [String: Any]
        XCTAssertEqual(json?["cmd"] as? String, "aibot_subscribe")
        let body = json?["body"] as? [String: Any]
        XCTAssertEqual(body?["bot_id"] as? String, "aib-001")
        XCTAssertEqual(body?["secret"] as? String, "s3cr3t")
    }

    // MARK: - Respond Frame

    func testToRespondFrame() {
        let outbound = OutboundMessage(
            channelId: "ch", content: "reply text", format: .markdown,
            replyToMessageId: "msg-1"
        )
        let data = WeComFrameParser.toRespondFrame(outbound, reqId: "req-001")
        XCTAssertNotNil(data)

        let json = try? JSONSerialization.jsonObject(with: data!) as? [String: Any]
        XCTAssertEqual(json?["cmd"] as? String, "aibot_respond_msg")
        let headers = json?["headers"] as? [String: Any]
        XCTAssertEqual(headers?["req_id"] as? String, "req-001")
    }
}
