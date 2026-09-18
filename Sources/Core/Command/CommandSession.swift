import Foundation

/// An action that asked first and is waiting for `/yes`.
struct PendingAction: Equatable {
    static let lifetime: TimeInterval = 60

    /// The line to run on confirmation — already carrying `force`.
    let line: ParsedLine
    let summary: String
    let expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt }
}

/// One surface's conversation with the fleet: which pane it is talking to.
///
/// The desktop's session is the dashboard selection and is never stored here;
/// this is for the surfaces that have no selection to look at — a Telegram
/// chat, a mail thread — each of which keeps its own binding, so a phone's
/// `/go` cannot move the desktop and a desktop click cannot redirect a phone.
struct CommandSession: Codable, Equatable {
    /// `telegram:<chat id>`, `mail:<thread id>`.
    let key: String
    /// `PaneHandleRegistry` key of the bound pane — what survives a relaunch.
    var boundPaneKey: String?
    /// Station id of the bound pane, for the close hook, which only has that.
    var boundPaneId: String?
    /// Fallback when a worktree was bound before it had a pane (`/go
    /// @worktree`, or `/new` racing the agent launch): the first pane to
    /// appear there is the one.
    var boundWorktreePath: String?
    /// Who bound it — for mail, the address the agent's output goes back to.
    var commander: String?
    /// The bound pane was closed. Kept rather than deleted so a mail thread
    /// can still be told its pane is gone.
    var closed: Bool
    /// seahelm opened this Telegram topic for the pane itself, rather than
    /// someone binding a topic that already existed.
    ///
    /// Two things turn on it. Inside such a topic prose is an order, because
    /// the thread is that pane's command line and nothing else. And when the
    /// pane ends, the topic is closed — which would be rude to do to a thread
    /// somebody else opened.
    var autoTopic: Bool
    /// The name the topic currently carries, so a rename is only spent when the
    /// pane's title has actually moved.
    var topicName: String?

    init(key: String, boundPaneKey: String? = nil, boundPaneId: String? = nil,
         boundWorktreePath: String? = nil, commander: String? = nil, closed: Bool = false,
         autoTopic: Bool = false, topicName: String? = nil) {
        self.key = key
        self.boundPaneKey = boundPaneKey
        self.boundPaneId = boundPaneId
        self.boundWorktreePath = boundWorktreePath
        self.commander = commander
        self.closed = closed
        self.autoTopic = autoTopic
        self.topicName = topicName
    }

    enum CodingKeys: String, CodingKey {
        case key, boundPaneKey, boundPaneId, boundWorktreePath, commander, closed
        case autoTopic, topicName
    }

    /// Hand-written so a store written before auto-topics still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        boundPaneKey = try c.decodeIfPresent(String.self, forKey: .boundPaneKey)
        boundPaneId = try c.decodeIfPresent(String.self, forKey: .boundPaneId)
        boundWorktreePath = try c.decodeIfPresent(String.self, forKey: .boundWorktreePath)
        commander = try c.decodeIfPresent(String.self, forKey: .commander)
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed) ?? false
        autoTopic = try c.decodeIfPresent(Bool.self, forKey: .autoTopic) ?? false
        topicName = try c.decodeIfPresent(String.self, forKey: .topicName)
    }

    static func key(surface: String, id: String) -> String { "\(surface):\(id)" }

    /// The part before the first colon: `telegram`, `mail`.
    var surface: String { String(key.prefix { $0 != ":" }) }
    /// The part after it — a chat id, a thread id.
    var id: String {
        guard let colon = key.firstIndex(of: ":") else { return key }
        return String(key[key.index(after: colon)...])
    }
}

/// Persists sessions; holds pending confirmations in memory only.
final class CommandSessionStore {
    static let defaultURL = Config.configDir.appendingPathComponent("command-sessions.json")
    /// The mail bindings this store replaced; imported once, then ignored.
    static let legacyMailURL = Config.configDir.appendingPathComponent("gmail-mail-conversations.json")

    /// Nil keeps everything in memory — tests, and the headless fallback.
    private let url: URL?
    private let queue = DispatchQueue(label: "seahelm.command-sessions")
    private var sessions: [String: CommandSession] = [:]
    private var pending: [String: PendingAction] = [:]

    init(url: URL? = CommandSessionStore.defaultURL, legacyMailURL: URL? = CommandSessionStore.legacyMailURL) {
        self.url = url
        guard let url else { return }
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode([String: CommandSession].self, from: data) {
            sessions = loaded
        } else if let legacyMailURL, let data = try? Data(contentsOf: legacyMailURL) {
            sessions = Self.importLegacyMail(data)
            persist()
        }
    }

    // MARK: - Sessions

    /// The session, or a fresh unbound one that is not stored until saved.
    func session(for key: String) -> CommandSession {
        queue.sync { sessions[key] ?? CommandSession(key: key) }
    }

    func save(_ session: CommandSession) {
        queue.sync {
            sessions[session.key] = session
            persist()
        }
    }

    func bind(_ key: String, toPaneKey paneKey: String, paneId: String, worktreePath: String,
              commander: String? = nil) {
        queue.sync {
            var session = sessions[key] ?? CommandSession(key: key)
            session.boundPaneKey = paneKey
            session.boundPaneId = paneId
            session.boundWorktreePath = worktreePath
            session.closed = false
            if let commander { session.commander = commander }
            sessions[key] = session
            persist()
        }
    }

    func bind(_ key: String, toWorktreePath path: String, commander: String? = nil) {
        queue.sync {
            var session = sessions[key] ?? CommandSession(key: key)
            session.boundPaneKey = nil
            session.boundPaneId = nil
            session.boundWorktreePath = path
            session.closed = false
            if let commander { session.commander = commander }
            sessions[key] = session
            persist()
        }
    }

    /// Bind a topic seahelm just opened to the pane it was opened for.
    ///
    /// Separate from `bind` because it also records the two things that make a
    /// topic *ours* — see `CommandSession.autoTopic`.
    func bindAutoTopic(_ key: String, toPaneKey paneKey: String, paneId: String,
                       worktreePath: String, topicName: String) {
        queue.sync {
            var session = sessions[key] ?? CommandSession(key: key)
            session.boundPaneKey = paneKey
            session.boundPaneId = paneId
            session.boundWorktreePath = worktreePath
            session.closed = false
            session.autoTopic = true
            session.topicName = topicName
            sessions[key] = session
            persist()
        }
    }

    /// The live topic seahelm opened for this pane, if it has one.
    func autoTopic(forPaneKey paneKey: String) -> CommandSession? {
        queue.sync {
            sessions.values.first { $0.autoTopic && !$0.closed && $0.boundPaneKey == paneKey }
        }
    }

    /// Every live topic seahelm opened, by address — what the channel needs to
    /// know which threads take bare prose as orders.
    func autoTopicAddresses() -> Set<String> {
        queue.sync {
            Set(sessions.values.filter { $0.autoTopic && !$0.closed && $0.surface == "telegram" }
                .map(\.id))
        }
    }

    /// Every live topic seahelm opened, as sessions — what a re-home sweep
    /// walks to decide which are now in the wrong group.
    func autoTopicSessions() -> [CommandSession] {
        queue.sync {
            sessions.values.filter { $0.autoTopic && !$0.closed && $0.surface == "telegram" }
        }
    }

    /// Forget a session outright.
    ///
    /// Not `close`: a closed session is one whose pane ended and is kept so it
    /// can still be told so. This is for a binding that should never have
    /// existed at this address — a topic that moved groups — where the pane is
    /// alive and must be free to open a fresh one.
    func remove(_ key: String) {
        queue.sync {
            guard sessions.removeValue(forKey: key) != nil else { return }
            persist()
        }
    }

    /// Record the name a topic now carries, after a successful rename.
    func noteTopicName(_ name: String, for key: String) {
        queue.sync {
            guard var session = sessions[key] else { return }
            session.topicName = name
            sessions[key] = session
            persist()
        }
    }

    func unbind(_ key: String) {
        queue.sync {
            guard var session = sessions[key] else { return }
            session.boundPaneKey = nil
            session.boundPaneId = nil
            session.boundWorktreePath = nil
            sessions[key] = session
            persist()
        }
    }

    /// Open sessions bound to this pane — every conversation that should hear
    /// what it says.
    func sessions(boundToPaneKey paneKey: String) -> [CommandSession] {
        queue.sync { sessions.values.filter { $0.boundPaneKey == paneKey && !$0.closed } }
    }

    /// Telegram chats that should hear a pane-status notification.
    ///
    /// Bound chats for `paneKey` always hear it. `fleetListenerChatIds` (the
    /// configured default / last-order chat) hear the whole fleet only while
    /// unbound — after `/go #n` they are silenced for every other pane, which
    /// is what binding is for.
    /// The result carries one address per chat: a pane collects bindings — a
    /// `/go` in the group, another in a topic, its own auto topic — and they
    /// are all the same room. Deduping here rather than at each call site is
    /// deliberate; the first fix missed two of the three and the duplicates
    /// came straight back. See `TelegramChatAddress.oneAddressPerChat`.
    func telegramChatsToNotify(paneKey: String?,
                               fleetListenerChatIds: [String]) -> [String] {
        queue.sync {
            var chats = Set<String>()
            if let paneKey {
                for session in sessions.values
                where session.surface == "telegram"
                    && !session.closed
                    && session.boundPaneKey == paneKey {
                    chats.insert(session.id)
                }
            }
            for chatId in fleetListenerChatIds {
                let session = sessions[CommandSession.key(surface: "telegram", id: chatId)]
                    ?? CommandSession(key: CommandSession.key(surface: "telegram", id: chatId))
                if session.boundPaneKey == nil || session.closed {
                    chats.insert(chatId)
                }
            }
            return TelegramChatAddress.oneAddressPerChat(
                Array(chats), preferring: paneKey.flatMap { key in
                    sessions.values.first { $0.autoTopic && !$0.closed && $0.boundPaneKey == key }?.id
                })
        }
    }

    /// Telegram addresses bound to this pane, one per chat — what a progress
    /// line edits in place, and why it must not open three of them in one room.
    func telegramChats(boundToPaneKey paneKey: String) -> [String] {
        queue.sync {
            let bound = sessions.values.filter {
                $0.surface == "telegram" && !$0.closed && $0.boundPaneKey == paneKey
            }
            return TelegramChatAddress.oneAddressPerChat(
                bound.map(\.id), preferring: bound.first(where: \.autoTopic)?.id)
        }
    }

    /// Mark every session bound to this pane closed. Returns them, so the
    /// caller can clean up whatever else the binding owned.
    @discardableResult
    func close(paneId: String) -> [CommandSession] {
        queue.sync {
            var closed: [CommandSession] = []
            for (key, value) in sessions where value.boundPaneId == paneId && !value.closed {
                var changed = value
                changed.closed = true
                sessions[key] = changed
                closed.append(changed)
            }
            if !closed.isEmpty { persist() }
            return closed
        }
    }

    // MARK: - Pending confirmations

    func setPending(_ action: PendingAction, for key: String) {
        queue.sync { pending[key] = action }
    }

    func clearPending(for key: String) {
        queue.sync { _ = pending.removeValue(forKey: key) }
    }

    /// The live pending action, removed. Nil when there is none or it expired.
    func takePending(for key: String) -> PendingAction? {
        queue.sync {
            guard let action = pending.removeValue(forKey: key), !action.isExpired else { return nil }
            return action
        }
    }

    // MARK: - Persistence

    private func persist() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(sessions).write(to: url, options: .atomic)
    }

    /// The old per-thread mail store: `{ threadID: { paneSessionKey, paneID,
    /// worktreePath, closed, commander } }`.
    private struct LegacyConversation: Decodable {
        let paneSessionKey: String
        let paneID: String
        let worktreePath: String
        let closed: Bool
        let commander: String?
    }

    private static func importLegacyMail(_ data: Data) -> [String: CommandSession] {
        guard let legacy = try? JSONDecoder().decode([String: LegacyConversation].self, from: data) else { return [:] }
        var out: [String: CommandSession] = [:]
        for (threadID, conversation) in legacy {
            let key = CommandSession.key(surface: "mail", id: threadID)
            out[key] = CommandSession(
                key: key,
                boundPaneKey: PaneHandleRegistry.key(sessionKey: conversation.paneSessionKey, paneId: conversation.paneID),
                boundPaneId: conversation.paneID,
                boundWorktreePath: conversation.worktreePath.isEmpty ? nil : conversation.worktreePath,
                commander: conversation.commander,
                closed: conversation.closed)
        }
        return out
    }
}
