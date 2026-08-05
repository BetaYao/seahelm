import Foundation

/// Google REST adapter. It performs a bounded metadata-only query, then fetches
/// exactly the headers required by the policy validator. MIME bodies and
/// attachments are intentionally deferred to the routing/attachment ticket.
final class GmailRESTMailClient: GmailMailClient {
    private let accountEmail: String
    private let credentialStore: GmailOAuthCredentialStoring
    private let session: URLSession

    init(accountEmail: String, credentialStore: GmailOAuthCredentialStoring = GmailOAuthCredentialStore(),
         session: URLSession = .shared) {
        self.accountEmail = GmailMailConfig.normalizeEmail(accountEmail)
        self.credentialStore = credentialStore
        self.session = session
    }

    func poll(since: Date, historyID: String?, inboundAlias: String,
              completion: @escaping (Result<GmailMailPoll, GmailMailClientError>) -> Void) {
        do {
            guard let credentials = try credentialStore.load(accountEmail: accountEmail),
                  !credentials.accessToken.isEmpty else {
                completion(.failure(.authorizationExpired)); return
            }
            if let historyID {
                self.fetchHistory(historyID, token: credentials.accessToken, completion: completion)
            } else {
                // Establish a cursor only. Do not list the inbox here: mail that
                // predates this running window must remain out of scope.
                self.request(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!, token: credentials.accessToken) {
                    (result: Result<Profile, GmailMailClientError>) in
                    completion(result.map { .init(messages: [], latestHistoryId: $0.historyId) })
                }
            }
        } catch { completion(.failure(.transport(error.localizedDescription))) }
    }

    private func fetchHistory(_ historyID: String, token: String,
                              completion: @escaping (Result<GmailMailPoll, GmailMailClientError>) -> Void) {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/history")!
        components.queryItems = [.init(name: "startHistoryId", value: historyID),
                                 .init(name: "historyTypes", value: "messageAdded")]
        request(components.url!, token: token) { [weak self] (result: Result<HistoryList, GmailMailClientError>) in
            guard let self else { return }
            switch result {
            case .failure(.transport("HTTP 404")): completion(.failure(.historyExpired))
            case .failure(let error): completion(.failure(error))
            case .success(let history):
                let refs = (history.history ?? []).flatMap { $0.messagesAdded ?? [] }.map(\.message)
                self.fetchMessages(refs, token: token, historyID: history.historyId, completion: completion)
            }
        }
    }

    private func fetchMessages(_ refs: [MessageReference], token: String, historyID: String?,
                               completion: @escaping (Result<GmailMailPoll, GmailMailClientError>) -> Void) {
        guard let first = refs.first else { completion(.success(.init(messages: [], latestHistoryId: historyID))); return }
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(first.id)")!
        components.queryItems = [
            .init(name: "format", value: "full")
        ]
        request(components.url!, token: token) { [weak self] (result: Result<MessageDetail, GmailMailClientError>) in
            guard let self else { return }
            switch result {
            case .failure(.transport("HTTP 404")):
                // Gmail history can reference a message that has already been
                // expunged. It is not a stale history cursor and must not make
                // us discard the rest of the current window.
                self.fetchMessages(Array(refs.dropFirst()), token: token, historyID: historyID, completion: completion)
            case .failure(let error): completion(.failure(error))
            case .success(let detail):
                let headers = Dictionary(uniqueKeysWithValues: (detail.payload?.headers ?? []).map { ($0.name, $0.value) })
                let date = Date(timeIntervalSince1970: (Double(detail.internalDate ?? "") ?? 0) / 1_000)
                let parts = Self.flatten(detail.payload)
                let text = parts.first(where: { $0.mimeType.lowercased() == "text/plain" })
                    .flatMap { Self.decode($0.body?.data).flatMap { String(data: $0, encoding: .utf8) } } ?? detail.snippet ?? ""
                let inlineAttachments = parts.compactMap { part -> EmailAttachment? in
                    guard !part.filename.isEmpty, let data = Self.decode(part.body?.data) else { return nil }
                    return EmailAttachment(filename: part.filename, mimeType: part.mimeType, data: data)
                }
                self.fetchReferencedAttachments(parts, messageID: detail.id, token: token) { referenced in
                    let message = GmailInboundMessage(id: detail.id, threadId: detail.threadId, receivedAt: date, headers: headers, bodyText: text, attachments: inlineAttachments + referenced)
                    self.fetchMessages(Array(refs.dropFirst()), token: token, historyID: historyID) { tail in
                        completion(tail.map { GmailMailPoll(messages: [message] + $0.messages, latestHistoryId: $0.latestHistoryId ?? historyID) })
                    }
                }
            }
        }
    }

    private func request<Response: Decodable>(_ url: URL, token: String,
                                              completion: @escaping (Result<Response, GmailMailClientError>) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(.transport(error.localizedDescription))); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { completion(.failure(.authorizationExpired)); return }
            guard (200..<300).contains(status), let data else { completion(.failure(.transport("HTTP \(status)"))); return }
            do { completion(.success(try JSONDecoder().decode(Response.self, from: data))) }
            catch { completion(.failure(.malformedResponse)) }
        }.resume()
    }

    private func fetchReferencedAttachments(_ parts: [Payload], messageID: String, token: String,
                                            completion: @escaping ([EmailAttachment]) -> Void) {
        let refs = parts.filter { !$0.filename.isEmpty && $0.body?.data == nil && $0.body?.attachmentId != nil }
        guard let first = refs.first, let attachmentID = first.body?.attachmentId else { completion([]); return }
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageID)/attachments/\(attachmentID)")!
        request(url, token: token) { [weak self] (result: Result<AttachmentBody, GmailMailClientError>) in
            guard let self else { completion([]); return }
            let firstAttachment: EmailAttachment?
            switch result {
            case .success(let value): firstAttachment = Self.decode(value.data).map { EmailAttachment(filename: first.filename, mimeType: first.mimeType, data: $0) }
            case .failure: firstAttachment = nil
            }
            self.fetchReferencedAttachments(Array(refs.dropFirst()), messageID: messageID, token: token) { rest in
                completion(firstAttachment.map { [$0] + rest } ?? rest)
            }
        }
    }

    private struct Profile: Decodable { let historyId: String }
    private struct HistoryList: Decodable { let history: [History]?; let historyId: String? }
    private struct History: Decodable { let messagesAdded: [AddedMessage]? }
    private struct AddedMessage: Decodable { let message: MessageReference }
    private struct MessageReference: Decodable { let id: String }
    private struct MessageDetail: Decodable { let id: String; let threadId: String; let internalDate: String?; let snippet: String?; let payload: Payload? }
    private struct Payload: Decodable { let mimeType: String; let filename: String; let headers: [Header]?; let body: Body?; let parts: [Payload]? }
    private struct Body: Decodable { let data: String?; let attachmentId: String? }
    private struct AttachmentBody: Decodable { let data: String }
    private struct Header: Decodable { let name: String; let value: String }
    private static func flatten(_ payload: Payload?) -> [Payload] { guard let payload else { return [] }; return [payload] + (payload.parts ?? []).flatMap(flatten) }
    private static func decode(_ encoded: String?) -> Data? { guard let encoded else { return nil }; let padded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - encoded.count % 4) % 4); return Data(base64Encoded: padded) }
}
