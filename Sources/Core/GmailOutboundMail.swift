import Foundation

struct OutboundMailIntent: Codable, Equatable {
    enum Kind: String, Codable { case waiting, completion, error }
    var id: String
    var threadID: String
    var paneSessionKey: String
    var sequence: UInt64
    var kind: Kind
    var subject: String
    var body: String
    var state: String // pending | accepted | failed
}

final class OutboundMailIntentStore {
    private let url: URL
    private var intents: [String: OutboundMailIntent] = [:]
    private let lock = NSLock()
    init(url: URL = Config.configDir.appendingPathComponent("gmail-outbound-intents.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode([String: OutboundMailIntent].self, from: data) { intents = value }
    }
    func insertIfAbsent(_ intent: OutboundMailIntent) -> Bool { lock.lock(); defer { lock.unlock() }; guard intents[intent.id] == nil else { return false }; intents[intent.id] = intent; persist(); return true }
    func update(_ intent: OutboundMailIntent) { lock.lock(); defer { lock.unlock() }; intents[intent.id] = intent; persist() }
    func retryable() -> [OutboundMailIntent] { lock.lock(); defer { lock.unlock() }; return intents.values.filter { $0.state == "failed" || $0.state == "pending" } }
    private func persist() { try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try? JSONEncoder().encode(intents).write(to: url, options: .atomic) }
}

enum MailContentRedactor {
    static func summary(_ text: String, limit: Int = 4_000) -> String {
        let unsafe = ["token", "password", "secret", "api_key", "authorization:", "export ", "diff --git"]
        let safe = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !unsafe.contains(where: { line.lowercased().contains($0) }) }
            .joined(separator: "\n")
        return String(safe.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class MailPaneObserver {
    var onIntent: ((OutboundMailIntent) -> Void)?
    private let conversations: EmailConversationStore
    private var emitted: Set<String> = []
    private let intentStore: OutboundMailIntentStore

    init(conversations: EmailConversationStore, intentStore: OutboundMailIntentStore = OutboundMailIntentStore()) { self.conversations = conversations; self.intentStore = intentStore }

    func ingest(_ outcome: IngestOutcome) {
        let key = outcome.info.station?.paneSessionKey ?? ""
        guard !key.isEmpty, let conversation = conversations.conversation(forPaneSessionKey: key), !conversation.closed else { return }
        let kind: OutboundMailIntent.Kind?
        if outcome.isCompletionSignal { kind = .completion }
        else if outcome.statusChanged && outcome.newStatus == .waiting { kind = .waiting }
        else if outcome.statusChanged && outcome.newStatus == .error { kind = .error }
        else { kind = nil }
        guard let kind else { return }
        let id = "\(key):\(outcome.seq):\(kind.rawValue)"
        guard emitted.insert(id).inserted else { return }
        let text = outcome.isCompletionSignal ? outcome.info.lastAssistantMessage : outcome.info.lastMessage
        let body = MailContentRedactor.summary(text.isEmpty ? "Seahelm pane status: \(outcome.newStatus.groupLabel)." : text)
        let intent = OutboundMailIntent(id: id, threadID: conversation.gmailThreadID, paneSessionKey: key, sequence: outcome.seq, kind: kind,
                                        subject: "[seahelm:\(conversation.projectAlias)]", body: body, state: "pending")
        guard intentStore.insertIfAbsent(intent) else { return }
        onIntent?(intent)
    }
}

protocol GmailMailSending {
    func send(_ intent: OutboundMailIntent, to account: String, completion: @escaping (Result<String, GmailMailClientError>) -> Void)
}

/// Sends only the redacted intent body. It deliberately has no terminal/pane
/// dependency, so outbound mail cannot accidentally capture a screen buffer.
final class GmailRESTMailSender: GmailMailSending {
    private let account: String
    private let tokens: GmailAccessTokenProviding
    init(account: String, tokens: GmailAccessTokenProviding? = nil) {
        self.account = GmailMailConfig.normalizeEmail(account)
        self.tokens = tokens ?? GmailAccessTokenProvider(accountEmail: account)
    }
    func send(_ intent: OutboundMailIntent, to account: String, completion: @escaping (Result<String, GmailMailClientError>) -> Void) {
        send(intent, to: account, forceRefresh: false, completion: completion)
    }

    private func send(_ intent: OutboundMailIntent, to account: String, forceRefresh: Bool,
                      completion: @escaping (Result<String, GmailMailClientError>) -> Void) {
        tokens.token(forceRefresh: forceRefresh) { [weak self] result in
        guard let self else { return }
        guard case .success(let token) = result else {
            completion(.failure(result.failureError ?? .authorizationExpired)); return
        }
        let message = ["To: \(account)", "Subject: \(intent.subject)", "Content-Type: text/plain; charset=utf-8", "", intent.body].joined(separator: "\r\n")
        let raw = Data(message.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        request.httpMethod = "POST"; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["threadId": intent.threadID, "raw": raw])
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(.transport(error.localizedDescription))); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["id"] as? String else {
                // A token can be rejected before its recorded expiry — revoked,
                // or clock skew — so try one forced exchange before giving up.
                if status == 401, !forceRefresh {
                    self.send(intent, to: account, forceRefresh: true, completion: completion)
                } else {
                    completion(.failure(status == 401 ? .authorizationExpired : .transport("HTTP \(status)")))
                }
                return
            }
            completion(.success(id))
        }.resume()
        }
    }
}
