import Foundation

/// Configuration for the opt-in Gmail mail channel. OAuth credentials belong in
/// Keychain; this value is deliberately safe to persist in Config.
struct GmailMailConfig: Codable, Equatable {
    var enabled: Bool
    var accountEmail: String
    var inboundAlias: String
    var projects: [GmailMailProjectRule]
    var pollIntervalSeconds: TimeInterval
    var allowedAttachmentBytes: Int
    /// Addresses besides the account itself that may command Seahelm, so the
    /// commanding mailbox needn't be the one being read — writing to yourself
    /// works, but reads as odd in a thread.
    ///
    /// A `From` header is trivially forged, and what arrives here is typed into
    /// a terminal running an agent. Mail from these addresses is therefore only
    /// honoured when Google's own SPF/DKIM verdict passes; see
    /// `GmailInboundValidator`.
    var allowedSenders: [String]

    static let defaultPollIntervalSeconds: TimeInterval = 45
    static let defaultAllowedAttachmentBytes = 20 * 1_024 * 1_024

    init(enabled: Bool = false, accountEmail: String = "", inboundAlias: String = "",
         projects: [GmailMailProjectRule] = [],
         pollIntervalSeconds: TimeInterval = GmailMailConfig.defaultPollIntervalSeconds,
         allowedAttachmentBytes: Int = GmailMailConfig.defaultAllowedAttachmentBytes,
         allowedSenders: [String] = []) {
        self.enabled = enabled
        self.accountEmail = Self.normalizeEmail(accountEmail)
        self.inboundAlias = Self.normalizeEmail(inboundAlias)
        self.projects = projects
        self.pollIntervalSeconds = pollIntervalSeconds
        self.allowedAttachmentBytes = allowedAttachmentBytes
        self.allowedSenders = allowedSenders
    }

    /// Hand-written so a config saved before `allowedSenders` existed still
    /// decodes, per the `decodeIfPresent` convention used throughout Config.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        accountEmail = Self.normalizeEmail(try values.decodeIfPresent(String.self, forKey: .accountEmail) ?? "")
        inboundAlias = Self.normalizeEmail(try values.decodeIfPresent(String.self, forKey: .inboundAlias) ?? "")
        projects = try values.decodeIfPresent([GmailMailProjectRule].self, forKey: .projects) ?? []
        pollIntervalSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .pollIntervalSeconds)
            ?? Self.defaultPollIntervalSeconds
        allowedAttachmentBytes = try values.decodeIfPresent(Int.self, forKey: .allowedAttachmentBytes)
            ?? Self.defaultAllowedAttachmentBytes
        allowedSenders = try values.decodeIfPresent([String].self, forKey: .allowedSenders) ?? []
    }

    /// The whitelist, normalised for comparison. The account itself is always
    /// permitted and never needs listing.
    var normalizedAllowedSenders: Set<String> {
        Set(allowedSenders.map(Self.normalizeEmail).filter { !$0.isEmpty })
    }

    var resolvedPollIntervalSeconds: TimeInterval {
        min(60, max(30, pollIntervalSeconds))
    }

    var resolvedAllowedAttachmentBytes: Int {
        max(0, allowedAttachmentBytes)
    }

    /// The only alias supported by v1. It keeps inbound filtering simple and
    /// prevents a config typo from silently widening the accepted recipient set.
    var isValidInboundAlias: Bool {
        let account = Self.normalizeEmail(accountEmail)
        guard let at = account.firstIndex(of: "@") else { return false }
        let expected = String(account[..<at]) + "+seahelm" + String(account[at...])
        return inboundAlias == expected
    }

    var validationError: String? {
        guard Self.isEmail(accountEmail) else { return "Enter a valid Gmail address." }
        guard isValidInboundAlias else { return "The inbound alias must be \(derivedInboundAlias)." }
        // Project rules are no longer part of routing — the recipient alias is
        // the only gate and every command is fleet-wide — so an empty list is a
        // perfectly valid configuration.
        guard Set(projects.map(\.normalizedAlias)).count == projects.count else {
            return "Project aliases must be unique."
        }
        guard projects.allSatisfy({ $0.isValid }) else {
            return "Each project needs a lowercase alias and an existing directory."
        }
        return nil
    }

    var derivedInboundAlias: String {
        let account = Self.normalizeEmail(accountEmail)
        guard let at = account.firstIndex(of: "@") else { return "" }
        return String(account[..<at]) + "+seahelm" + String(account[at...])
    }

    static func normalizeEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isEmail(_ value: String) -> Bool {
        let parts = normalizeEmail(value).split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }
}

struct GmailMailProjectRule: Codable, Equatable {
    var alias: String
    var worktreePath: String

    init(alias: String, worktreePath: String) {
        self.alias = alias
        self.worktreePath = worktreePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedAlias: String { alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    var isValid: Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !normalizedAlias.isEmpty,
              normalizedAlias.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: worktreePath, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
