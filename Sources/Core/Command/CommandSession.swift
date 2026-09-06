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
