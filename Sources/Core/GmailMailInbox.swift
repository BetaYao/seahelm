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
    case accept
    case reject(GmailMailAuditCode)
}

enum GmailMailAuditCode: String, Codable, Equatable {
    case accepted
    case duplicateMessage
    case preEnableMessage
    case missingMessageID
    case missingThreadID
    case invalidSender
    /// A whitelisted address that Google could not vouch for — most likely a
    /// forged `From`.
    case unauthenticatedSender
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
    /// The `From` address, recorded in the clear and only when it is why the
    /// message was refused.
    ///
    /// Message and thread ids are hashed because nothing needs to read them
    /// back, but a whitelist cannot be corrected against an address you are not
    /// allowed to see — and the address a provider actually sends from is
    /// routinely not the one you typed into it.
    let sender: String?
    let code: GmailMailAuditCode

    init(messageID: String, threadID: String, sender: String? = nil,
         code: GmailMailAuditCode, timestamp: Date = Date()) {
        self.timestamp = timestamp
        messageIDHash = Self.hash(messageID)
        threadIDHash = Self.hash(threadID)
        self.sender = sender
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
        let sender = normalizedAddress(message.header("from"))
        if sender != config.accountEmail {
            guard config.normalizedAllowedSenders.contains(sender) else { return .reject(.invalidSender) }
            // Anyone can put a whitelisted address in a `From` header, and what
            // arrives here is typed into a terminal running an agent. Only
            // Google's own verdict makes an outside address worth trusting;
            // mail the account sent itself never leaves Google and carries no
            // such header, which is why the check is scoped to outside senders.
            guard isSenderAuthenticated(message) else { return .reject(.unauthenticatedSender) }
        }
        guard recipientHeadersContainAlias(message, alias: config.inboundAlias) else { return .reject(.invalidRecipient) }
        guard !isAutomated(message) else { return .reject(.autoReply) }
        // The recipient alias is the whole gate. There is no subject tag and no
        // per-project routing: every command is fleet-wide, and a thread that
        // wants one particular pane says so with `/pane <n>`.
        return .accept
    }

    /// Google's inbound verdict, from the `Authentication-Results` header it
    /// stamps on everything arriving from outside.
    ///
    /// DKIM is the stronger signal — it binds the message to a domain's key and
    /// survives forwarding — but SPF alone still proves the sending host was
    /// authorised, so either is accepted. A message with no verdict at all is
    /// refused rather than assumed good.
    static func isSenderAuthenticated(_ message: GmailInboundMessage) -> Bool {
        guard let results = message.header("authentication-results")?.lowercased() else { return false }
        return results.contains("dkim=pass") || results.contains("spf=pass")
    }

    private static func recipientHeadersContainAlias(_ message: GmailInboundMessage, alias: String) -> Bool {
        [message.header("to"), message.header("delivered-to")]
            .compactMap { $0 }
            .flatMap { $0.split(separator: ",") }
            .contains { normalizedAddress(String($0)) == alias }
    }

    /// The address the sender gate compares against, so a rejection can name it.
    static func senderAddress(of message: GmailInboundMessage) -> String {
        normalizedAddress(message.header("from"))
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

    mutating func record(messageID: String, threadID: String, sender: String? = nil, code: GmailMailAuditCode) {
        if !messageID.isEmpty {
            processedMessageIDs.append(messageID)
            processedMessageIDs = Array(processedMessageIDs.suffix(Self.maxProcessedMessageIDs))
        }
        audit.append(.init(messageID: messageID, threadID: threadID, sender: sender, code: code))
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
