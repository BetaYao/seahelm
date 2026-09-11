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

/// A button drawn beside an outbound message.
///
/// `token` is minted by `ChatCallbackRegistry` and means nothing to the
/// channel: it carries it out, and carries it back when someone taps. That is
/// deliberate — Telegram allows 64 bytes of callback data, which is less than
/// a card id, and what travels over the wire and sits in a chat's history
/// forever should not be a path on this machine either.
struct MessageButton: Equatable {
    let label: String
    let token: String
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
    /// An optional logical packet id. Channels may coalesce duplicate sends of
    /// the same packet without suppressing ordinary messages that happen to
    /// have identical text.
    let packetKey: String?
    /// Drawn under the message by channels that can. Always a shortcut for
    /// something the text says how to type, so dropping them costs nothing.
    let buttons: [MessageButton]

    init(channelId: String, targetChatId: String? = nil, targetUserId: String? = nil,
         content: String, format: MessageFormat = .text,
         replyToMessageId: String? = nil, streaming: Bool = false, streamId: String? = nil,
         buttons: [MessageButton] = []) {
        self.init(channelId: channelId, targetChatId: targetChatId, targetUserId: targetUserId,
                  content: content, format: format, replyToMessageId: replyToMessageId,
                  streaming: streaming, streamId: streamId, buttons: buttons, packetKey: nil)
    }

    init(channelId: String, targetChatId: String? = nil, targetUserId: String? = nil,
         content: String, format: MessageFormat = .text,
         replyToMessageId: String? = nil, streaming: Bool = false, streamId: String? = nil,
         buttons: [MessageButton] = [], packetKey: String?) {
        self.channelId = channelId
        self.targetChatId = targetChatId
        self.targetUserId = targetUserId
        self.content = content
        self.format = format
        self.replyToMessageId = replyToMessageId
        self.streaming = streaming
        self.streamId = streamId
        self.buttons = buttons
        self.packetKey = packetKey
    }
}

/// Someone tapped a button on a message this channel sent.
///
/// Not an `InboundMessage`: nothing was said, and the tap carries the message
/// it came from so the buttons can be taken off once it is handled.
struct InboundCallback {
    let channelId: String
    let senderId: String
    let senderName: String
    let chatId: String
    /// The message the button was attached to.
    let messageId: String
    /// What the button means — resolve through `ChatCallbackRegistry`.
    let token: String
}

// MARK: - ExternalChannel Protocol

enum ExternalChannelType: String {
    case telegram
}

protocol ExternalChannel: AnyObject {
    var channelId: String { get }
    var channelType: ExternalChannelType { get }
    var gatewayState: GatewayState { get }

    /// Called by the channel when a message arrives from the external platform
    var onMessage: ((InboundMessage) -> Void)? { get set }

    /// Called when someone taps a button on a message this channel sent.
    /// Separate from `onMessage` because nothing was said: see `InboundCallback`.
    var onCallback: ((InboundCallback) -> Void)? { get set }

    /// Send a message out to the external platform
    func send(_ message: OutboundMessage)

    /// Send, and report the id of the message the buttons hang under, so the
    /// caller can come back and change them. Nil when nothing was sent.
    func send(_ message: OutboundMessage, completion: ((String?) -> Void)?)

    /// Change the buttons on a message this channel already sent; `[]` takes
    /// them off. Channels that cannot edit what they sent do nothing.
    ///
    /// Both directions are needed. A card that has been answered must not go
    /// on offering its options — on the phone that message stays in the
    /// history forever — and an agent's suggested next steps are added to the
    /// completion notice they belong under rather than sent as a second
    /// message repeating it.
    func setButtons(chatId: String, messageId: String, buttons: [MessageButton])

    /// Rewrite the text of a message this channel already sent, and take one
    /// back. Both exist for the same thing: a line reporting what an agent is
    /// doing *while* it does it is one message edited over and over and then
    /// removed, not a stream of new ones. Both are best effort — a channel that
    /// can do neither does nothing, and the reader loses only the liveness. The
    /// answer itself never travels this way.
    func editMessage(chatId: String, messageId: String, content: String, format: MessageFormat)
    func deleteMessage(chatId: String, messageId: String)

    /// Connection management
    func connect()
    func disconnect()
}

extension ExternalChannel {
    func send(_ message: OutboundMessage, completion: ((String?) -> Void)?) {
        send(message)
        completion?(nil)
    }

    func setButtons(chatId: String, messageId: String, buttons: [MessageButton]) {}

    func editMessage(chatId: String, messageId: String, content: String, format: MessageFormat) {}
    func deleteMessage(chatId: String, messageId: String) {}

    /// The common direction, named for what it means.
    func retireButtons(chatId: String, messageId: String) {
        setButtons(chatId: chatId, messageId: messageId, buttons: [])
    }
}
