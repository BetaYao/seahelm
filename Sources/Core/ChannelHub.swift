import Foundation

/// The chat channels (Telegram, mail, …): inbound messages and button taps
/// routed to the command language, outbound pushes, edits, drafts and
/// buttons. Nothing here knows what an agent is doing; that is seahelm-core's
/// (docs/app-reads-core.md). Pulled out of `Fleet`, where it shared a
/// lock with the agent model; it moves to seahelm-gateway in time.
final class ChannelHub {
    static let shared = ChannelHub()

    private let lock = NSLock()
    private var externalChannels: [String: ExternalChannel] = [:]

    // MARK: - External Channel Management

    /// Register an external channel (Telegram, Slack, etc.)
    func registerChannel(_ channel: ExternalChannel) {
        lock.lock()
        externalChannels[channel.channelId] = channel
        lock.unlock()

        channel.onMessage = { [weak self] message in
            self?.handleInbound(message)
        }
        channel.onCallback = { [weak self] callback in
            self?.handleCallback(callback)
        }
        (channel as? TelegramChannel)?.onDraftStopped = { [weak self] chatId, draftId in
            self?.draftStopRoute?(chatId, draftId)
        }
        (channel as? TelegramChannel)?.onChatGone = { [weak self] chatId in
            self?.chatGoneRoute?(chatId)
        }
    }

    /// Unregister and disconnect an external channel
    func unregisterChannel(_ channelId: String) {
        lock.lock()
        let channel = externalChannels.removeValue(forKey: channelId)
        lock.unlock()

        channel?.disconnect()
    }

    /// Remove all external channels (for testing)
    func unregisterAllExternalChannels() {
        lock.lock()
        let channels = externalChannels
        externalChannels.removeAll()
        lock.unlock()

        for (_, channel) in channels {
            channel.disconnect()
        }
    }

    // MARK: - Inbound Message Handling

    /// Runs a chat line through the command language and replies. Set by
    /// `MainWindowController`, which owns the executor and the fleet; until
    /// then — tests, headless runs — a headless executor over an empty fleet
    /// answers instead.
    var commandRoute: ((_ text: String, _ surface: CommandSurface, _ reply: @escaping (CommandReply) -> Void) -> Void)?

    /// Resolves a chat button tap: what the token meant, and doing it. Set by
    /// `MainWindowController`, which owns the card queue and the panes. Until
    /// then a tap is answered as stale, which is also what an unrecognised
    /// token gets — the two are the same thing to the tapper.
    var callbackRoute: ((InboundCallback) -> Void)?

    /// Injects a rule-matched prompt into the pane a target names. Set by
    /// `MainWindowController`, which owns the pane list. Returns false when the
    /// target resolves to nothing.
    var ruleTriggerRoute: ((_ prompt: String, _ target: TelegramRuleTarget) -> Bool)?

    /// Merges rapid rule hits aimed at the same pane (Aliyun multi-threshold
    /// SMS, etc.) into one inject. Owned here so every inbound path — live
    /// bridge, tests — gets the same window without MainWindow wiring it.
    let ruleCoalescer = TelegramRuleCoalescer()

    func handleInbound(_ message: InboundMessage) {
        // Channels deliver from their own poll threads, and the executor
        // reads the dashboard's selection and moves it. Hop to main before any
        // of that touches AppKit.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handleInbound(message) }
            return
        }

        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // A rule-matched signal is dispatch, not conversation: inject and stay
        // silent. Replying would text an alerting service back — at best noise,
        // at worst an SMS to a shortcode that charges for it.
        //
        // Hits for one pane are coalesced for 30s so a same-second 80%+90%
        // alert burst becomes one agent turn instead of two overlapping ones.
        if let target = message.metadata?["ruleTarget"] as? TelegramRuleTarget {
            let ruleName = message.metadata?["ruleName"] as? String ?? "?"
            ruleCoalescer.enqueue(prompt: text, target: target, ruleName: ruleName) { [weak self] combined, t in
                if self?.ruleTriggerRoute?(combined, t) != true {
                    NSLog("[Telegram] Rule '\(ruleName)' matched but target \(t.kind.rawValue)=\(t.value) resolved to no pane")
                }
            }
            return
        }

        // One executor for every surface: the chat speaks the same language as
        // the desktop Helm line. The session is the chat, so each Telegram
        // conversation keeps its own binding.
        let surface = CommandSurface(
            sessionKey: CommandSession.key(surface: message.channelId, id: message.chatId ?? message.senderId),
            isDesktop: false,
            commander: message.senderId)
        let route = commandRoute ?? headlessCommandRoute
        route(text, surface) { [weak self] result in
            guard !result.text.isEmpty else { return }
            self?.reply(to: message, content: result.text, format: .markdown,
                        buttons: ChatCallbackRegistry.shared.buttons(for: result.buttons))
        }
    }

    /// A button tap, on the main thread. The channel reports it from its poll
    /// thread and the router walks the fleet and the card queue.
    func handleCallback(_ callback: InboundCallback) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handleCallback(callback) }
            return
        }
        callbackRoute?(callback)
    }

    /// What answers before the window has wired a host — tests, headless runs:
    /// the command language over an empty fleet, with nothing persisted.
    private lazy var headlessExecutor = CommandExecutor(host: HeadlessCommandHost.shared,
                                                        sessions: CommandSessionStore(url: nil, legacyMailURL: nil))
    private var headlessCommandRoute: (String, CommandSurface, @escaping (CommandReply) -> Void) -> Void {
        { [weak self] text, surface, reply in self?.headlessExecutor.run(text, surface: surface, reply: reply) }
    }

    /// Send a reply back through the same external channel
    private func reply(to message: InboundMessage, content: String, format: MessageFormat = .text,
                       buttons: [MessageButton] = []) {
        let outbound = OutboundMessage(
            channelId: message.channelId,
            targetChatId: message.chatId,
            targetUserId: message.chatId == nil ? message.senderId : nil,
            content: content,
            format: format,
            replyToMessageId: message.messageId,
            buttons: buttons
        )
        pushToChannel(message.channelId, message: outbound)
    }

    /// Push a message to a specific external channel. `completion` carries the
    /// sent message's id where the channel can report one — what a caller needs
    /// to come back and change that message's buttons.
    func pushToChannel(_ channelId: String, message: OutboundMessage,
                       completion: ((String?) -> Void)? = nil) {
        lock.lock()
        let channel = externalChannels[channelId]
        lock.unlock()

        guard let channel else {
            completion?(nil)
            return
        }
        channel.send(message, completion: completion)
    }

    /// Change the buttons on a message a channel already sent; `[]` takes them
    /// off. Channels that cannot edit their own messages do nothing.
    func setButtons(channelId: String, chatId: String, messageId: String, buttons: [MessageButton]) {
        lock.lock()
        let channel = externalChannels[channelId]
        lock.unlock()

        channel?.setButtons(chatId: chatId, messageId: messageId, buttons: buttons)
    }

    /// Rewrite a message a channel already sent, or take it back. Both are for
    /// the progress line — see `ChatProgressReporter` — and both are best
    /// effort: a channel that cannot edit its own messages does nothing.
    func editInChannel(_ channelId: String, chatId: String, messageId: String,
                       content: String, format: MessageFormat = .markdown) {
        lock.lock()
        let channel = externalChannels[channelId]
        lock.unlock()

        channel?.editMessage(chatId: chatId, messageId: messageId, content: content, format: format)
    }

    /// Stream a draft (Telegram private chats only; anything else ignores it).
    func draftInChannel(_ channelId: String, chatId: String, draftId: Int, content: String,
                        canStop: Bool) {
        lock.lock()
        let channel = externalChannels[channelId]
        lock.unlock()

        (channel as? TelegramChannel)?.sendDraft(chatId: chatId, draftId: draftId,
                                                 content: content, canStop: canStop)
    }

    /// Stop was pressed under a draft: `(chatId, draftId)`, on main. Set by
    /// `MainWindowController`, which knows which pane the chat is talking to.
    var draftStopRoute: ((String, Int) -> Void)?
    /// A Telegram chat can no longer be written to (bot removed, blocked, chat
    /// deleted). On main. Set by `MainWindowController`, which owns bindings.
    var chatGoneRoute: ((String) -> Void)?

    func deleteInChannel(_ channelId: String, chatId: String, messageId: String) {
        lock.lock()
        let channel = externalChannels[channelId]
        lock.unlock()

        channel?.deleteMessage(chatId: chatId, messageId: messageId)
    }

    /// Broadcast a message to all registered external channels
    func broadcast(_ content: String, format: MessageFormat = .text) {
        broadcast(content, format: format, excluding: [])
    }

    /// Like `broadcast`, but skip channel ids in `excluding` — used when the
    /// caller delivers Telegram itself with pane-scoped routing.
    func broadcast(_ content: String, format: MessageFormat = .text, excluding: Set<String>) {
        lock.lock()
        let channels = Array(externalChannels.values)
        lock.unlock()

        for channel in channels where !excluding.contains(channel.channelId) {
            let message = OutboundMessage(
                channelId: channel.channelId,
                content: content,
                format: format
            )
            channel.send(message)
        }
    }
}
