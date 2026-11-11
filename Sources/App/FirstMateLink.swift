import Foundation

/// First Mate as the app sees it. First Mate lives in seahelm-core and
/// nowhere else (docs/app-reads-core.md): the core runs its session, rules,
/// gates, cards and audit. The app shows its state, talks to it, stops its
/// turn and shows its conversation. Its answers to chats and its audit lines
/// are seahelm-gateway's to deliver.
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
    /// What config.json says about First Mate (`autopilot_enabled`,
    /// `autopilot_agent`), as the core read it. seahelm-web can change both
    /// (`autopilot.configure`); the app keeps its own copy of the config and
    /// writes all of it on any save, so it follows the core's reading here.
    var onConfigured: ((_ enabled: Bool, _ agent: String) -> Void)?

    /// The core says First Mate is running.
    private(set) var isRunning = false
    private(set) var agent: AgentType = .claudeCode
    /// The language the core writes First Mate's lines in (`autopilot.state`
    /// `language`): `first_mate_language`, or, unset, the user's own. Nil
    /// while the core does not answer.
    private(set) var language: String?

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    /// The user's own words, now. False when it is not running.
    @discardableResult
    func sendUserMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, !trimmed.isEmpty else { return false }
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reply = Self.remoteState()
            DispatchQueue.main.async { self?.apply(reply) }
        }
    }

    private func apply(_ r: [String: Any]?) {
        guard let r else {
            language = nil
            isRunning = false
            state = State()
            return
        }
        isRunning = r["enabled"] as? Bool ?? false
        if let a = r["agent"] as? String, let t = AgentType(rawValue: a) { agent = t }
        language = r["language"] as? String
        if let c = r["configured"] as? [String: Any], let on = c["enabled"] as? Bool, let a = c["agent"] as? String {
            onConfigured?(on, a)
        }
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
}
