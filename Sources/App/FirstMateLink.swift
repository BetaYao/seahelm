import Foundation

/// First Mate as the app sees it. First Mate lives in seahelm-core and
/// nowhere else (docs/app-reads-core.md): the core runs its session, rules,
/// gates, cards and audit. The app shows its state, talks to it, stops its
/// turn, shows its conversation, and passes its answers and actions on to the
/// chats that asked.
final class FirstMateLink {
    struct State: Equatable {
        enum Activity: Equatable { case off, starting, idle, thinking, needsYou, paused }
        var activity: Activity = .off
        /// The newest thing First Mate was woken by or did, as the core words it.
        var latest: String = ""
        var latestAt: Date?
        /// While it works: what it is doing right now.
        var doing: String = ""
        var watching: Int = 0
        var queued: Int = 0
        /// Cards of First Mate's waiting on the user.
        var pendingApprovals: Int = 0
    }

    private(set) var state = State() {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?
    /// First Mate finished a turn the chats in `targets` asked for.
    var onReply: ((_ targets: [String], _ text: String) -> Void)?
    /// A line the core wrote to First Mate's audit log since the last look.
    var onAudit: ((AutopilotAudit.Entry) -> Void)?

    /// The core says First Mate is running.
    private(set) var isRunning = false
    private(set) var agent: AgentType = .claudeCode

    /// Chats waiting on First Mate's answer.
    private var replyTargets: [String] = []
    private var timer: Timer?
    private var auditOffset: UInt64 = 0

    func start() {
        guard timer == nil else { return }
        CoreClient.shared.observe { [weak self] in self?.coreEvent($0) }
        auditOffset = (try? FileManager.default.attributesOfItem(atPath: FirstMatePane.auditPath))?[.size] as? UInt64 ?? 0
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    /// First Mate's turn ended (its pane's completion, from the core): its
    /// answer goes to the chats that asked.
    private func coreEvent(_ event: CoreEvent) {
        guard case .raw(let ev) = event,
              ev["pane_session_key"] as? String == FirstMatePane.sessionName,
              ev["is_completion"] as? Bool == true, !replyTargets.isEmpty else { return }
        let answer = (ev["final_message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        onReply?(replyTargets, answer)
        replyTargets = []
    }

    /// The user's own words, now. `replyTo` is a chat (a `CommandSession`
    /// key) that gets First Mate's answer. False when it is not running.
    @discardableResult
    func sendUserMessage(_ text: String, replyTo: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, !trimmed.isEmpty else { return false }
        if let replyTo, !replyTargets.contains(replyTo) { replyTargets.append(replyTo) }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CoreSocketClient.call("autopilot.say", ["text": trimmed])
        }
        return true
    }

    /// Stop First Mate's turn: Esc into its session.
    func interrupt() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CoreSocketClient.call("pane.send_keys", ["pane_id": FirstMatePane.sessionName, "keys": ["escape"]])
        }
    }

    /// First Mate's conversation. Blocking (a socket call): off main.
    static func timeline() -> [MessageEvent] {
        CoreMessages.shared.snapshot(paneId: FirstMatePane.sessionName)
    }

    /// The core's `firstMate.state`, as the web draws it. Blocking: off main.
    static func remoteState() -> [String: Any]? {
        guard case .success(let r) = CoreSocketClient.call("autopilot.state") else { return nil }
        return r
    }

    // MARK: - Following the core

    private func poll() {
        let path = FirstMatePane.auditPath
        let offset = auditOffset
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reply = Self.remoteState()
            let (entries, next) = Self.readAudit(path: path, from: offset)
            DispatchQueue.main.async {
                guard let self else { return }
                self.auditOffset = next
                for entry in entries { self.onAudit?(entry) }
                self.apply(reply)
            }
        }
    }

    private func apply(_ r: [String: Any]?) {
        guard let r else {
            isRunning = false
            state = State()
            return
        }
        isRunning = r["enabled"] as? Bool ?? false
        if let a = r["agent"] as? String, let t = AgentType(rawValue: a) { agent = t }
        var s = State()
        s.activity = Self.activity(r["activity"] as? String)
        s.latest = r["detail"] as? String ?? ""
        s.queued = r["queued"] as? Int ?? 0
        s.pendingApprovals = r["pending"] as? Int ?? 0
        state = s
    }

    static func activity(_ word: String?) -> State.Activity {
        switch word {
        case "starting": return .starting
        case "watching": return .idle
        case "thinking": return .thinking
        case "needs you": return .needsYou
        case "paused": return .paused
        default: return .off
        }
    }

    /// Lines appended to `audit.jsonl` (the core writes it) since `offset`.
    static func readAudit(path: String, from offset: UInt64) -> ([AutopilotAudit.Entry], UInt64) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ([], 0) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = offset > size ? 0 : offset
        guard size > start else { return ([], size) }
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], start) }
        let complete = data[data.startIndex...lastNewline]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = complete.split(separator: 0x0A).compactMap { try? decoder.decode(AutopilotAudit.Entry.self, from: Data($0)) }
        return (entries, start + UInt64(complete.count))
    }
}

extension Notification.Name {
    /// First Mate's state changed; `userInfo` is the core's `autopilot.state`.
    static let firstMateStateChanged = Notification.Name("seahelm.firstMateStateChanged")
}
