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

    static let defaultPollIntervalSeconds: TimeInterval = 45
    static let defaultAllowedAttachmentBytes = 20 * 1_024 * 1_024

    init(enabled: Bool = false, accountEmail: String = "", inboundAlias: String = "",
         projects: [GmailMailProjectRule] = [],
         pollIntervalSeconds: TimeInterval = GmailMailConfig.defaultPollIntervalSeconds,
         allowedAttachmentBytes: Int = GmailMailConfig.defaultAllowedAttachmentBytes) {
        self.enabled = enabled
        self.accountEmail = Self.normalizeEmail(accountEmail)
        self.inboundAlias = Self.normalizeEmail(inboundAlias)
        self.projects = projects
        self.pollIntervalSeconds = pollIntervalSeconds
        self.allowedAttachmentBytes = allowedAttachmentBytes
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
        guard !projects.isEmpty else { return "Add at least one project rule." }
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
