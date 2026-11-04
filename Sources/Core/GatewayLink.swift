import Foundation

/// The app's link to seahelm-gateway, the service that serves seahelm-web, the
/// share links and the Telegram bot (docs/seahelm-gateway-plan.md). The app
/// only makes sure it runs and edits its settings; it never relays anything
/// through it.
///
/// - **Running**: `seahelm-gateway ensure` at launch, the binary shipped in
///   Contents/Resources/bin beside seahelm-core.
/// - **Settings**: `GatewayClient`, over `gateway.sock`.
final class GatewayLink {
    static let shared = GatewayLink()

    private var started = false

    /// Contents/Resources/bin/seahelm-gateway, else `$SEAHELM_GATEWAY_BIN`, else PATH.
    static var binary: String? {
        if let url = Bundle.main.url(forResource: "seahelm-gateway", withExtension: nil, subdirectory: "bin"),
           FileManager.default.isExecutableFile(atPath: url.path) { return url.path }
        if let env = ProcessInfo.processInfo.environment["SEAHELM_GATEWAY_BIN"], !env.isEmpty { return env }
        return ProcessRunner.commandPath("seahelm-gateway")
    }

    /// Start the gateway detached unless it already answers. Off main; once.
    func start() {
        guard !started else { return }
        started = true
        DispatchQueue.global(qos: .utility).async {
            guard let binary = Self.binary else {
                NSLog("[GatewayLink] no seahelm-gateway binary; web access and Telegram are off")
                return
            }
            let result = ProcessRunner.capture(executable: URL(fileURLWithPath: binary), arguments: ["ensure"], timeout: 10)
            if !result.succeeded { NSLog("[GatewayLink] seahelm-gateway ensure failed") }
        }
    }
}

// MARK: - gateway.sock

/// seahelm-gateway's admin socket (`$SEAHELM_GATEWAY_SOCKET`, else
/// `~/.config/seahelm/gateway.sock`). The blocking `call` must never run on
/// main; `request` runs it off main and completes on main.
enum GatewayClient {
    typealias Failure = CoreSocketClient.Failure

    static var path: String { CoreSocketClient.socketPath(envKey: "SEAHELM_GATEWAY_SOCKET", fileName: "gateway.sock") }

    /// What the panes say when the gateway does not answer.
    static let notRunningMessage = "seahelm-gateway is not running"

    static func call(_ method: String, _ params: [String: Any] = [:],
                     timeout: TimeInterval = 5) -> Result<[String: Any], Failure> {
        CoreSocketClient.call(method, params, timeout: timeout, path: path)
    }

    /// `call` off main, answered on main.
    static func request(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 5,
                        completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = call(method, params, timeout: timeout)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// A failure as one line for a status label.
    static func describe(_ failure: Failure) -> String {
        switch failure {
        case .unreachable: return notRunningMessage
        case .rpc(_, let message): return message.isEmpty ? "seahelm-gateway refused it" : message
        case .malformed: return "seahelm-gateway answered something unreadable"
        }
    }

    // MARK: Typed helpers

    static func status(_ done: @escaping (Result<GatewayStatus, Failure>) -> Void) {
        request("gateway.status") { done($0.map(GatewayStatus.init)) }
    }

    static func config(_ done: @escaping (Result<GatewaySettings, Failure>) -> Void) {
        request("gateway.config.get") { done($0.map(GatewaySettings.init)) }
    }

    /// `patch` is `{web?: {...}, telegram?: {...}}`, partial; `bot_token: ""` clears it.
    static func setConfig(_ patch: [String: Any], _ done: @escaping (Result<GatewaySettings, Failure>) -> Void) {
        request("gateway.config.set", patch, timeout: 15) { done($0.map(GatewaySettings.init)) }
    }

    static func pairingCode(_ done: @escaping (Result<GatewayPairingCode, Failure>) -> Void) {
        request("pairing.code.get") { done($0.map(GatewayPairingCode.init)) }
    }

    static func refreshPairingCode(_ done: @escaping (Result<GatewayPairingCode, Failure>) -> Void) {
        request("pairing.code.refresh") { done($0.map(GatewayPairingCode.init)) }
    }

    /// `-32602` when the code is not 8–16 digits.
    static func setPairingCode(_ code: String, _ done: @escaping (Result<GatewayPairingCode, Failure>) -> Void) {
        request("pairing.code.set", ["code": code]) { done($0.map(GatewayPairingCode.init)) }
    }

    static func revokeAll(_ done: @escaping (Result<Void, Failure>) -> Void) {
        request("pairing.revoke_all") { done($0.map { _ in () }) }
    }

    static func devices(_ done: @escaping (Result<[GatewayDevice], Failure>) -> Void) {
        request("devices.list") { result in
            done(result.map { ($0["devices"] as? [[String: Any]] ?? []).compactMap(GatewayDevice.init) })
        }
    }

    static func revokeDevice(id: String, _ done: @escaping (Result<Void, Failure>) -> Void) {
        request("devices.revoke", ["id": id]) { done($0.map { _ in () }) }
    }

    static func createShare(paneSessionKey: String, label: String, lifetime: ShareLinkLifetime,
                            recipient: String?, _ done: @escaping (Result<GatewayShareCreated, Failure>) -> Void) {
        var params: [String: Any] = ["pane_session_key": paneSessionKey, "label": label,
                                     "lifetime_seconds": lifetime.seconds.map { Int($0) as Any } ?? NSNull()]
        if let recipient { params["recipient"] = recipient }
        request("share.create", params) { result in
            done(result.flatMap { GatewayShareCreated($0).map { .success($0) } ?? .failure(.malformed) })
        }
    }

    static func shares(_ done: @escaping (Result<[GatewayShareLink], Failure>) -> Void) {
        request("share.list") { result in
            done(result.map { ($0["links"] as? [[String: Any]] ?? []).compactMap(GatewayShareLink.init) })
        }
    }

    /// Only the fields given change. `lifetime` restarts the clock from now;
    /// `recipient: .some(nil)` opens the link to anyone again.
    static func updateShare(id: String, lifetime: ShareLinkLifetime? = nil, recipient: String?? = nil,
                            _ done: @escaping (Result<GatewayShareLink, Failure>) -> Void) {
        var params: [String: Any] = ["id": id]
        if let lifetime { params["lifetime_seconds"] = lifetime.seconds.map { Int($0) as Any } ?? NSNull() }
        if let recipient { params["recipient"] = recipient ?? NSNull() }
        request("share.update", params) { result in
            done(result.flatMap { GatewayShareLink($0).map { .success($0) } ?? .failure(.malformed) })
        }
    }

    static func revokeShare(id: String, _ done: @escaping (Result<Void, Failure>) -> Void = { _ in }) {
        request("share.revoke", ["id": id]) { done($0.map { _ in () }) }
    }

    static func revokeShares(paneSessionKey: String, _ done: @escaping (Result<Void, Failure>) -> Void = { _ in }) {
        request("share.revoke", ["pane_session_key": paneSessionKey]) { done($0.map { _ in () }) }
    }

    static func validateTelegramToken(_ token: String, _ done: @escaping (Result<GatewayTokenCheck, Failure>) -> Void) {
        request("telegram.validate_token", ["bot_token": token], timeout: 20) { done($0.map(GatewayTokenCheck.init)) }
    }

    static func beginTelegramPairing(_ done: @escaping (Result<GatewayTelegramPairing, Failure>) -> Void) {
        request("telegram.pair.begin", timeout: 15) { done($0.map(GatewayTelegramPairing.init)) }
    }

    static func cancelTelegramPairing() {
        request("telegram.pair.cancel") { _ in }
    }
}

// MARK: - Shapes

/// Seconds since 1970 (or milliseconds, past 1e12), or an ISO-8601 string.
enum GatewayTime {
    static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber, !(value is Bool) {
            let v = n.doubleValue
            guard v > 0 else { return nil }
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        if let s = value as? String, !s.isEmpty {
            let f = ISO8601DateFormatter()
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s)
        }
        return nil
    }
}

private func string(_ value: Any?) -> String? {
    if let s = value as? String { return s.isEmpty ? nil : s }
    if let n = value as? NSNumber, !(value is Bool) { return n.stringValue }
    return nil
}

/// `gateway.status`.
struct GatewayStatus: Equatable {
    struct Web: Equatable {
        var enabled = false
        var listening = false
        var port: Int?
        var publicURL: String?
        var error: String?
        var clients = 0
    }
    struct Telegram: Equatable {
        var enabled = false
        var configured = false
        var connected = false
        var botUsername: String?
        var error: String?
    }
    var web = Web()
    var telegram = Telegram()
    var coreReachable = false

    init() {}

    init(_ r: [String: Any]) {
        let w = r["web"] as? [String: Any] ?? [:]
        web = Web(enabled: w["enabled"] as? Bool ?? false,
                  listening: w["listening"] as? Bool ?? false,
                  port: (w["port"] as? NSNumber)?.intValue,
                  publicURL: string(w["public_url"]),
                  error: string(w["error"]),
                  clients: (w["clients"] as? NSNumber)?.intValue ?? 0)
        let t = r["telegram"] as? [String: Any] ?? [:]
        telegram = Telegram(enabled: t["enabled"] as? Bool ?? false,
                            configured: t["configured"] as? Bool ?? false,
                            connected: t["connected"] as? Bool ?? false,
                            botUsername: string(t["bot_username"]),
                            error: string(t["error"]))
        coreReachable = (r["core"] as? [String: Any])?["reachable"] as? Bool ?? false
    }
}

/// `gateway.config.get` / `.set`.
struct GatewaySettings: Equatable {
    struct Web: Equatable {
        var enabled = false
        var port: Int = 2783
        var publicURL: String?
        var webRoot: String?
        var telegramHost: String?

        /// The page a browser opens: the public URL's origin, else localhost.
        var pageURL: String {
            if let publicURL, var c = URLComponents(string: publicURL), c.host != nil {
                if c.scheme == "wss" { c.scheme = "https" } else if c.scheme == "ws" { c.scheme = "http" }
                c.path = "/"
                c.query = nil
                if let s = c.string { return s }
            }
            return "http://127.0.0.1:\(port)/"
        }
    }
    struct Telegram: Equatable {
        var enabled = false
        var botTokenSet = false
        var allowedUsers: [String] = []
        var defaultChatId: String?
        var backfillSeconds: Int?
        var rules: [TelegramRule] = []
        var miniAppURL: String?
    }
    var web = Web()
    var telegram = Telegram()

    init() {}

    init(_ r: [String: Any]) {
        let w = r["web"] as? [String: Any] ?? [:]
        web = Web(enabled: w["enabled"] as? Bool ?? false,
                  port: (w["port"] as? NSNumber)?.intValue ?? 2783,
                  publicURL: string(w["public_url"]),
                  webRoot: string(w["web_root"]),
                  telegramHost: string(w["telegram_host"]))
        let t = r["telegram"] as? [String: Any] ?? [:]
        var rules: [TelegramRule] = []
        if let raw = t["rules"], JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw) {
            rules = (try? JSONDecoder().decode([TelegramRule].self, from: data)) ?? []
        }
        telegram = Telegram(enabled: t["enabled"] as? Bool ?? false,
                            botTokenSet: t["bot_token_set"] as? Bool ?? false,
                            allowedUsers: (t["allowed_users"] as? [Any] ?? []).compactMap(string),
                            defaultChatId: string(t["default_chat_id"]),
                            backfillSeconds: (t["backfill_seconds"] as? NSNumber)?.intValue,
                            rules: rules,
                            miniAppURL: string(t["mini_app_url"]))
    }

    /// Rules in the wire shape, for `gateway.config.set`.
    static func rulesJSON(_ rules: [TelegramRule]) -> [Any] {
        guard let data = try? JSONEncoder().encode(rules),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return obj
    }
}

/// `pairing.code.*`.
struct GatewayPairingCode: Equatable {
    var code: String
    var pairURL: String

    init(code: String, pairURL: String) {
        self.code = code
        self.pairURL = pairURL
    }

    init(_ r: [String: Any]) {
        code = string(r["code"]) ?? ""
        pairURL = string(r["pair_url"]) ?? ""
    }

    static let lengths = 8...16

    /// Digits only.
    static func normalize(_ raw: String) -> String {
        String(raw.filter(\.isNumber))
    }

    /// `1234 5678`: groups of four, read off a screen in halves.
    static func grouped(_ raw: String) -> String {
        let digits = Array(normalize(raw))
        return stride(from: 0, to: digits.count, by: 4)
            .map { String(digits[$0..<min($0 + 4, digits.count)]) }
            .joined(separator: " ")
    }
}

/// One `devices.list` row: a browser or phone holding its own token.
struct GatewayDevice: Equatable {
    var id: String
    var label: String
    /// `code`, `telegram` or `legacy`.
    var via: String
    var createdAt: Date?
    var lastSeenAt: Date?
    var connected: Bool

    init?(_ r: [String: Any]) {
        guard let id = string(r["id"]) else { return nil }
        self.id = id
        label = string(r["label"]) ?? ""
        via = string(r["via"]) ?? ""
        createdAt = GatewayTime.date(r["created_at"])
        lastSeenAt = GatewayTime.date(r["last_seen_at"])
        connected = r["connected"] as? Bool ?? false
    }

    init(id: String, label: String, via: String, createdAt: Date?, lastSeenAt: Date?, connected: Bool) {
        self.id = id
        self.label = label
        self.via = via
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.connected = connected
    }
}

/// One `share.list` row.
struct GatewayShareLink: Equatable {
    var id: String
    var paneSessionKey: String
    var label: String
    var recipient: String?
    var createdAt: Date
    var expiresAt: Date?

    init?(_ r: [String: Any]) {
        guard let id = string(r["id"]) else { return nil }
        self.id = id
        paneSessionKey = string(r["pane_session_key"]) ?? ""
        label = string(r["label"]) ?? ""
        recipient = string(r["recipient"])
        createdAt = GatewayTime.date(r["created_at"]) ?? Date()
        expiresAt = GatewayTime.date(r["expires_at"])
    }

    init(id: String, paneSessionKey: String, label: String, recipient: String?, createdAt: Date, expiresAt: Date?) {
        self.id = id
        self.paneSessionKey = paneSessionKey
        self.label = label
        self.recipient = recipient
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// `share.create`.
struct GatewayShareCreated: Equatable {
    var id: String
    var url: String
    var expiresAt: Date?

    init?(_ r: [String: Any]) {
        guard let id = string(r["id"]), let url = string(r["url"]) else { return nil }
        self.id = id
        self.url = url
        expiresAt = GatewayTime.date(r["expires_at"])
    }
}

/// `telegram.validate_token`.
struct GatewayTokenCheck: Equatable {
    var ok: Bool
    var username: String?
    var error: String?

    init(_ r: [String: Any]) {
        ok = r["ok"] as? Bool ?? false
        username = string(r["username"])
        error = string(r["error"])
    }
}

/// `telegram.pair.begin`.
struct GatewayTelegramPairing: Equatable {
    var code: String
    var deepLink: String

    init(_ r: [String: Any]) {
        code = string(r["code"]) ?? ""
        deepLink = string(r["deep_link"]) ?? ""
    }
}

// MARK: - events.subscribe

/// One `events.subscribe` stream on `gateway.sock`, followed on a thread of
/// its own and reconnected while it is wanted. Events (`gateway.status_changed`,
/// `telegram.paired`, `devices.changed`, `share.changed`, `config.changed`)
/// arrive on main as `(type, event)`; `onConnected` says whether the gateway
/// answers.
final class GatewayEventStream {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnected: ((Bool) -> Void)?

    private let lock = NSLock()
    /// Bumped by every `start` and `stop`; a thread runs only while the
    /// generation it was started for is current, so a quick stop-then-start
    /// never leaves two streams delivering the same events.
    private var generation = 0
    private var running = false
    private var fd: Int32 = -1

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        running = true
        generation += 1
        let mine = generation
        let t = Thread { [weak self] in self?.run(mine) }
        t.name = "seahelm-gateway-events"
        t.qualityOfService = .utility
        t.start()
    }

    func stop() {
        lock.lock()
        running = false
        generation += 1
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }

    deinit { stop() }

    private func isCurrent(_ mine: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && generation == mine
    }

    private func run(_ mine: Int) {
        var pause: TimeInterval = 1
        while isCurrent(mine) {
            if let fd = CoreSocketClient.open(path: GatewayClient.path, timeout: 60) {
                lock.lock()
                guard running && generation == mine else { lock.unlock(); close(fd); return }
                self.fd = fd
                lock.unlock()
                follow(fd, mine)
                lock.lock()
                if self.fd == fd { self.fd = -1 }
                lock.unlock()
                close(fd)
                pause = 1
            }
            guard isCurrent(mine) else { return }
            DispatchQueue.main.async { [weak self] in self?.onConnected?(false) }
            Thread.sleep(forTimeInterval: pause)
            pause = min(pause * 2, 10)
        }
    }

    private func follow(_ fd: Int32, _ mine: Int) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "events.subscribe", "params": [:]]
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return }
        data.append(0x0A)
        guard data.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == data.count else { return }
        DispatchQueue.main.async { [weak self] in self?.onConnected?(true) }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while isCurrent(mine) {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }   // receive timeout: idle, not dead
            guard n > 0 else { return }
            pending.append(contentsOf: buffer[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let ev = Self.event(from: obj), let type = ev["type"] as? String else { continue }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(mine) else { return }
                    self.onEvent?(type, ev)
                }
            }
        }
    }

    /// `{method: "event", params: {type, …}}` as the core frames events, or a
    /// bare `{type, …}` line. The subscription's own reply is neither.
    static func event(from obj: [String: Any]) -> [String: Any]? {
        if obj["method"] as? String == "event", let params = obj["params"] as? [String: Any] { return params }
        if obj["type"] is String, obj["id"] == nil { return obj }
        return nil
    }
}
