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

    var body: String? { text ?? caption }
    var timestamp: Date { Date(timeIntervalSince1970: date) }
}

struct TelegramUpdate: Decodable, Equatable {
    let updateId: Int
    let message: TelegramMessage?
    let channelPost: TelegramMessage?

    /// The one kind of payload the bridge acts on. Edits, reactions and the
    /// rest are deliberately not requested (`allowedUpdates`), so they never
    /// arrive.
    var payload: TelegramMessage? { message ?? channelPost }
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
                                message: nil, channelPost: nil)
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

    func getMe() throws -> TelegramBotInfo {
        try call("getMe", params: [:], deadline: Self.stallSeconds)
    }

    func getUpdates(offset: Int?, timeout: Int, limit: Int = 100) throws -> [TelegramUpdate] {
        var params: [String: Any] = [
            "timeout": timeout,
            "limit": limit,
            // Only what the bridge acts on. Asking for less also means a bot
            // added to a busy group is not woken for every reaction.
            "allowed_updates": ["message", "channel_post"],
        ]
        if let offset { params["offset"] = offset }
        let lenient: [LenientUpdate] = try call("getUpdates", params: params,
                                                deadline: timeout + Self.stallSeconds)
        return lenient.map(\.update)
    }

    /// `parseMode` is `"HTML"` or nil for plain text. Callers chunk to
    /// `TelegramFormatter.maxMessageLength` first; this sends one message.
    func sendMessage(chatId: String, text: String, parseMode: String?) throws {
        var params: [String: Any] = [
            "chat_id": chatId,
            "text": text,
            // Agent output is full of paths and URLs; a preview card under each
            // one is noise.
            "link_preview_options": ["is_disabled": true],
        ]
        if let parseMode { params["parse_mode"] = parseMode }
        let _: TelegramMessage = try call("sendMessage", params: params, deadline: Self.stallSeconds)
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

    // MARK: - Transport

    private func call<T: Decodable>(_ method: String, params: [String: Any], deadline: Int) throws -> T {
        lock.lock()
        let dead = invalidated
        lock.unlock()
        if dead { throw TelegramAPIError.cancelled }

        let body = try JSONSerialization.data(withJSONObject: params)
        let configURL = try writeConfig(method: method)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.curlPath)
        process.arguments = [
            "--silent", "--show-error",
            "--config", configURL.path,
            "--max-time", "\(deadline)",
            "--request", "POST",
            "--header", "Content-Type: application/json",
            "--data-binary", "@-",
        ]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let id = ObjectIdentifier(process)
        lock.lock()
        processes[id] = process
        lock.unlock()
        defer {
            lock.lock()
            processes.removeValue(forKey: id)
            lock.unlock()
        }

        do {
            try process.run()
        } catch {
            throw TelegramAPIError.network("could not start curl: \(error.localizedDescription)")
        }
        stdin.fileHandleForWriting.write(body)
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
            return try unwrap(output)
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
    private func writeConfig(method: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("seahelm-telegram-\(UUID().uuidString).curlrc")
        let contents = "url = \"\(Self.host)/bot\(token)/\(method)\"\n"
        guard FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw TelegramAPIError.network("could not write curl config")
        }
        return url
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
