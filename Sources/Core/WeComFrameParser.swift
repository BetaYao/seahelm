import Foundation

struct WeComFrame {
    let cmd: String
    let reqId: String
    let body: [String: Any]
}

enum WeComFrameParser {

    // MARK: - Parse Incoming

    /// Parse raw WebSocket data into a WeComFrame
    static func parse(_ data: Data) -> WeComFrame? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = json["cmd"] as? String else {
            return nil
        }
        let headers = json["headers"] as? [String: Any] ?? [:]
        let reqId = headers["req_id"] as? String ?? ""
        let body = json["body"] as? [String: Any] ?? [:]
        return WeComFrame(cmd: cmd, reqId: reqId, body: body)
    }

    /// Convert a message callback frame to an InboundMessage.
    /// Returns nil for non-message frames (events, heartbeats, etc.).
    static func toInboundMessage(_ frame: WeComFrame, channelId: String) -> InboundMessage? {
        guard frame.cmd == "aibot_msg_callback" else { return nil }

        let body = frame.body
        let msgtype = body["msgtype"] as? String ?? "text"
        guard msgtype == "text" else { return nil } // Phase 1: text only

        let from = body["from"] as? [String: Any] ?? [:]
        let textDict = body["text"] as? [String: Any] ?? [:]
        let rawContent = textDict["content"] as? String ?? ""
        let chatTypeStr = body["chattype"] as? String ?? "single"
        let isGroup = chatTypeStr == "group"

        // Strip @mention prefix in group messages
        let content = stripMention(rawContent)

        return InboundMessage(
            channelId: channelId,
            senderId: from["userid"] as? String ?? "",
            senderName: from["name"] as? String ?? from["userid"] as? String ?? "",
            chatId: isGroup ? body["chatid"] as? String : nil,
            chatType: isGroup ? .group : .direct,
            content: content,
            messageId: body["msgid"] as? String ?? UUID().uuidString,
            timestamp: Date(),
            replyTo: nil,
            metadata: body
        )
    }

    // MARK: - Build Outgoing

    /// Build an aibot_send_msg frame (proactive push)
    static func toSendFrame(_ message: OutboundMessage, botId: String) -> Data? {
        let isMarkdown = message.format == .markdown
        var body: [String: Any] = [
            "bot_id": botId,
            "msgtype": isMarkdown ? "markdown" : "text",
        ]

        if let chatId = message.targetChatId {
            body["chatid"] = chatId
        }
        if let userId = message.targetUserId {
            body["userid"] = userId
        }

        if isMarkdown {
            body["markdown"] = ["content": message.content]
        } else {
            body["text"] = ["content": message.content]
        }

        let frame: [String: Any] = [
            "cmd": "aibot_send_msg",
            "headers": ["req_id": UUID().uuidString],
            "body": body
        ]

        return try? JSONSerialization.data(withJSONObject: frame)
    }

    /// Build an aibot_respond_msg frame (passive reply)
    static func toRespondFrame(_ message: OutboundMessage, reqId: String) -> Data? {
        let isMarkdown = message.format == .markdown
        var body: [String: Any] = [
            "msgtype": isMarkdown ? "markdown" : "text",
        ]

        if isMarkdown {
            body["markdown"] = ["content": message.content]
        } else {
            body["text"] = ["content": message.content]
        }

        let frame: [String: Any] = [
            "cmd": "aibot_respond_msg",
            "headers": ["req_id": reqId],
            "body": body
        ]

        return try? JSONSerialization.data(withJSONObject: frame)
    }

    /// Build the aibot_subscribe authentication frame
    static func subscribeFrame(botId: String, secret: String) -> Data? {
        let frame: [String: Any] = [
            "cmd": "aibot_subscribe",
            "headers": ["req_id": UUID().uuidString],
            "body": [
                "bot_id": botId,
                "secret": secret
            ]
        ]
        return try? JSONSerialization.data(withJSONObject: frame)
    }

    // MARK: - Helpers

    /// Strip "@BotName " prefix from group message content
    private static func stripMention(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("@") {
            if let spaceIndex = trimmed.firstIndex(of: " ") {
                let afterMention = trimmed[trimmed.index(after: spaceIndex)...]
                return String(afterMention).trimmingCharacters(in: .whitespaces)
            }
        }
        return trimmed
    }
}
