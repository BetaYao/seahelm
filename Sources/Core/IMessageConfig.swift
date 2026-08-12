import Foundation

/// iMessage bridge settings.
///
/// Unlike the retired WeCom/WeChat channels there is no token here: the
/// transport is the local Messages.app database plus AppleScript, so the only
/// real configuration is *who* is allowed to steer the fleet.
struct IMessageConfig: Codable, Equatable {
    /// Handles permitted to issue commands — phone numbers in E.164
    /// (`+8613800138000`) or Apple IDs (`someone@example.com`).
    ///
    /// This is a hard gate, not a convenience filter: an iMessage inbox is open
    /// to anyone who knows the handle, and an inbound line here can spawn
    /// worktrees and run commands. Empty means the channel connects but drops
    /// every inbound message.
    var allowedHandles: [String]

    /// Where `AgentRegistry.broadcast` (agent-finished notifications) is sent. Falls
    /// back to the first allowed handle so the common single-user setup needs
    /// no extra field.
    var defaultRecipient: String?

    var autoConnect: Bool?

    /// Ignore anything already in chat.db older than this at connect time, so
    /// enabling the channel doesn't replay a week of texts as commands.
    var backfillSeconds: Double?

    /// Word a message must start with to be treated as a command: `sea status`.
    ///
    /// Required in both directions, and it is what makes the single-Apple-ID
    /// setup safe. Texting yourself is also how people keep notes, so without a
    /// marker every stray line in that thread would be an order.
    var commandPrefix: String?

    /// Word seahelm stamps on everything it sends: `helm ✅ Agent finished`.
    ///
    /// This is the echo guard. Replies land back in the same thread as
    /// `is_from_me = 1`, indistinguishable from something the user typed, so
    /// they have to be self-identifying or the bridge answers itself forever.
    var replyPrefix: String?

    /// Message-triggered agent dispatch. Evaluated only for lines that are *not*
    /// commands, so an order to seahelm never doubles as a trigger.
    var rules: [IMessageRule]?

    init(allowedHandles: [String] = [],
         defaultRecipient: String? = nil,
         autoConnect: Bool? = nil,
         backfillSeconds: Double? = nil,
         commandPrefix: String? = nil,
         replyPrefix: String? = nil,
         rules: [IMessageRule]? = nil) {
        self.allowedHandles = allowedHandles
        self.defaultRecipient = defaultRecipient
        self.autoConnect = autoConnect
        self.backfillSeconds = backfillSeconds
        self.commandPrefix = commandPrefix
        self.replyPrefix = replyPrefix
        self.rules = rules
    }

    var resolvedAutoConnect: Bool { autoConnect ?? true }
    var resolvedBackfillSeconds: Double { backfillSeconds ?? 60 }
    var resolvedRules: [IMessageRule] { rules ?? [] }
    var resolvedCommandPrefix: String { nonBlank(commandPrefix) ?? "sea" }
    var resolvedReplyPrefix: String { nonBlank(replyPrefix) ?? "helm" }

    private func nonBlank(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }

    // MARK: - Prefixes

    /// The command body, or nil if this line isn't addressed to seahelm.
    ///
    /// Matching is case-insensitive and the separator is any whitespace run, so
    /// an iPhone autocapitalising to `Sea status` still works. `sea` alone
    /// returns nil — a bare prefix carries no order.
    func commandBody(of text: String) -> String? {
        strip(prefix: resolvedCommandPrefix, from: text)
    }

    /// True for a line seahelm sent itself. Checked before anything else, so a
    /// reply that happens to quote a command can't re-trigger it.
    func isOwnReply(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .hasPrefix(resolvedReplyPrefix.lowercased())
    }

    /// Stamp an outbound body so the drain loop recognises it on the way back.
    func stampReply(_ body: String) -> String {
        isOwnReply(body) ? body : "\(resolvedReplyPrefix) \(body)"
    }

    private func strip(prefix: String, from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        let rest = trimmed.dropFirst(prefix.count)
        // Require a separator: `seahelm` must not read as `sea` + `helm`.
        guard let first = rest.first, first.isWhitespace else { return nil }
        let body = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    var resolvedDefaultRecipient: String? {
        if let r = defaultRecipient?.trimmingCharacters(in: .whitespaces), !r.isEmpty { return r }
        return allowedHandles.first
    }

    /// Handles compare loosely: Messages stores a number as `+8613800138000`
    /// but a user may type `13800138000`, and Apple IDs vary in case.
    func allows(handle: String) -> Bool {
        let needle = Self.normalize(handle)
        guard !needle.isEmpty else { return false }
        return allowedHandles.contains { Self.normalize($0) == needle }
    }

    /// The other party's handle, pulled out of a 1:1 chat GUID
    /// (`iMessage;-;+8613800138000`, `SMS;-;10690…`).
    ///
    /// Outgoing rows have no `handle_id` to join against — Messages only records
    /// who a message came *from* — so for the user's own commands the chat is
    /// the only thing left to authorise against. Group GUIDs
    /// (`iMessage;+;chat123…`) yield nil: a group is not a private command line.
    static func counterpart(ofChatGuid guid: String?) -> String? {
        guard let guid else { return nil }
        let parts = guid.components(separatedBy: ";")
        guard parts.count >= 3, parts[1] == "-" else { return nil }
        let handle = parts.dropFirst(2).joined(separator: ";")
        return handle.isEmpty ? nil : handle
    }

    static func normalize(_ handle: String) -> String {
        let lowered = handle.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lowered.contains("@") else { return lowered }
        // Phone: keep digits only, then compare on the last 10 so a missing
        // country code doesn't lock the owner out of their own bridge.
        let digits = lowered.filter(\.isNumber)
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }

    enum CodingKeys: String, CodingKey {
        case allowedHandles = "allowed_handles"
        case defaultRecipient = "default_recipient"
        case autoConnect = "auto_connect"
        case backfillSeconds = "backfill_seconds"
        case commandPrefix = "command_prefix"
        case replyPrefix = "reply_prefix"
        case rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowedHandles = try c.decodeIfPresent([String].self, forKey: .allowedHandles) ?? []
        defaultRecipient = try c.decodeIfPresent(String.self, forKey: .defaultRecipient)
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect)
        backfillSeconds = try c.decodeIfPresent(Double.self, forKey: .backfillSeconds)
        commandPrefix = try c.decodeIfPresent(String.self, forKey: .commandPrefix)
        replyPrefix = try c.decodeIfPresent(String.self, forKey: .replyPrefix)
        rules = try c.decodeIfPresent([IMessageRule].self, forKey: .rules)
    }
}
