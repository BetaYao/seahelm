import CryptoKit
import Foundation

/// Provider-independent representation of the headers needed before a message
/// can become a Seahelm mail candidate. Bodies and MIME parts intentionally stay
/// out of the audit/state store.
struct GmailInboundMessage: Equatable {
    let id: String
    let threadId: String
    let receivedAt: Date
    let headers: [String: String]
    let bodyText: String
    let attachments: [EmailAttachment]

    init(id: String, threadId: String, receivedAt: Date, headers: [String: String], bodyText: String = "", attachments: [EmailAttachment] = []) {
        self.id = id
        self.threadId = threadId
        self.receivedAt = receivedAt
        // Lowercasing can collide even when the source keys were unique, and the
        // source keys usually are not — see the note in GmailRESTMailClient.
        // Trapping here would crash the app on ordinary mail.
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) },
                                  uniquingKeysWith: { "\($0), \($1)" })
        self.bodyText = bodyText
        self.attachments = attachments
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

enum GmailInboundDecision: Equatable {
    case accept(project: GmailMailProjectRule)
    case reject(GmailMailAuditCode)
}

enum GmailMailAuditCode: String, Codable, Equatable {
    case accepted
    case duplicateMessage
    case preEnableMessage
    case missingMessageID
    case missingThreadID
    case invalidSender
    case invalidRecipient
    case autoReply
    case malformedSubject
    case unknownProject
    case cursorReset
    case authorizationExpired
    case clientError
}

struct GmailMailAuditEntry: Codable, Equatable {
    let timestamp: Date
    let messageIDHash: String
    let threadIDHash: String
    let projectAlias: String?
    let code: GmailMailAuditCode

    init(messageID: String, threadID: String, projectAlias: String? = nil,
         code: GmailMailAuditCode, timestamp: Date = Date()) {
        self.timestamp = timestamp
        messageIDHash = Self.hash(messageID)
        threadIDHash = Self.hash(threadID)
        self.projectAlias = projectAlias
        self.code = code
    }

    private static func hash(_ value: String) -> String {
        String(SHA256.hash(data: Data(value.utf8)).compactMap { String(format: "%02x", $0) }.joined().prefix(16))
    }
}

enum GmailInboundValidator {
    static func validate(_ message: GmailInboundMessage, config: GmailMailConfig,
                         syncStartedAt: Date, processedIDs: Set<String>) -> GmailInboundDecision {
        guard !message.id.isEmpty else { return .reject(.missingMessageID) }
        guard !message.threadId.isEmpty else { return .reject(.missingThreadID) }
        guard message.receivedAt >= syncStartedAt else { return .reject(.preEnableMessage) }
        guard !processedIDs.contains(message.id) else { return .reject(.duplicateMessage) }
        guard normalizedAddress(message.header("from")) == config.accountEmail else { return .reject(.invalidSender) }
        guard recipientHeadersContainAlias(message, alias: config.inboundAlias) else { return .reject(.invalidRecipient) }
        guard !isAutomated(message) else { return .reject(.autoReply) }
        guard let alias = projectAlias(from: message.header("subject")),
              let project = config.projects.first(where: { $0.normalizedAlias == alias }) else {
            return .reject(message.header("subject") == nil ? .malformedSubject : .unknownProject)
        }
        return .accept(project: project)
    }

    static func projectAlias(from subject: String?) -> String? {
        guard let subject else { return nil }
        // Gmail adds `Re:` (and occasionally `Fwd:`) before a reply subject.
        // Strip those first so extraction still begins at `[seahelm:`.
        let normalized = subject.replacingOccurrences(of: #"(?i)^(?:(?:re|fwd):\s*)*"#, with: "", options: .regularExpression)
        let pattern = #"^\[seahelm:([a-z0-9-]+)\]\s*"#
        guard let match = normalized.range(of: pattern, options: .regularExpression) else { return nil }
        let prefix = String(normalized[match])
        return prefix.dropFirst("[seahelm:".count).dropLast(2).trimmingCharacters(in: .whitespaces)
    }

    private static func recipientHeadersContainAlias(_ message: GmailInboundMessage, alias: String) -> Bool {
        [message.header("to"), message.header("delivered-to")]
            .compactMap { $0 }
            .flatMap { $0.split(separator: ",") }
            .contains { normalizedAddress(String($0)) == alias }
    }

    private static func normalizedAddress(_ value: String?) -> String {
        guard let value else { return "" }
        if let start = value.lastIndex(of: "<"), let end = value[start...].firstIndex(of: ">") {
            return GmailMailConfig.normalizeEmail(String(value[value.index(after: start)..<end]))
        }
        return GmailMailConfig.normalizeEmail(value)
    }

    private static func isAutomated(_ message: GmailInboundMessage) -> Bool {
        let autoSubmitted = message.header("auto-submitted")?.lowercased() ?? "no"
        if autoSubmitted != "no" { return true }
        let precedence = message.header("precedence")?.lowercased() ?? ""
        if ["bulk", "junk", "list"].contains(precedence) { return true }
        let from = message.header("from")?.lowercased() ?? ""
        return from.contains("mailer-daemon")
    }
}

/// Durable, bounded state used only inside one running Gmail window.  The state
/// never contains OAuth secrets, message bodies, or provider MIME payloads.
struct GmailMailState: Codable, Equatable {
    var syncStartedAt: Date
    var latestHistoryId: String?
    var processedMessageIDs: [String]
    var audit: [GmailMailAuditEntry]

    static let maxProcessedMessageIDs = 2_000
    static let maxAuditEntries = 500

    init(syncStartedAt: Date, latestHistoryId: String? = nil, processedMessageIDs: [String] = [], audit: [GmailMailAuditEntry] = []) {
        self.syncStartedAt = syncStartedAt
        self.latestHistoryId = latestHistoryId
        self.processedMessageIDs = processedMessageIDs
        self.audit = audit
    }

    mutating func record(messageID: String, threadID: String, projectAlias: String? = nil, code: GmailMailAuditCode) {
        if !messageID.isEmpty {
            processedMessageIDs.append(messageID)
            processedMessageIDs = Array(processedMessageIDs.suffix(Self.maxProcessedMessageIDs))
        }
        audit.append(.init(messageID: messageID, threadID: threadID, projectAlias: projectAlias, code: code))
        audit = Array(audit.suffix(Self.maxAuditEntries))
    }
}

final class GmailMailStateStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "seahelm.gmail-mail-state")
    private let fileManager: FileManager

    init(fileURL: URL = Config.configDir.appendingPathComponent("gmail-mail-state.json"), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() -> GmailMailState? {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(GmailMailState.self, from: data)
        }
    }

    func save(_ state: GmailMailState) throws {
        try queue.sync {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        }
    }

    func remove() throws {
        try queue.sync {
            guard fileManager.fileExists(atPath: fileURL.path) else { return }
            try fileManager.removeItem(at: fileURL)
        }
    }
}
