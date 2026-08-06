import Foundation

struct OutboundMailIntent: Codable, Equatable {
    enum Kind: String, Codable { case waiting, completion, error, reply }
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
    /// `(intent, recipient)` — the recipient is the thread's commander, so an
    /// agent's output reaches whoever is actually running it.
    var onIntent: ((OutboundMailIntent, String?) -> Void)?
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
        // A turn that simply ends. Agents that report a Stop hook raise
        // `isCompletionSignal`; the rest just fall back to resting, and without
        // this their answer never left the pane — which is the whole point of
        // having mailed them.
        else if outcome.statusChanged && outcome.oldStatus == .running && outcome.newStatus == .idle { kind = .completion }
        else { kind = nil }
        guard let kind else { return }
        let id = "\(key):\(outcome.seq):\(kind.rawValue)"
        guard emitted.insert(id).inserted else { return }
        let text = outcome.isCompletionSignal ? outcome.info.lastAssistantMessage : outcome.info.lastMessage
        let body = MailContentRedactor.summary(text.isEmpty ? "Seahelm pane status: \(outcome.newStatus.groupLabel)." : text)
        let intent = OutboundMailIntent(id: id, threadID: conversation.gmailThreadID, paneSessionKey: key, sequence: outcome.seq, kind: kind,
                                        // Nothing parses the subject any more — the recipient alias is
                                        // the gate — so it just has to read well in a thread list.
                                        subject: "Seahelm — \(outcome.newStatus.groupLabel)", body: body, state: "pending")
        guard intentStore.insertIfAbsent(intent) else { return }
        onIntent?(intent, conversation.commander)
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
    /// A `multipart/alternative` of the same content twice.
    ///
    /// The plain part is not a fallback — it is what the reader parses on the way
    /// back (`GmailRESTMailClient` takes `text/plain`), so quoting and therefore
    /// `MailBody.newContent` keep working. The HTML part is only what you see.
    ///
    /// Both parts are base64: RFC 5322 caps a line at 998 characters and agent
    /// output regularly runs past that, which would otherwise corrupt the mail.
    static func rawMessage(intent: OutboundMailIntent, to account: String, boundary: String = "seahelm-\(UUID().uuidString)") -> String {
        // Every outbound mail carries the command list. Mail is the one surface
        // with no autocomplete and no keyboard help, and the `-- ` marker means
        // a reply quoting it back gets stripped again on arrival.
        let plain = MailSignature.appended(to: intent.body)
        let html = MailHTML.document(body: intent.body)
        let message = [
            "To: \(account)",
            "Subject: \(intent.subject)",
            "MIME-Version: 1.0",
            "Content-Type: multipart/alternative; boundary=\"\(boundary)\"",
            "",
            "--\(boundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            base64Body(plain),
            "--\(boundary)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            base64Body(html),
            "--\(boundary)--",
        ].joined(separator: "\r\n")
        return Data(message.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64Body(_ text: String) -> String {
        Data(text.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
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
            let raw = Self.rawMessage(intent: intent, to: account)
            var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
            request.httpMethod = "POST"; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["threadId": intent.threadID, "raw": raw])
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error { completion(.failure(.transport(error.localizedDescription))); return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status), let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["id"] as? String else {
                    // Same one-shot forced exchange as the poller: a token can be
                    // rejected before its recorded expiry.
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
