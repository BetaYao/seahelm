import Foundation

// MARK: - Message Types

enum ChatType: String {
    case direct
    case group
}

enum MessageFormat: String {
    case text
    case markdown
    case templateCard
}

struct InboundMessage {
    let channelId: String
    let senderId: String
    let senderName: String
    let chatId: String?
    let chatType: ChatType
    let content: String
    let messageId: String
    let timestamp: Date
    let replyTo: String?
    let metadata: [String: Any]?
}

struct OutboundMessage {
    let channelId: String
    let targetChatId: String?
    let targetUserId: String?
    let content: String
    let format: MessageFormat
    let replyToMessageId: String?
    let streaming: Bool
    let streamId: String?

    init(channelId: String, targetChatId: String? = nil, targetUserId: String? = nil,
         content: String, format: MessageFormat = .text,
         replyToMessageId: String? = nil, streaming: Bool = false, streamId: String? = nil) {
        self.channelId = channelId
        self.targetChatId = targetChatId
        self.targetUserId = targetUserId
        self.content = content
        self.format = format
        self.replyToMessageId = replyToMessageId
        self.streaming = streaming
        self.streamId = streamId
    }
}

// MARK: - ExternalChannel Protocol

enum ExternalChannelType: String {
    case wecom
    case wechat
}

protocol ExternalChannel: AnyObject {
    var channelId: String { get }
    var channelType: ExternalChannelType { get }
    var gatewayState: GatewayState { get }

    /// Called by the channel when a message arrives from the external platform
    var onMessage: ((InboundMessage) -> Void)? { get set }

    /// Send a message out to the external platform
    func send(_ message: OutboundMessage)

    /// Connection management
    func connect()
    func disconnect()
}
