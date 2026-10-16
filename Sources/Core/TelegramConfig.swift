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

    init(botToken: String? = nil,
         allowedUsers: [String] = [],
         defaultChatId: String? = nil,
         autoConnect: Bool? = nil,
         backfillSeconds: Double? = nil,
         rules: [TelegramRule]? = nil) {
        self.botToken = botToken
        self.allowedUsers = allowedUsers
        self.defaultChatId = defaultChatId
        self.autoConnect = autoConnect
        self.backfillSeconds = backfillSeconds
        self.rules = rules
    }

    var resolvedAutoConnect: Bool { autoConnect ?? true }
    var resolvedBackfillSeconds: Double { backfillSeconds ?? 60 }
    var resolvedRules: [TelegramRule] { rules ?? [] }
    var resolvedBotToken: String? { nonBlank(botToken) }

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
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        botToken = try c.decodeIfPresent(String.self, forKey: .botToken)
        allowedUsers = try c.decodeIfPresent([String].self, forKey: .allowedUsers) ?? []
        defaultChatId = try c.decodeIfPresent(String.self, forKey: .defaultChatId)
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect)
        backfillSeconds = try c.decodeIfPresent(Double.self, forKey: .backfillSeconds)
        rules = try c.decodeIfPresent([TelegramRule].self, forKey: .rules)
    }
}
