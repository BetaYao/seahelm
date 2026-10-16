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
    init(key: String, boundPaneKey: String? = nil, boundPaneId: String? = nil,
         boundWorktreePath: String? = nil, commander: String? = nil, closed: Bool = false) {
        self.key = key
        self.boundPaneKey = boundPaneKey
        self.boundPaneId = boundPaneId
        self.boundWorktreePath = boundWorktreePath
        self.commander = commander
        self.closed = closed
    }

    enum CodingKeys: String, CodingKey {
        case key, boundPaneKey, boundPaneId, boundWorktreePath, commander, closed
    }

    /// Hand-written so an older store, missing `closed`, still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        boundPaneKey = try c.decodeIfPresent(String.self, forKey: .boundPaneKey)
        boundPaneId = try c.decodeIfPresent(String.self, forKey: .boundPaneId)
        boundWorktreePath = try c.decodeIfPresent(String.self, forKey: .boundWorktreePath)
        commander = try c.decodeIfPresent(String.self, forKey: .commander)
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed) ?? false
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
            // Forum topics were once their own conversations, addressed
            // `<chat>#<thread>`. Nothing can send to that any more.
            sessions = loaded.filter { !Self.isTopicSession($0.value) }
            if sessions.count != loaded.count { persist() }
        } else if let legacyMailURL, let data = try? Data(contentsOf: legacyMailURL) {
            sessions = Self.importLegacyMail(data)
            persist()
        }
    }

    static func isTopicSession(_ session: CommandSession) -> Bool {
        session.surface == "telegram" && session.id.contains("#")
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
    func telegramChatsToNotify(paneKey: String?, fleetListenerChatIds: [String]) -> [String] {
        queue.sync {
            var chats = Set<String>()
            if let paneKey {
                for session in sessions.values
                where session.surface == "telegram" && !session.closed && session.boundPaneKey == paneKey {
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
            return chats.sorted()
        }
    }

    /// Telegram chats bound to this pane — what a progress line edits in place.
    func telegramChats(boundToPaneKey paneKey: String) -> [String] {
        queue.sync {
            sessions.values.filter {
                $0.surface == "telegram" && !$0.closed && $0.boundPaneKey == paneKey
            }.map(\.id).sorted()
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

    /// Close every conversation bound to this worktree.
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
/// is a lost binding. And never while the bound pane is alive: a pane that
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
