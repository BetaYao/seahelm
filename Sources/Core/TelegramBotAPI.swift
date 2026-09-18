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
    /// True when the supergroup has topics turned on. Not consulted for
    /// routing — a message says which topic it is in — but it is what tells a
    /// log line why one group threads its replies and another does not.
    let isForum: Bool?

    var isPrivate: Bool { type == "private" }

    init(id: Int64, type: String, title: String?, username: String?, isForum: Bool? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.username = username
        self.isForum = isForum
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
    /// The forum topic this message sits in — but also, in a plain group, the
    /// reply chain it belongs to, and since Bot API 10.0 a private chat's own
    /// topic. Only `TelegramChatAddress` decides which of those can be replied
    /// into; nothing else should read this field.
    let messageThreadId: Int?
    /// True when the message was posted to a topic rather than to the chat at
    /// large. Absent for General, which is the chat at large.
    let isTopicMessage: Bool?

    init(messageId: Int, date: TimeInterval, chat: TelegramChat, from: TelegramUser?,
         senderChat: TelegramChat?, text: String?, caption: String?,
         photo: [TelegramPhotoSize]? = nil, document: TelegramDocument? = nil,
         replyToMessage: TelegramReplyTarget? = nil,
         messageThreadId: Int? = nil, isTopicMessage: Bool? = nil) {
        self.messageThreadId = messageThreadId
        self.isTopicMessage = isTopicMessage
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

    /// The one kind of payload the bridge acts on. Edits, reactions and the
    /// rest are deliberately not requested (`allowedUpdates`), so they never
    /// arrive.
    var payload: TelegramMessage? { message ?? channelPost }
}

/// The slice of `getChatMember` the bridge reads: what this bot may do in a
/// chat. `canManageTopics` is absent for anyone who is not an administrator,
/// which reads the same as not having it.
struct TelegramChatMember: Decodable, Equatable {
    let status: String
    let canManageTopics: Bool?

    var isAdministrator: Bool { status == "administrator" || status == "creator" }
    /// The group's creator may always manage topics; Telegram leaves the flag
    /// off for them rather than setting it true.
    var mayManageTopics: Bool { status == "creator" || canManageTopics == true }
}

/// What `createForumTopic` answers with: the thread id every later message
/// into this topic carries.
struct TelegramForumTopic: Decodable, Equatable {
    let messageThreadId: Int
    let name: String
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
}

// MARK: - Client

/// The three Bot API methods the bridge uses, as blocking calls.
///
/// Blocking on purpose: the caller is a long-poll loop on its own thread, and
/// `getUpdates` is *meant* to sit open for twenty seconds. A completion-handler
/// shape would only reinvent that loop with more state.
///
/// The transport is `/usr/bin/curl`, not URLSession — deliberately. Inside
/// this process, URLSession requests to Telegram hung: the first one or two
/// completed, then most sat until their timeout, and some past it, with
/// neither a response nor an error, while the identical requests from a
/// standalone process (and from curl) completed every time. Per-request
/// sessions, a client-side watchdog and shorter polls all failed to make it
/// reliable. curl in a child process shares none of this process's network
/// state, ships with every macOS, and worked without a single failure. The
/// token never appears on a command line: it travels in a 0600 config file
/// curl reads and that is deleted the moment the request ends.
final class TelegramBotAPI {
    static let host = "https://api.telegram.org"
    /// How long `getUpdates` holds the request open. Telegram closes it
    /// itself when this elapses.
    static let longPollSeconds = 20
    /// Slack past the long poll before a call is abandoned; short calls get
    /// this alone.
    static let stallSeconds = 15
    static let curlPath = "/usr/bin/curl"

    private let token: String
    private let lock = NSLock()
    private var invalidated = false
    private var processes: [ObjectIdentifier: Process] = [:]
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(token: String) {
        self.token = token
    }

    /// Ends whatever is in flight; the blocked caller sees `.cancelled`.
    /// The client is unusable afterwards — make a new one to reconnect.
    func invalidate() {
        lock.lock()
        invalidated = true
        let live = Array(processes.values)
        lock.unlock()
        for process in live where process.isRunning { process.terminate() }
    }

    /// What a chat is — asked for one thing only: whether it is a forum.
    func getChat(chatId: String) throws -> TelegramChat {
        try call("getChat", params: ["chat_id": chatId], deadline: Self.stallSeconds)
    }

    /// This bot's standing in a chat, for the rights it needs there.
    func getChatMember(chatId: String, userId: Int64) throws -> TelegramChatMember {
        try call("getChatMember", params: ["chat_id": chatId, "user_id": userId],
                 deadline: Self.stallSeconds)
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
            "allowed_updates": ["message", "channel_post", "callback_query"],
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
    ///
    /// `messageThreadId` posts into a forum topic. It is left off for every
    /// other kind of chat — including a forum's General topic, which Telegram
    /// rejects a thread id for; see `TelegramChatAddress`.
    @discardableResult
    func sendMessage(chatId: String, text: String, parseMode: String?,
                     buttons: [MessageButton] = [], messageThreadId: Int? = nil) throws -> Int {
        var params: [String: Any] = [
            "chat_id": chatId,
            "text": text,
            // Agent output is full of paths and URLs; a preview card under each
            // one is noise.
            "link_preview_options": ["is_disabled": true],
        ]
        if let parseMode { params["parse_mode"] = parseMode }
        if let messageThreadId { params["message_thread_id"] = messageThreadId }
        if !buttons.isEmpty {
            params["reply_markup"] = ["inline_keyboard": Self.keyboard(buttons)]
        }
        let sent: TelegramMessage = try call("sendMessage", params: params, deadline: Self.stallSeconds)
        return sent.messageId
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

    // MARK: - Forum topics

    /// Open a topic in a forum supergroup and return it.
    ///
    /// Needs the bot to be an administrator with `can_manage_topics`; without
    /// it Telegram answers 400 and there is nothing to retry — someone has to
    /// grant the right in the group.
    func createForumTopic(chatId: String, name: String, iconColor: Int?) throws -> TelegramForumTopic {
        var params: [String: Any] = ["chat_id": chatId, "name": Self.trimTopicName(name)]
        if let iconColor { params["icon_color"] = iconColor }
        return try call("createForumTopic", params: params, deadline: Self.stallSeconds)
    }

    /// Rename a topic. Agents rewrite their own session titles as the work
    /// turns, and a thread still called by the first prompt three hours in is
    /// worse than no name at all.
    func editForumTopic(chatId: String, messageThreadId: Int, name: String) throws {
        let _: Bool = try call("editForumTopic",
                               params: ["chat_id": chatId,
                                        "message_thread_id": messageThreadId,
                                        "name": Self.trimTopicName(name)],
                               deadline: Self.stallSeconds)
    }

    /// Close a topic: it folds into the group's closed list and stops taking
    /// messages, but keeps everything said in it.
    ///
    /// Deliberately not `deleteForumTopic`. A pane ending is not a reason to
    /// destroy the record of what it did, and deletion cannot be undone.
    func closeForumTopic(chatId: String, messageThreadId: Int) throws {
        let _: Bool = try call("closeForumTopic",
                               params: ["chat_id": chatId, "message_thread_id": messageThreadId],
                               deadline: Self.stallSeconds)
    }

    /// Telegram caps a topic name at 128 characters and rejects an empty one.
    static func trimTopicName(_ name: String, limit: Int = 128) -> String {
        let flat = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if flat.isEmpty { return "seahelm" }
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "\u{2026}"
    }

    /// The six colours Telegram allows a topic icon to take. Anything else is a
    /// 400, so a colour is chosen from this list rather than computed.
    static let topicIconColors = [0x6FB9F0, 0xFFD67E, 0xCB86DB, 0x8EEE98, 0xFF93B2, 0xFB6F5F]

    /// One colour per project, stable across launches, so a glance at the topic
    /// list groups by repo. A sum of scalars rather than `hashValue`: Swift's
    /// hashing is seeded per process and would repaint the list on every start.
    static func topicIconColor(for key: String) -> Int {
        guard !key.isEmpty else { return topicIconColors[0] }
        let sum = key.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 100_003 }
        return topicIconColors[sum % topicIconColors.count]
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
        lock.lock()
        let dead = invalidated
        lock.unlock()
        if dead { throw TelegramAPIError.cancelled }

        let configURL = try writeFileConfig(filePath: filePath)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let output = try runCurl(configURL: configURL, deadline: Self.stallSeconds, body: nil)
        guard output.count <= maxBytes else {
            throw TelegramAPIError.network("file exceeds \(maxBytes) bytes")
        }
        guard !output.isEmpty else {
            throw TelegramAPIError.badResponse
        }
        return output
    }

    // MARK: - Transport

    private func call<T: Decodable>(_ method: String, params: [String: Any], deadline: Int) throws -> T {
        let body = try JSONSerialization.data(withJSONObject: params)
        let configURL = try writeConfig(url: "\(Self.host)/bot\(token)/\(method)")
        defer { try? FileManager.default.removeItem(at: configURL) }
        let output = try runCurl(configURL: configURL, deadline: deadline, body: body)
        return try unwrap(output)
    }

    /// GET a file URL — raw bytes, no `{ok, result}` envelope.
    private func writeFileConfig(filePath: String) throws -> URL {
        // Paths from Telegram are relative (`photos/file_0.jpg`); reject anything
        // that could escape the file host prefix.
        guard !filePath.hasPrefix("/"), !filePath.contains(".."),
              !filePath.contains("://") else {
            throw TelegramAPIError.badResponse
        }
        return try writeConfig(url: "\(Self.host)/file/bot\(token)/\(filePath)")
    }

    private func runCurl(configURL: URL, deadline: Int, body: Data?) throws -> Data {
        lock.lock()
        let dead = invalidated
        lock.unlock()
        if dead { throw TelegramAPIError.cancelled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.curlPath)
        var args = [
            "--silent", "--show-error",
            "--config", configURL.path,
            "--max-time", "\(deadline)",
        ]
        if body != nil {
            args += ["--request", "POST",
                     "--header", "Content-Type: application/json",
                     "--data-binary", "@-"]
        }
        process.arguments = args
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Every end, not just the ones we read. `readDataToEndOfFile` does not
        // close, and the poll thread that owns these calls has no autorelease
        // pool of its own — leaving a handle open leaked two descriptors per
        // call (~2800 pipes after a workday of long-polls). Same rule as
        // `ProcessRunner.drain`.
        let allHandles = [
            stdin.fileHandleForReading, stdin.fileHandleForWriting,
            stdout.fileHandleForReading, stdout.fileHandleForWriting,
            stderr.fileHandleForReading, stderr.fileHandleForWriting,
        ]
        func closePipes() {
            for handle in allHandles { try? handle.close() }
        }

        let id = ObjectIdentifier(process)
        lock.lock()
        processes[id] = process
        lock.unlock()
        defer {
            lock.lock()
            processes.removeValue(forKey: id)
            lock.unlock()
            closePipes()
        }

        do {
            try process.run()
        } catch {
            throw TelegramAPIError.network("could not start curl: \(error.localizedDescription)")
        }
        if let body {
            stdin.fileHandleForWriting.write(body)
        }
        try? stdin.fileHandleForWriting.close()
        // Drain both pipes before waiting, or a large reply fills the pipe and
        // curl blocks on write while we block on exit.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        lock.lock()
        let cancelled = invalidated
        lock.unlock()
        if cancelled { throw TelegramAPIError.cancelled }

        switch process.terminationStatus {
        case 0:
            return output
        case 28:
            throw TelegramAPIError.network("no response within \(deadline)s")
        default:
            let reason = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TelegramAPIError.network(scrub(reason.isEmpty ? "curl exit \(process.terminationStatus)" : reason))
        }
    }

    /// The URL — and so the token — goes to curl through a private file
    /// rather than an argument, where every other user on the machine could
    /// read it with `ps`.
    private func writeConfig(url: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let configURL = dir.appendingPathComponent("seahelm-telegram-\(UUID().uuidString).curlrc")
        let contents = "url = \"\(url)\"\n"
        guard FileManager.default.createFile(atPath: configURL.path, contents: Data(contents.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw TelegramAPIError.network("could not write curl config")
        }
        return configURL
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
