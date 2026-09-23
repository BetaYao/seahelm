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
enum TopicScope: String, Codable {
    case pane
    case worktree
}

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
    /// seahelm opened this Telegram topic for a worktree of its own, rather
    /// than someone binding a topic that already existed.
    ///
    /// Two things turn on it. Inside such a topic prose is an order, because
    /// the thread is that worktree's command line and nothing else. And when
    /// the worktree is deleted the topic goes with it — which would be
    /// unthinkable to do to a thread somebody else opened, where the binding is
    /// simply let go of and the room told. A *pane* ending is not that ending:
    /// the others in the worktree are still reporting there.
    var autoTopic: Bool
    /// The name the topic currently carries, so a rename is only spent when
    /// what it is called has actually moved.
    var topicName: String?
    /// What an auto-opened topic covers.
    ///
    /// One topic per *pane* is what shipped first, and on a real fleet it made
    /// the group's topic list too long to skim — twenty threads for work that
    /// lives in five worktrees. A topic now covers a **worktree**, and the panes
    /// in it share one thread.
    ///
    /// The value is stored rather than assumed because it is also the migration
    /// marker: a record written before this decodes as `.pane`, which is how the
    /// topics already opened are told apart from the ones opened since, and
    /// swept.
    var topicScope: TopicScope

    init(key: String, boundPaneKey: String? = nil, boundPaneId: String? = nil,
         boundWorktreePath: String? = nil, commander: String? = nil, closed: Bool = false,
         autoTopic: Bool = false, topicName: String? = nil,
         topicScope: TopicScope = .worktree) {
        self.key = key
        self.boundPaneKey = boundPaneKey
        self.boundPaneId = boundPaneId
        self.boundWorktreePath = boundWorktreePath
        self.commander = commander
        self.closed = closed
        self.autoTopic = autoTopic
        self.topicName = topicName
        self.topicScope = topicScope
    }

    enum CodingKeys: String, CodingKey {
        case key, boundPaneKey, boundPaneId, boundWorktreePath, commander, closed
        case autoTopic, topicName, topicScope
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
        // Absent means it was written before topics covered a worktree.
        topicScope = try c.decodeIfPresent(TopicScope.self, forKey: .topicScope) ?? .pane
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

    /// Bind a topic seahelm just opened to the worktree it was opened for.
    ///
    /// Separate from `bind` because it also records the things that make a topic
    /// *ours* — see `CommandSession.autoTopic`. The pane fields are the *current*
    /// target within that worktree, not the topic's identity: whoever spoke last
    /// is who a bare order goes to.
    func bindAutoTopic(_ key: String, toWorktreePath path: String,
                       paneKey: String?, paneId: String?, topicName: String) {
        queue.sync {
            var session = sessions[key] ?? CommandSession(key: key)
            session.boundPaneKey = paneKey
            session.boundPaneId = paneId
            session.boundWorktreePath = path
            session.closed = false
            session.autoTopic = true
            session.topicName = topicName
            session.topicScope = .worktree
            sessions[key] = session
            persist()
        }
    }

    /// The live topic seahelm opened for this worktree, if it has one.
    func autoTopic(forWorktreePath path: String) -> CommandSession? {
        queue.sync {
            sessions.values.first {
                $0.autoTopic && !$0.closed && $0.topicScope == .worktree
                    && $0.boundWorktreePath == path
            }
        }
    }

    /// Point a worktree's topic at the pane that just spoke, so a bare order
    /// follows the work rather than whichever pane happened to open the thread.
    /// Only moves what changed — every notice comes through here.
    func noteActivePane(_ paneKey: String, paneId: String, inWorktree path: String) {
        queue.sync {
            guard var session = sessions.values.first(where: {
                $0.autoTopic && !$0.closed && $0.topicScope == .worktree
                    && $0.boundWorktreePath == path
            }), session.boundPaneKey != paneKey else { return }
            session.boundPaneKey = paneKey
            session.boundPaneId = paneId
            sessions[session.key] = session
            persist()
        }
    }

    /// The topics opened back when one covered a single pane. Swept on launch:
    /// the fleet they describe no longer exists in that shape, and leaving them
    /// is leaving the very list that made this change necessary.
    func paneScopedAutoTopics() -> [CommandSession] {
        queue.sync {
            sessions.values.filter {
                $0.autoTopic && $0.topicScope == .pane && $0.surface == "telegram"
            }
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
    func telegramChatsToNotify(paneKey: String?, worktreePath: String?,
                               fleetListenerChatIds: [String]) -> [String] {
        queue.sync {
            var chats = Set<String>()
            for session in sessions.values
            where session.surface == "telegram" && !session.closed {
                // A topic seahelm opened covers a worktree, so every pane in it
                // reports to the same thread. A binding somebody made by hand is
                // still to the one pane they bound.
                let mine = session.autoTopic && session.topicScope == .worktree
                    ? (worktreePath != nil && session.boundWorktreePath == worktreePath)
                    : (paneKey != nil && session.boundPaneKey == paneKey)
                if mine { chats.insert(session.id) }
            }
            for chatId in fleetListenerChatIds {
                let session = sessions[CommandSession.key(surface: "telegram", id: chatId)]
                    ?? CommandSession(key: CommandSession.key(surface: "telegram", id: chatId))
                if session.boundPaneKey == nil || session.closed {
                    chats.insert(chatId)
                }
            }
            return TelegramChatAddress.oneAddressPerChat(
                Array(chats), preferring: worktreePath.flatMap { path in
                    sessions.values.first {
                        $0.autoTopic && !$0.closed && $0.topicScope == .worktree
                            && $0.boundWorktreePath == path
                    }?.id
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
            var repointed = false
            for (key, value) in sessions where value.boundPaneId == paneId && !value.closed {
                // A worktree's topic outlives the panes in it. The pane that
                // ended was only the thread's current target, so the pointer
                // goes and the conversation stays — the next pane to speak in
                // that worktree claims it.
                if value.autoTopic && value.topicScope == .worktree {
                    var changed = value
                    changed.boundPaneKey = nil
                    changed.boundPaneId = nil
                    sessions[key] = changed
                    repointed = true
                    continue
                }
                var changed = value
                changed.closed = true
                sessions[key] = changed
                closed.append(changed)
            }
            if !closed.isEmpty || repointed { persist() }
            return closed
        }
    }

    /// Close every conversation this worktree owns. The worktree going is what
    /// ends a topic seahelm opened for it — a pane ending is not, because the
    /// others in it are still talking.
    func close(worktreePath: String) -> [CommandSession] {
        queue.sync {
            var closed: [CommandSession] = []
            for (key, value) in sessions
            where value.boundWorktreePath == worktreePath && !value.closed {
                var changed = value
                changed.closed = true
                sessions[key] = changed
                closed.append(changed)
            }
            if !closed.isEmpty { persist() }
            return closed
        }
    }

    /// Mark one session closed, by key. Returns it when this call is what
    /// closed it, so a caller cannot clean the same binding up twice.
    @discardableResult
    func close(key: String) -> CommandSession? {
        queue.sync {
            guard var session = sessions[key], !session.closed else { return nil }
            session.closed = true
            sessions[key] = session
            persist()
            return session
        }
    }

    /// Every session, open or closed — what a reconciling sweep walks.
    func allSessions() -> [CommandSession] {
        queue.sync { Array(sessions.values) }
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

/// Which bindings have outlived the pane they were made for.
///
/// The app's own teardown paths let go of a binding as they close the pane, so
/// this is for the drift they cannot see: a worktree removed with `git
/// worktree remove` in some other terminal, or the app quitting between the
/// deletion and the cleanup. It is the rule alone, with no store and no
/// filesystem, because the interesting part is what it refuses to touch.
///
/// A binding is retired only on a *fact*: the worktree it names is no longer
/// on disk. Never because the pane could not be found — a pane that has not
/// finished restoring looks exactly the same, and the punishment for guessing
/// is a deleted thread. And never while the bound pane is alive: a pane that
/// followed its agent out of a worktree being deleted has moved, not ended,
/// and its conversation moves with it.
enum StaleChatBindings {
    static func stale(in sessions: [CommandSession],
                      worktreeExists: (String) -> Bool,
                      paneIsLive: (String) -> Bool) -> [CommandSession] {
        sessions.filter { session in
            guard !session.closed else { return false }
            guard let path = session.boundWorktreePath, !path.isEmpty else { return false }
            guard !worktreeExists(path) else { return false }
            if let paneId = session.boundPaneId, paneIsLive(paneId) { return false }
            return true
        }.sorted { $0.key < $1.key }
    }
}
