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

    /// Where `ShipLog.broadcast` (agent-finished notifications) is sent. Falls
    /// back to the first allowed handle so the common single-user setup needs
    /// no extra field.
    var defaultRecipient: String?

    var autoConnect: Bool?

    /// Ignore anything already in chat.db older than this at connect time, so
    /// enabling the channel doesn't replay a week of texts as commands.
    var backfillSeconds: Double?

    init(allowedHandles: [String] = [],
         defaultRecipient: String? = nil,
         autoConnect: Bool? = nil,
         backfillSeconds: Double? = nil) {
        self.allowedHandles = allowedHandles
        self.defaultRecipient = defaultRecipient
        self.autoConnect = autoConnect
        self.backfillSeconds = backfillSeconds
    }

    var resolvedAutoConnect: Bool { autoConnect ?? true }
    var resolvedBackfillSeconds: Double { backfillSeconds ?? 60 }

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
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowedHandles = try c.decodeIfPresent([String].self, forKey: .allowedHandles) ?? []
        defaultRecipient = try c.decodeIfPresent(String.self, forKey: .defaultRecipient)
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect)
        backfillSeconds = try c.decodeIfPresent(Double.self, forKey: .backfillSeconds)
    }
}
