import Foundation

// MARK: - Wire types

/// The slice of Telegram's `User` the bridge reads.
struct TelegramUser: Decodable, Equatable {
    let id: Int64
    let isBot: Bool?
    let firstName: String?
    let username: String?

    /// What a log line or a reply calls this person.
    var displayName: String {
        if let username, !username.isEmpty { return "@\(username)" }
        if let firstName, !firstName.isEmpty { return firstName }
        return String(id)
    }
}

struct TelegramChat: Decodable, Equatable {
    let id: Int64
    /// `private`, `group`, `supergroup`, or `channel`.
    let type: String
    let title: String?
    let username: String?

    var isPrivate: Bool { type == "private" }

    init(id: Int64, type: String, title: String?, username: String?) {
        self.id = id
        self.type = type
        self.title = title
        self.username = username
    }
}

/// The slice of a message the bridge needs when it is the *target* of a reply.
///
/// Not a `TelegramMessage`: a value type cannot contain itself, and the only
/// question ever asked of a reply target is who sent it — replying to the
/// bot's own message is how you address it in a group without typing its name.
struct TelegramReplyTarget: Decodable, Equatable {
    let messageId: Int
    let from: TelegramUser?
}

/// One size of a photo Telegram attaches to a message. The API sends several;
/// the bridge keeps the largest.
struct TelegramPhotoSize: Decodable, Equatable {
    let fileId: String
    let width: Int
    let height: Int
    let fileSize: Int?
}

/// A file sent as a document (including "Send as file" images).
struct TelegramDocument: Decodable, Equatable {
    let fileId: String
    let fileName: String?
    let mimeType: String?
    let fileSize: Int?
}

/// `getFile` result — `filePath` is the relative path under Telegram's file host.
struct TelegramFile: Decodable, Equatable {
    let fileId: String
    let fileUniqueId: String?
    let fileSize: Int?
    let filePath: String?
}

struct TelegramMessage: Decodable, Equatable {
    let messageId: Int
    /// Unix seconds.
    let date: TimeInterval
    let chat: TelegramChat
    /// Absent for channel posts and for admins posting anonymously.
    let from: TelegramUser?
    /// The channel a post was made as, when `from` is absent.
    let senderChat: TelegramChat?
    let text: String?
    /// A photo or document sent with a note carries the note here, not in `text`.
    let caption: String?
    /// Compressed photo sizes, smallest first. Absent when there is no photo.
    let photo: [TelegramPhotoSize]?
    /// Present when the user sent a file (including an image "as file").
    let document: TelegramDocument?
    /// The message this one replies to, when it replies to anything.
    let replyToMessage: TelegramReplyTarget?

    init(messageId: Int, date: TimeInterval, chat: TelegramChat, from: TelegramUser?,
         senderChat: TelegramChat?, text: String?, caption: String?,
         photo: [TelegramPhotoSize]? = nil, document: TelegramDocument? = nil,
         replyToMessage: TelegramReplyTarget? = nil) {
        self.messageId = messageId
        self.date = date
        self.chat = chat
        self.from = from
        self.senderChat = senderChat
        self.text = text
        self.caption = caption
        self.photo = photo
        self.document = document
        self.replyToMessage = replyToMessage
    }

    var body: String? { text ?? caption }
    var timestamp: Date { Date(timeIntervalSince1970: date) }
}

/// Someone tapped an inline button. `data` is the token the button carried out;
/// `message` is the one it hangs under, so the buttons can be taken off it.
struct TelegramCallbackQuery: Decodable, Equatable {
    let id: String
    let from: TelegramUser
    let message: TelegramMessage?
    let data: String?
}

struct TelegramUpdate: Decodable, Equatable {
    let updateId: Int
    let message: TelegramMessage?
    let channelPost: TelegramMessage?
    let callbackQuery: TelegramCallbackQuery?
    /// Someone pressed Stop under a streamed draft (`sendMessageDraft` with
    /// `can_stop`).
    var stoppedMessageGeneration: TelegramGenerationStopped? = nil

    /// The one kind of payload the bridge acts on. Edits, reactions and the
    /// rest are deliberately not requested (`allowedUpdates`), so they never
    /// arrive.
    var payload: TelegramMessage? { message ?? channelPost }
}

/// The Stop button under a draft was pressed.
///
/// `draft_id` is documented as an Integer and arrives as a string (`"62"`, seen
/// live), so it is read as either.
struct TelegramGenerationStopped: Decodable, Equatable {
    let chat: TelegramChat
    let draftId: Int

    init(chat: TelegramChat, draftId: Int) {
        self.chat = chat
        self.draftId = draftId
    }

    private enum CodingKeys: String, CodingKey { case chat, draftId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chat = try c.decode(TelegramChat.self, forKey: .chat)
        if let number = try? c.decode(Int.self, forKey: .draftId) {
            draftId = number
        } else if let text = try? c.decode(String.self, forKey: .draftId), let number = Int(text) {
            draftId = number
        } else {
            throw DecodingError.dataCorruptedError(forKey: .draftId, in: c,
                                                   debugDescription: "draft_id is neither a number nor a numeric string")
        }
    }
}

struct TelegramBotInfo: Decodable, Equatable {
    let id: Int64
    let username: String?
    let firstName: String?
}

private struct TelegramEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
    let errorCode: Int?
    let description: String?
}

/// An update whose body failed to decode still has an id, and that id must
/// still advance the offset — otherwise one odd payload Telegram starts
/// sending (a new field with a type we did not expect) would be re-fetched
/// forever and wedge the bridge on it.
private struct LenientUpdate: Decodable {
    let update: TelegramUpdate

    private enum CodingKeys: String, CodingKey { case updateId }

    init(from decoder: Decoder) throws {
        if let whole = try? TelegramUpdate(from: decoder) {
            update = whole
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        update = TelegramUpdate(updateId: try c.decode(Int.self, forKey: .updateId),
                                message: nil, channelPost: nil, callbackQuery: nil)
    }
}

// MARK: - Errors

enum TelegramAPIError: LocalizedError, Equatable {
    /// Transport-level: DNS, TLS, timeout, no route.
    case network(String)
    /// Telegram answered, but not with the envelope every method returns.
    case badResponse
    /// Telegram said no. `code` is the HTTP status it chose (400, 401, 409…).
    case api(code: Int, description: String)
    /// The session was invalidated mid-request — the bridge is disconnecting.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .network(let msg): return "Could not reach Telegram: \(msg)"
        case .badResponse: return "Telegram returned an unexpected response"
        case .api(let code, let description):
            switch code {
            case 401, 404: return "Telegram rejected the bot token (\(code) \(description))"
            case 409: return "Another client is already polling this bot — a webhook is set, or a second seahelm is running (\(description))"
            default: return "Telegram error \(code): \(description)"
            }
        case .cancelled: return "Cancelled"
        }
    }

    /// Retrying will not help: the token is wrong. A 409 (another poller) is
    /// deliberately *not* here — the other poller is usually this app's
    /// previous instance still shutting down, and it resolves itself.
    var isFatal: Bool {
        if case .api(let code, _) = self { return code == 401 || code == 404 }
        return false
    }

    var isBadRequest: Bool {
        if case .api(400, _) = self { return true }
        return false
    }

    /// Telegram's way of saying "that edit would change nothing".
    ///
    /// It arrives as a 400, but it is the API agreeing with us: the message
    /// already says and offers exactly this. Every caller that edits does so
    /// repeatedly by design — a progress line rewritten each tick, a card whose
    /// buttons are set again when the same suggestion lands twice — so treating
    /// it as a failure fills the log with the bridge working correctly.
    var isNotModified: Bool {
        if case .api(400, let description) = self {
            return description.contains("message is not modified")
        }
        return false
    }
}

// MARK: - Client

/// The three Bot API methods the bridge uses, as blocking calls.
///
/// Blocking on purpose: the caller is a long-poll loop on its own thread, and
/// `getUpdates` is *meant* to sit open for twenty seconds. A completion-handler
/// shape would only reinvent that loop with more state.
///
/// The transport is the system libcurl (`CurlClient`), not URLSession —
/// deliberately; see `CurlClient` for why, and for the connection reuse that
/// keeps a reply from costing a fresh TLS handshake. The token is in the URL
/// and so never leaves this process: no command line, no temp file.
final class TelegramBotAPI {
    static let host = "https://api.telegram.org"
    /// How long `getUpdates` holds the request open. Telegram closes it
    /// itself when this elapses.
    static let longPollSeconds = 20
    /// Slack past the long poll before a call is abandoned; short calls get
    /// this alone.
    static let stallSeconds = 15

    private let token: String
    private let http = CurlClient()
    private let lock = NSLock()
    private var invalidated = false
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(token: String) {
        self.token = token
    }

    /// Ends whatever is in flight — within a second, the next time libcurl
    /// checks — and the blocked caller sees `.cancelled`. The client is
    /// unusable afterwards — make a new one to reconnect.
    func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    private var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }

    func getMe() throws -> TelegramBotInfo {
        try call("getMe", params: [:], deadline: Self.stallSeconds)
    }

    func getUpdates(offset: Int?, timeout: Int, limit: Int = 100) throws -> [TelegramUpdate] {
        var params: [String: Any] = [
            "timeout": timeout,
            "limit": limit,
            // Only what the bridge acts on. Asking for less also means a bot
            // added to a busy group is not woken for every reaction. A button
            // tap is a `callback_query` and arrives on no other channel — leave
            // it out and the inline keyboards below are decorative.
            // A draft's Stop button is `stopped_message_generation`; Telegram
            // drops it outright — no later delivery — unless it is asked for.
            "allowed_updates": ["message", "channel_post", "callback_query",
                                "stopped_message_generation"],
        ]
        if let offset { params["offset"] = offset }
        let lenient: [LenientUpdate] = try call("getUpdates", params: params,
                                                deadline: timeout + Self.stallSeconds)
        return lenient.map(\.update)
    }

    /// `parseMode` is `"HTML"` or nil for plain text. Callers chunk to
    /// `TelegramFormatter.maxMessageLength` first; this sends one message.
    ///
    /// `buttons` become a one-per-row inline keyboard. Returns the sent
    /// message's id, which is what a later `editMessageReplyMarkup` needs to
    /// take those buttons off again.
    @discardableResult
    func sendMessage(chatId: String, text: String, parseMode: String?,
                     buttons: [MessageButton] = []) throws -> Int {
        var params: [String: Any] = [
            "chat_id": chatId,
            "text": text,
            // Agent output is full of paths and URLs; a preview card under each
            // one is noise.
            "link_preview_options": ["is_disabled": true],
        ]
        if let parseMode { params["parse_mode"] = parseMode }
        if !buttons.isEmpty {
            params["reply_markup"] = ["inline_keyboard": Self.keyboard(buttons)]
        }
        let sent: TelegramMessage = try call("sendMessage", params: params, deadline: Self.stallSeconds)
        return sent.messageId
    }

    /// Stream a partial message into a private chat — Telegram's own
    /// "typing" preview, animated in place while `draftId` stays the same.
    ///
    /// Private chats only (a group answers `TEXTDRAFT_PEER_INVALID`), one draft
    /// per chat at a time (a different id replaces it), and ephemeral: it
    /// fades about 12s after the last call (the docs say 30) and the moment
    /// the bot sends anything else there. Nothing is ever persisted — what is
    /// worth keeping goes out with `sendMessage`.
    func sendMessageDraft(chatId: String, draftId: Int, text: String, parseMode: String?,
                          canStop: Bool) throws {
        var params: [String: Any] = ["chat_id": chatId, "draft_id": draftId, "text": text]
        if let parseMode { params["parse_mode"] = parseMode }
        if canStop { params["can_stop"] = true }
        let _: Bool = try call("sendMessageDraft", params: params, deadline: Self.stallSeconds)
    }

    /// One button per row: an option is a sentence, and Telegram truncates a
    /// row it cannot fit rather than wrapping it.
    static func keyboard(_ buttons: [MessageButton]) -> [[[String: String]]] {
        buttons.map { [["text": trimLabel($0.label), "callback_data": $0.token]] }
    }

    /// Telegram's own cap is generous but a button wider than the phone reads
    /// as a wall of text. Cut on a whole character, keeping the front, which is
    /// where an option says what it does.
    static func trimLabel(_ label: String, limit: Int = 48) -> String {
        let flat = label.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "\u{2026}"
    }

    /// Stop the spinner on the tapper's phone, optionally with a toast.
    ///
    /// Telegram shows a button as pending until this lands, so it is answered
    /// even when the tap turned out to be stale: an unanswered query reads as
    /// the bot having died mid-tap.
    func answerCallbackQuery(id: String, text: String?) throws {
        var params: [String: Any] = ["callback_query_id": id]
        if let text, !text.isEmpty { params["text"] = String(text.prefix(200)) }
        let _: Bool = try call("answerCallbackQuery", params: params, deadline: Self.stallSeconds)
    }

    /// Put a keyboard on a message already sent, or take one off with `[]`.
    ///
    /// Both directions matter. An answered card must stop offering its options
    /// — the message stays in the chat's history forever and a second tap would
    /// drive the pane's TUI again — and an agent's suggested next steps arrive
    /// a beat after the completion notice they belong under, so they are added
    /// to that message rather than sent as a second one saying the same words.
    func setReplyMarkup(chatId: String, messageId: Int, buttons: [MessageButton]) throws {
        var params: [String: Any] = ["chat_id": chatId, "message_id": messageId]
        if !buttons.isEmpty {
            params["reply_markup"] = ["inline_keyboard": Self.keyboard(buttons)]
        }
        // Editing a chat message answers with the edited message, not `true`
        // — that shape is only for inline-mode messages, which this is not.
        let _: TelegramMessage = try call("editMessageReplyMarkup", params: params,
                                          deadline: Self.stallSeconds)
    }

    /// Rewrite the text of a message this bot already sent.
    ///
    /// Telegram has no streaming primitive; a line that changes while an agent
    /// works is this method called again on the same message id. Two of its
    /// failures are ordinary rather than exceptional and the caller is expected
    /// to swallow them: editing to *identical* text is a 400 ("message is not
    /// modified"), and editing too often is a 429. Neither is worth a retry —
    /// the next update supersedes this one anyway.
    func editMessageText(chatId: String, messageId: Int, text: String, parseMode: String?) throws {
        var params: [String: Any] = ["chat_id": chatId, "message_id": messageId, "text": text]
        if let parseMode { params["parse_mode"] = parseMode }
        // As with the keyboard edit, the answer is the edited message.
        let _: TelegramMessage = try call("editMessageText", params: params, deadline: Self.stallSeconds)
    }

    /// Take back a message this bot sent. Telegram allows this for 48 hours,
    /// which is far longer than a transient status line lives.
    func deleteMessage(chatId: String, messageId: Int) throws {
        let _: Bool = try call("deleteMessage", params: ["chat_id": chatId, "message_id": messageId],
                               deadline: Self.stallSeconds)
    }

    /// Publish the verb table to Telegram, so typing `/` in the chat lists the
    /// commands instead of requiring the user to have read `/help` once.
    ///
    /// Set at setup rather than on every connect: it is per-bot state Telegram
    /// keeps, not per-session, and re-sending it on each launch would spend a
    /// round trip to write what is already there.
    func setMyCommands(_ commands: [(command: String, description: String)]) throws {
        let payload = commands.map { ["command": $0.command, "description": $0.description] }
        let _: Bool = try call("setMyCommands", params: ["commands": payload],
                               deadline: Self.stallSeconds)
    }

    /// Drop any webhook registered against this bot.
    ///
    /// A webhook and `getUpdates` are mutually exclusive — the second one to
    /// ask gets 409 — and a bot that was once wired to something else keeps its
    /// webhook forever. Clearing it during setup turns a confusing "another
    /// client is already polling" into a bot that simply works.
    func deleteWebhook() throws {
        let _: Bool = try call("deleteWebhook", params: ["drop_pending_updates": false],
                               deadline: Self.stallSeconds)
    }

    /// Resolve a `file_id` to a downloadable path on Telegram's file host.
    func getFile(fileId: String) throws -> TelegramFile {
        try call("getFile", params: ["file_id": fileId], deadline: Self.stallSeconds)
    }

    /// Download the bytes at `filePath` from a prior `getFile`. Caps at
    /// `maxBytes` so a hostile or huge upload cannot fill the disk.
    func downloadFile(path filePath: String, maxBytes: Int = TelegramInboundMedia.maxBytes) throws -> Data {
        // Paths from Telegram are relative (`photos/file_0.jpg`); reject anything
        // that could escape the file host prefix.
        guard !filePath.hasPrefix("/"), !filePath.contains(".."),
              !filePath.contains("://") else {
            throw TelegramAPIError.badResponse
        }
        let response = try request(url: "\(Self.host)/file/bot\(token)/\(filePath)", body: nil,
                                   deadline: Self.stallSeconds, maxBytes: maxBytes)
        // A file path that went stale answers with a JSON error, not bytes.
        guard response.status == 200, !response.body.isEmpty else {
            throw TelegramAPIError.badResponse
        }
        return response.body
    }

    // MARK: - Transport

    private func call<T: Decodable>(_ method: String, params: [String: Any], deadline: Int) throws -> T {
        let body = try JSONSerialization.data(withJSONObject: params)
        // Not judged on the HTTP status: Telegram's 4xx answers carry the
        // `{ok: false, …}` envelope, and its description is the useful part.
        let response = try request(url: "\(Self.host)/bot\(token)/\(method)", body: body,
                                   deadline: deadline)
        return try unwrap(response.body)
    }

    private func request(url: String, body: Data?, deadline: Int,
                         maxBytes: Int = .max) throws -> CurlClient.Response {
        if isInvalidated { throw TelegramAPIError.cancelled }
        do {
            return try http.perform(url: url, body: body, timeout: deadline, maxBytes: maxBytes,
                                    isCancelled: { [weak self] in self?.isInvalidated ?? true })
        } catch let failure as CurlClient.Failure {
            switch failure {
            case .cancelled:
                throw TelegramAPIError.cancelled
            case .timedOut:
                throw TelegramAPIError.network("no response within \(deadline)s")
            case .tooLarge:
                throw TelegramAPIError.network("file exceeds \(maxBytes) bytes")
            case .transport(let reason):
                throw TelegramAPIError.network(scrub(reason))
            }
        }
    }

    /// Every method answers `{ok, result}` or `{ok: false, error_code,
    /// description}`; this is the one place that shape is known.
    private func unwrap<T: Decodable>(_ data: Data) throws -> T {
        guard let envelope = try? decoder.decode(TelegramEnvelope<T>.self, from: data) else {
            throw TelegramAPIError.badResponse
        }
        guard envelope.ok, let value = envelope.result else {
            throw TelegramAPIError.api(code: envelope.errorCode ?? 0,
                                       description: scrub(envelope.description ?? "unknown error"))
        }
        return value
    }

    /// The `getUpdates` decode path, minus the transport, so the lenient
    /// per-update handling can be tested against captured JSON.
    func decodeUpdatesForTesting(_ data: Data) throws -> [TelegramUpdate] {
        let lenient: [LenientUpdate] = try unwrap(data)
        return lenient.map(\.update)
    }

    /// Nothing that reaches a log or an alert may carry the token.
    private func scrub(_ message: String) -> String {
        message.replacingOccurrences(of: token, with: "<token>")
    }
}
