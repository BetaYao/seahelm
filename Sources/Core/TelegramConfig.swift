import Foundation

/// Telegram bridge settings.
///
/// The transport is the Bot API over HTTPS — long polling in, `sendMessage`
/// out — so there is nothing to grant in System Settings and no local app to
/// drive. What it needs instead is a bot (from @BotFather) and, because a
/// bot's chat is open to anyone who finds it, a list of who is allowed to
/// steer the fleet.
struct TelegramConfig: Codable, Equatable {
    /// Bot token from @BotFather: `123456789:AAF…`. Lives in config.json beside
    /// the pairing root secret; it is never written to a log or an error.
    var botToken: String?

    /// Users permitted to issue commands — numeric Telegram user IDs
    /// (`123456789`) or usernames (`@someone`).
    ///
    /// This is a hard gate, not a convenience filter: anyone can open a chat
    /// with a bot, and an inbound line here can spawn worktrees and run
    /// commands. Empty means the channel connects but obeys nobody.
    var allowedUsers: [String]

    /// Chat where `AgentRegistry.broadcast` (agent-finished notifications) is
    /// sent. Falls back to the first numeric allowed user — a private chat's id
    /// *is* the user's id — so the common single-user setup needs no extra
    /// field. A username cannot serve here: the API only addresses chats by id.
    var defaultChatId: String?

    var autoConnect: Bool?

    /// Ignore updates older than this at connect time, so enabling the channel
    /// doesn't replay a day of messages as commands. Telegram keeps unconfirmed
    /// updates for 24 hours, so without a window that is exactly what happens.
    var backfillSeconds: Double?

    /// Message-triggered agent dispatch. Evaluated only for messages that are
    /// *not* orders — those from senders outside the allowlist — so an order to
    /// seahelm never doubles as a trigger.
    var rules: [TelegramRule]?

    /// Give each worktree a forum topic of its own.
    ///
    /// Off by default, and not merely out of caution: it needs a forum group
    /// the bot administers with "Manage Topics", which nothing else here
    /// requires. Turned on, a worktree's first notice opens a thread named
    /// `repo · branch` and every pane in that worktree reports there — which
    /// also means they stop reporting to the fleet-wide chat, or every notice
    /// would arrive twice.
    var autoTopics: Bool?

    /// The forum supergroup topics are opened in when nothing more specific
    /// matches. Its own id, with no topic: what a topic is created *in*.
    var topicChatId: String?

    /// Which group a worktree's topic is opened in, keyed by **worktree path**
    /// or **project name**.
    ///
    /// One group holding the whole fleet does not scale — a busy week is more
    /// threads than a phone can skim in one list — so the fleet is split across
    /// groups the way the work already is. A bot cannot create a group (the Bot API opens
    /// topics, not chats), so these are groups someone made by hand and added
    /// the bot to; this table only says which is which.
    ///
    /// Project is the grain that pays: a repo is a handful of groups made once,
    /// where a worktree would be a new group every time a branch is cut. A
    /// worktree path is still allowed as a key, for the one worktree important
    /// enough to deserve a room of its own, and it wins over the project.
    var topicChats: [String: String]?

    init(botToken: String? = nil,
         allowedUsers: [String] = [],
         defaultChatId: String? = nil,
         autoConnect: Bool? = nil,
         backfillSeconds: Double? = nil,
         rules: [TelegramRule]? = nil,
         autoTopics: Bool? = nil,
         topicChatId: String? = nil,
         topicChats: [String: String]? = nil) {
        self.botToken = botToken
        self.allowedUsers = allowedUsers
        self.defaultChatId = defaultChatId
        self.autoConnect = autoConnect
        self.backfillSeconds = backfillSeconds
        self.rules = rules
        self.autoTopics = autoTopics
        self.topicChatId = topicChatId
        self.topicChats = topicChats
    }

    var resolvedAutoConnect: Bool { autoConnect ?? true }
    var resolvedBackfillSeconds: Double { backfillSeconds ?? 60 }
    var resolvedRules: [TelegramRule] { rules ?? [] }
    var resolvedBotToken: String? { nonBlank(botToken) }

    /// The feature is on and has somewhere to put at least one topic.
    var autoTopicsEnabled: Bool {
        autoTopics == true && (nonBlank(topicChatId) != nil || !(topicChats ?? [:]).isEmpty)
    }

    /// The fallback group: where a worktree goes when the table names none for it.
    var resolvedTopicChatId: String? {
        guard autoTopics == true, let chat = nonBlank(topicChatId) else { return nil }
        return TelegramChatAddress.chatId(of: chat)
    }

    /// Which group this worktree's topic belongs in.
    ///
    /// Most specific first: the worktree itself, then the repo it belongs to,
    /// then the fallback. A value that carries a topic of
    /// its own is taken down to the group — a topic is opened *in* a chat.
    func topicChatId(worktreePath: String, project: String) -> String? {
        guard autoTopics == true else { return nil }
        let table = topicChats ?? [:]
        if let hit = table.first(where: { Self.samePath($0.key, worktreePath) })?.value,
           let chat = nonBlank(hit) {
            return TelegramChatAddress.chatId(of: chat)
        }
        if let hit = table.first(where: { Self.sameName($0.key, project) })?.value,
           let chat = nonBlank(hit) {
            return TelegramChatAddress.chatId(of: chat)
        }
        return resolvedTopicChatId
    }

    /// Paths compare without a trailing slash; a table written by hand will
    /// have one about half the time.
    private static func samePath(_ a: String, _ b: String) -> Bool {
        func trim(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespaces)
            while t.count > 1, t.hasSuffix("/") { t.removeLast() }
            return t
        }
        guard b.hasPrefix("/") else { return false }
        return trim(a) == trim(b)
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(
            b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    var resolvedDefaultChatId: String? {
        if let explicit = nonBlank(defaultChatId) { return explicit }
        return allowedUsers.map(Self.normalize).first(where: Self.isNumericId)
    }

    private func nonBlank(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    // MARK: - Allowlist

    func allows(user: TelegramUser) -> Bool {
        allows(userId: user.id, username: user.username)
    }

    /// An entry matches on the numeric id *or* the username, so the list can
    /// be written either way. Usernames compare without case and without the
    /// leading `@` — Telegram itself treats them so.
    func allows(userId: Int64, username: String?) -> Bool {
        let id = String(userId)
        let name = username.map(Self.normalize) ?? ""
        return allowedUsers.contains { entry in
            let needle = Self.normalize(entry)
            guard !needle.isEmpty else { return false }
            return needle == id || (!name.isEmpty && needle == name)
        }
    }

    static func normalize(_ entry: String) -> String {
        var s = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("@") { s.removeFirst() }
        return s
    }

    /// A user id (`123456`) or a chat id, which for groups is negative
    /// (`-1001234567890`).
    static func isNumericId(_ s: String) -> Bool {
        let digits = s.hasPrefix("-") ? s.dropFirst() : Substring(s)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case botToken = "bot_token"
        case allowedUsers = "allowed_users"
        case defaultChatId = "default_chat_id"
        case autoConnect = "auto_connect"
        case backfillSeconds = "backfill_seconds"
        case rules
        case autoTopics = "auto_topics"
        case topicChatId = "topic_chat_id"
        case topicChats = "topic_chats"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        botToken = try c.decodeIfPresent(String.self, forKey: .botToken)
        allowedUsers = try c.decodeIfPresent([String].self, forKey: .allowedUsers) ?? []
        defaultChatId = try c.decodeIfPresent(String.self, forKey: .defaultChatId)
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect)
        backfillSeconds = try c.decodeIfPresent(Double.self, forKey: .backfillSeconds)
        rules = try c.decodeIfPresent([TelegramRule].self, forKey: .rules)
        autoTopics = try c.decodeIfPresent(Bool.self, forKey: .autoTopics)
        topicChatId = try c.decodeIfPresent(String.self, forKey: .topicChatId)
        topicChats = try c.decodeIfPresent([String: String].self, forKey: .topicChats)
    }
}
