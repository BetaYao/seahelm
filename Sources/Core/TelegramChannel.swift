import Foundation

/// Telegram channel — phone-side remote control through a bot.
///
/// The trade it makes: a real API in both directions, no permissions to grant,
/// works from any device with Telegram on it. The price is that seahelm now
/// holds a network connection open — long polling `getUpdates` on a thread of
/// its own — and that the bot's chat is public: the allowlist in
/// `TelegramConfig` is the only thing between a stranger and the fleet.
///
/// Long polling rather than a webhook because a desktop app has no public
/// address. Telegram holds each request open for up to thirty seconds and
/// answers the moment something arrives, so latency is the same and nothing is
/// exposed.
final class TelegramChannel: ExternalChannel {
    let channelId: String
    let channelType: ExternalChannelType = .telegram
    var onMessage: ((InboundMessage) -> Void)?
    var onStateChange: ((GatewayState) -> Void)?

    private var config: TelegramConfig
    private var stateMachine = GatewayStateMachine()
    private(set) var gatewayState: GatewayState = .disconnected

    private var api: TelegramBotAPI?
    /// Bumped by every connect and disconnect; a poll loop that finds its
    /// generation stale stops touching the channel.
    private var generation = 0
    private let lock = NSLock()
    private let sendQueue = DispatchQueue(label: "com.seahelm.telegram.send", qos: .utility)
    /// Lets `disconnect` cut a retry backoff short instead of waiting it out.
    private let wake = DispatchSemaphore(value: 0)

    /// So `/status@seahelm_bot` in a group parses as `/status`.
    private(set) var botUsername: String?
    /// Armed while the setup wizard is waiting for someone to tap Start.
    /// Consulted *before* the allowlist, which is the whole point: the person
    /// pairing is by definition not on it yet.
    private var pairing: TelegramPairingSession?
    /// Fires on the main thread when a code is claimed. The owner writes the
    /// allowlist; the channel only reports who it was.
    var onPaired: ((TelegramPairingResult) -> Void)?
    /// Chat each user last gave an order from, so a reply addressed to a user
    /// lands where they were talking.
    private var chatIdBySender: [String: String] = [:]
    /// The chat the most recent order came from: the broadcast fallback when
    /// the config names no chat and no allowed user is numeric.
    private var lastCommandChatId: String?

    /// Where unbound fleet notifications go: configured default, else the chat
    /// that last issued an order.
    var fleetNotifyChatId: String? {
        lock.lock()
        defer { lock.unlock() }
        return config.resolvedDefaultChatId ?? lastCommandChatId
    }

    private static let maxBackoff: TimeInterval = 30
    /// Attempts per outbound chunk before the rest of the message is abandoned.
    private static let sendAttempts = 3
    private static let sendRetryDelay: TimeInterval = 1

    init(config: TelegramConfig, channelId: String = "telegram") {
        self.config = config
        self.channelId = channelId
    }

    deinit { disconnect() }

    // MARK: - ExternalChannel

    func connect() {
        guard stateMachine.transition(to: .connecting) else { return }
        gatewayState = stateMachine.state
        onStateChange?(gatewayState)

        lock.lock()
        generation += 1
        let gen = generation
        let cfg = config
        lock.unlock()

        guard let token = cfg.resolvedBotToken else {
            updateState(.error("No Telegram bot token configured"))
            return
        }

        let api = TelegramBotAPI(token: token)
        lock.lock()
        self.api = api
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.run(api: api, config: cfg, generation: gen)
        }
        thread.name = "com.seahelm.telegram.poll"
        thread.qualityOfService = .utility
        thread.start()
    }

    func disconnect() {
        lock.lock()
        generation += 1
        let api = self.api
        self.api = nil
        lock.unlock()

        api?.invalidate()
        wake.signal()
        updateState(.disconnected)
    }

    func send(_ message: OutboundMessage) {
        lock.lock()
        let cfg = config
        let api = self.api
        let bySender = chatIdBySender
        let last = lastCommandChatId
        lock.unlock()

        guard let api else {
            NSLog("[Telegram] Dropping outbound: bridge not connected")
            return
        }

        // Replies carry the originating chat. Broadcasts (agent-finished
        // notifications) carry nothing and go to the configured chat — or,
        // failing that, wherever the last order came from.
        let target = message.targetChatId
            ?? message.targetUserId.flatMap { bySender[$0] ?? (TelegramConfig.isNumericId($0) ? $0 : nil) }
            ?? cfg.resolvedDefaultChatId
            ?? last

        guard let target, !target.isEmpty else {
            NSLog("[Telegram] Dropping outbound: no recipient configured")
            return
        }

        let parseMode: String? = message.format == .text ? nil : "HTML"
        let rendered = parseMode == nil ? message.content : TelegramFormatter.html(from: message.content)

        sendQueue.async { [weak self] in
            guard let self else { return }
            let chunks = TelegramFormatter.chunk(rendered)
            for (index, chunk) in chunks.enumerated() {
                guard self.sendChunk(api: api, target: target, chunk: chunk, parseMode: parseMode) else {
                    // Say how much was lost. A long answer that stops mid-way
                    // with nothing to mark the cut reads as the agent having
                    // said only that much.
                    NSLog("[Telegram] Gave up with \(chunks.count - index) of \(chunks.count) chunk(s) unsent")
                    return
                }
            }
        }
    }

    /// One chunk, retried. A multi-part answer that loses its second part to a
    /// transient network error is worse than one that arrives late: the reader
    /// gets a truncated message and nothing tells them it was cut.
    private func sendChunk(api: TelegramBotAPI, target: String, chunk: String, parseMode: String?) -> Bool {
        for attempt in 1...Self.sendAttempts {
            do {
                try api.sendMessage(chatId: target, text: chunk, parseMode: parseMode)
                NSLog("[Telegram] → \(target): \(chunk.count) chars")
                return true
            } catch let error as TelegramAPIError where error.isBadRequest && parseMode != nil {
                // Telegram is strict about its HTML. Rather than lose the
                // message over a stray tag, resend the same words flat.
                do {
                    try api.sendMessage(chatId: target, text: TelegramFormatter.stripHTML(chunk), parseMode: nil)
                    return true
                } catch {
                    NSLog("[Telegram] Send failed (flat): \(error.localizedDescription)")
                    return false
                }
            } catch TelegramAPIError.cancelled {
                return false
            } catch {
                NSLog("[Telegram] Send attempt \(attempt)/\(Self.sendAttempts) failed: \(error.localizedDescription)")
                if attempt < Self.sendAttempts { Thread.sleep(forTimeInterval: Self.sendRetryDelay) }
            }
        }
        return false
    }

    // MARK: - Config

    /// Swap the allowlist and rules without reconnecting — both are consulted
    /// per message. A token change needs a new channel; the owner handles that.
    func update(config: TelegramConfig) {
        lock.lock()
        self.config = config
        lock.unlock()
    }

    /// Arm (or, with nil, disarm) pairing. Live for as long as the wizard is on
    /// screen: a code that outlived its window would be a second, quieter
    /// allowlist.
    func armPairing(_ session: TelegramPairingSession?) {
        lock.lock()
        pairing = session
        lock.unlock()
    }

    // MARK: - Poll loop

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == gen
    }

    private func run(api: TelegramBotAPI, config cfg: TelegramConfig, generation gen: Int) {
        // Validate the token before anything else. A network failure here is
        // retried — the app may be launching before Wi-Fi is up — but a token
        // Telegram rejects is final.
        guard let me = retrying(generation: gen, "getMe", { try api.getMe() }) else { return }
        botUsername = me.username
        NSLog("[Telegram] Connected as @\(me.username ?? String(me.id))")

        // The offset is the one piece of state the loop owns: everything below
        // it has been acknowledged to Telegram and will not be sent again.
        var offset: Int?
        guard retrying(generation: gen, "backlog", { try skipBacklog(api: api, config: cfg, offset: &offset) }) != nil,
              isCurrent(gen) else { return }
        updateState(.connected)

        while true {
            guard let updates = retrying(generation: gen, "poll", {
                try api.getUpdates(offset: offset, timeout: TelegramBotAPI.longPollSeconds)
            }), isCurrent(gen) else { return }

            lock.lock()
            let live = config
            lock.unlock()
            for update in updates {
                offset = max(offset ?? 0, update.updateId + 1)
                if let message = update.payload { handle(message, config: live) }
            }
        }
    }

    /// Runs `work` until it succeeds, backing off between attempts. Gives up —
    /// returning nil — on cancellation, on a newer generation, or on an API
    /// error retrying cannot fix, which becomes the channel's error state.
    private func retrying<T>(generation gen: Int, _ label: String, _ work: () throws -> T) -> T? {
        var backoff: TimeInterval = 1
        while isCurrent(gen) {
            do {
                return try work()
            } catch TelegramAPIError.cancelled {
                return nil
            } catch let error as TelegramAPIError where error.isFatal {
                updateState(.error(error.localizedDescription))
                return nil
            } catch {
                NSLog("[Telegram] \(label) failed: \(error.localizedDescription) — retrying in \(Int(backoff))s")
                _ = wake.wait(timeout: .now() + backoff)
                backoff = min(backoff * 2, Self.maxBackoff)
            }
        }
        return nil
    }

    /// Drain what Telegram has queued for this bot. Anything older than the
    /// backfill window is acknowledged and dropped — enabling the bridge must
    /// not replay yesterday as orders — while recent messages are delivered,
    /// covering the gap between a text and the app launching.
    ///
    /// `offset` is advanced page by page rather than returned at the end, so a
    /// failure partway through resumes after what was already handled instead
    /// of handing it to the agent twice.
    private func skipBacklog(api: TelegramBotAPI, config cfg: TelegramConfig, offset: inout Int?) throws {
        let cutoff = Date().addingTimeInterval(-cfg.resolvedBackfillSeconds)
        while true {
            let updates = try api.getUpdates(offset: offset, timeout: 0)
            guard let lastId = updates.last?.updateId else { return }
            for update in updates {
                guard let message = update.payload, message.timestamp >= cutoff else { continue }
                handle(message, config: cfg)
            }
            offset = lastId + 1
        }
    }

    // MARK: - Inbound

    private func handle(_ message: TelegramMessage, config cfg: TelegramConfig) {
        guard let text = message.body?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        let chatId = String(message.chat.id)

        // `/start` is Telegram's own front door: the Start button sends it, and
        // a `t.me/<bot>?start=<code>` deep link sends it with the pairing code
        // attached. It is answered here and never reaches the verb table, which
        // has no such verb and would only reply "unknown command".
        if let payload = TelegramPairingCode.startPayload(
            in: Self.stripBotMention(text, botUsername: botUsername)) {
            handleStart(payload: payload, message: message, config: cfg)
            return
        }

        if let command = Self.command(in: message, config: cfg, botUsername: botUsername) {
            lock.lock()
            chatIdBySender[command.senderId] = chatId
            lastCommandChatId = chatId
            lock.unlock()
            NSLog("[Telegram] ← \(command.senderName) in \(chatId): \(command.body.prefix(80))")

            onMessage?(InboundMessage(
                channelId: channelId,
                senderId: command.senderId,
                senderName: command.senderName,
                chatId: chatId,
                chatType: message.chat.isPrivate ? .direct : .group,
                content: command.body,
                messageId: String(message.messageId),
                timestamp: message.timestamp,
                replyTo: nil,
                metadata: nil
            ))
            return
        }

        deliverSignal(message, text: text, config: cfg)
    }

    /// Answer `/start`.
    ///
    /// Which of the three cases applies turns on whether a code is armed, not
    /// on who sent the message: pairing exists precisely because the sender is
    /// a stranger to the allowlist at the moment they use it.
    private func handleStart(payload: String, message: TelegramMessage, config cfg: TelegramConfig) {
        // A channel post carries no user, and an allowlist entry has to name
        // one. Nothing to pair with.
        guard let from = message.from else { return }
        let chatId = String(message.chat.id)

        lock.lock()
        let session = pairing
        lock.unlock()

        if let session {
            if !payload.isEmpty {
                guard session.claim(payload) else {
                    // Wrong, spent or expired — but a code *is* armed and this
                    // person is looking at a QR that just failed them, so say
                    // so rather than leave them tapping Start again.
                    reply(chatId, "That pairing code has expired or was already used. "
                                + "Generate a new one in seahelm ▸ Settings ▸ Telegram.")
                    return
                }
                let result = TelegramPairingResult(userId: String(from.id),
                                                   displayName: from.displayName,
                                                   chatId: chatId)
                NSLog("[Telegram] Paired with \(from.displayName) (\(from.id)) in chat \(chatId)")
                reply(chatId, "**Paired.** This chat can command the fleet now.\n\n"
                            + "`/status` lists what is running, `/help` lists the commands, "
                            + "and anything without a slash goes straight to the agent you are talking to.")
                DispatchQueue.main.async { [weak self] in self?.onPaired?(result) }
                return
            }
            if !cfg.allows(user: from) {
                // Found the bot without the deep link — an easy thing to do,
                // since Telegram opens a Start button on any bot you search
                // for. Point them at the code rather than stonewall.
                reply(chatId, "Send me the 8-character pairing code shown in "
                            + "seahelm ▸ Settings ▸ Telegram to connect this chat.")
                return
            }
        }

        // A bare Start from someone already trusted gets the usual Telegram
        // greeting. From anyone else, silence: an unpaired bot must not confirm
        // to a stranger that it is attached to a working fleet.
        if cfg.allows(user: from) {
            reply(chatId, "**seahelm** is connected. `/status` lists the fleet, `/help` lists the commands.")
        } else {
            NSLog("[Telegram] Ignoring /start from unlisted user \(from.displayName) (\(from.id))")
        }
    }

    private func reply(_ chatId: String, _ markdown: String) {
        send(OutboundMessage(channelId: channelId, targetChatId: chatId,
                             content: markdown, format: .markdown))
    }

    /// A message that is not an order may still be work: a monitoring channel
    /// the bot was added to, a colleague in a group, a stranger asking. Run it
    /// past the rules and, on a match, hand the rendered prompt up as an
    /// inbound carrying `ruleTarget` metadata — the router uses that to inject
    /// rather than reply.
    ///
    /// An allowed user's own words are never a signal: from them a line is an
    /// order or (in a group) conversation, and letting conversation fire
    /// agents would make every shared group unusable.
    private func deliverSignal(_ message: TelegramMessage, text: String, config cfg: TelegramConfig) {
        guard !cfg.resolvedRules.isEmpty else { return }
        if let from = message.from, cfg.allows(user: from) { return }

        let sender = Self.signalSender(of: message)
        guard let match = TelegramRuleEngine.firstMatch(rules: cfg.resolvedRules,
                                                        sender: sender,
                                                        text: text) else { return }

        NSLog("[Telegram] Rule '\(match.rule.name)' matched from \(sender)")
        onMessage?(InboundMessage(
            channelId: channelId,
            senderId: sender,
            senderName: sender,
            chatId: String(message.chat.id),
            chatType: message.chat.isPrivate ? .direct : .group,
            content: match.prompt,
            messageId: String(message.messageId),
            timestamp: message.timestamp,
            replyTo: nil,
            metadata: [
                "ruleName": match.rule.name,
                "ruleTarget": match.rule.target,
            ]
        ))
    }

    struct Command: Equatable {
        let body: String
        /// Telegram user id, as a string — stable where usernames are not.
        let senderId: String
        let senderName: String
    }

    /// Decide whether one message is an order, and from whom.
    ///
    /// Two gates:
    ///
    /// 1. **Sender** — it must come from a user on the allowlist. Channel
    ///    posts and anonymous group admins carry no user at all and so can
    ///    never be orders, only signals.
    /// 2. **Chat** — in a private chat with the bot everything is an order,
    ///    prose included, because there is nobody else to be talking to. In a
    ///    group only a `/command` is: bare prose there is conversation, and a
    ///    stray line in a shared group must not steer an agent.
    ///
    /// No echo guard is needed. The bot's own messages never come back as
    /// updates — that was the whole trouble with a transport that shared the
    /// owner's identity.
    static func command(in message: TelegramMessage,
                        config: TelegramConfig,
                        botUsername: String?) -> Command? {
        guard let text = message.body?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        guard let from = message.from else { return nil }
        guard config.allows(user: from) else {
            // Logged only when it looked like an order; group chatter from
            // colleagues would otherwise fill the log.
            if text.hasPrefix("/") {
                NSLog("[Telegram] Ignoring command from unlisted user \(from.displayName) (\(from.id))")
            }
            return nil
        }

        let body = stripBotMention(text, botUsername: botUsername)
        guard message.chat.isPrivate || body.hasPrefix("/") else { return nil }
        return Command(body: body, senderId: String(from.id), senderName: from.displayName)
    }

    /// `/status@seahelm_bot` is how Telegram disambiguates commands in a group
    /// with several bots; the suffix means nothing to the grammar.
    static func stripBotMention(_ text: String, botUsername: String?) -> String {
        guard text.hasPrefix("/"), let name = botUsername, !name.isEmpty else { return text }
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        var head = String(parts[0])
        let suffix = "@\(name)"
        if head.lowercased().hasSuffix(suffix.lowercased()) {
            head = String(head.dropLast(suffix.count))
        }
        return parts.count > 1 ? head + " " + parts[1] : head
    }

    /// What a rule's `from` pattern sees: a user's `@username` (or id when they
    /// have none), a channel's `@username` or title.
    static func signalSender(of message: TelegramMessage) -> String {
        if let from = message.from {
            return from.username.map { "@\($0)" } ?? String(from.id)
        }
        let chat = message.senderChat ?? message.chat
        if let username = chat.username, !username.isEmpty { return "@\(username)" }
        if let title = chat.title, !title.isEmpty { return title }
        return String(chat.id)
    }

    // MARK: - State

    private func updateState(_ newState: GatewayState) {
        lock.lock()
        let changed = stateMachine.transition(to: newState)
        let state = stateMachine.state
        lock.unlock()
        guard changed else { return }
        gatewayState = state
        if case .error(let msg) = newState { NSLog("[Telegram] \(msg)") }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStateChange?(self.gatewayState)
        }
    }
}
