import AppKit

/// Runs First Mate: keeps its session alive, turns PR changes into events,
/// matches them to each repo's rules, and hands the prompts to First Mate when
/// it is free. Main thread. See docs/first-mate-autopilot.md.
final class AutopilotCoordinator {
    /// What the dock and First Mate's view draw.
    struct State: Equatable {
        enum Activity: Equatable { case off, starting, idle, thinking, needsYou, paused }
        var activity: Activity = .off
        /// The newest audit line worth showing ("→ told #3 to fix CI").
        var latest: String = ""
        var queued: Int = 0
        /// Approvals waiting on the user (phase 1c).
        var pendingApprovals: Int = 0
    }

    private(set) var state = State() {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?

    let audit: AutopilotAudit
    private let ledger: AutopilotLedger
    private var detector = PREventDetector()
    private(set) var station: Station?
    private var queue: [AutopilotDispatch] = []
    /// A prompt went in and First Mate has not been seen working on it yet: the
    /// status flips to running a moment after the text lands, and delivering
    /// again in that gap would pile two turns into one.
    private var awaitingTurn = false
    private var enabled = false
    private var paused = false
    private var configs: [String: (config: AutomationConfig?, error: String?, mtime: Date?)] = [:]

    var stationId: String? { station?.id }

    // MARK: Policy (phase 1c)

    /// A gated call waiting on the user.
    struct Approval {
        let id: String
        let action: AutopilotAction
        let method: String
        let params: [String: Any]
        let summary: String
    }
    private var approvals: [String: Approval] = [:]
    /// Raise / retire the card for an approval (owner: the pending-orders queue).
    var onRequestApproval: ((_ id: String, _ summary: String) -> Void)?
    var onApprovalClosed: ((_ id: String) -> Void)?
    /// Run a control call as the user, past the policy. Called off the main thread.
    var execute: ((_ method: String, _ params: [String: Any]) -> ControlResult)?
    /// The higher of Claude's and Codex's 5h usage, from the usage store.
    var usagePercent: Int?
    /// The rules of the events First Mate is working on, and whether the user
    /// has spoken since it last finished a turn. Together they pick the level.
    private var activeRules: [(rule: AutomationRule, config: AutomationConfig)] = []
    private var userSpoke = false
    /// Worktrees First Mate started agents in, for `max_concurrent_agents`.
    private(set) var startedWorktrees: Set<String> = []
    /// Which of those still exist; set by the owner from the fleet.
    var liveWorktrees: () -> Set<String> = { [] }

    init(auditPath: String = FirstMatePane.auditPath, ledgerPath: String = FirstMatePane.ledgerPath) {
        audit = AutopilotAudit(path: auditPath)
        ledger = AutopilotLedger(path: ledgerPath)
        audit.onAppend = { [weak self] entry in
            DispatchQueue.main.async { self?.noteAudit(entry) }
        }
        if let last = audit.recent(limit: 1).last { state.latest = Self.headline(last) }
    }

    // MARK: - Lifecycle

    /// Tests: decide gates as a running First Mate would, without a session.
    func activateForTesting(paused: Bool = false) {
        enabled = true
        self.paused = paused
    }

    /// Tests: First Mate is working on these rules.
    func setActiveRulesForTesting(_ rules: [(AutomationRule, AutomationConfig)], userSpoke: Bool = false) {
        activeRules = rules.map { (rule: $0.0, config: $0.1) }
        self.userSpoke = userSpoke
    }

    /// The user's defaults per action (Settings ▸ First Mate).
    private(set) var defaults: AutonomyMap = AutomationConfig.defaultAutonomy

    func apply(enabled: Bool, paused: Bool, backend: String,
               defaults: AutonomyMap = AutomationConfig.defaultAutonomy) {
        self.paused = paused
        if defaults != self.defaults {
            self.defaults = defaults
            configs.removeAll()
        }
        if enabled, !self.enabled {
            self.enabled = true
            start(backend: backend)
        } else if !enabled, self.enabled {
            self.enabled = false
            stop()
        }
        refreshActivity()
        if !paused { deliverIfReady() }
    }

    private func start(backend: String) {
        state.activity = .starting
        FirstMatePane.provision()
        let station = Station()
        station.paneSessionKey = FirstMatePane.sessionName
        station.backend = backend
        self.station = station
        StationRegistry.shared.register(station)
        AgentRegistry.shared.register(station: station, worktreePath: FirstMatePane.directory, branch: "",
                                      project: FirstMatePane.project, startedAt: Date(),
                                      paneSessionKey: FirstMatePane.sessionName, backend: backend)
        self.backend = backend
        ensureSession()
    }

    private var backend = "zmx"
    /// When this run last launched the session. Its agent waits for a client to
    /// attach before it starts (up to ~10s), so a session this young is not
    /// judged by whether the agent is there yet.
    private var launchedAt: Date?

    /// Make sure the session exists and is hosting First Mate's agent, then call
    /// back on main. A session can be there without its agent — an exit, or a
    /// plain shell re-created by an attach after the session was lost — and a
    /// bare shell is not First Mate: it is replaced. So is a session launched by
    /// an older seahelm (before the permission flag, say).
    func ensureSession(then done: (() -> Void)? = nil) {
        let backend = self.backend
        // The agent is started with its own permission gate (`.claude/settings.json`
        // in its directory), never with the yolo flag: seahelm's policy covers its
        // CLI, Claude's covers the rest of the shell.
        let command = FirstMatePane.launchCommand
        let young = launchedAt.map { Date().timeIntervalSince($0) < 60 } ?? false
        DispatchQueue.global(qos: .userInitiated).async {
            let name = FirstMatePane.sessionName
            var exists = SessionManager.sessionExists(name: name, backend: backend)
            if exists, !FirstMatePane.sessionIsCurrent() || (!young && !Self.agentIsRunning()) {
                SessionManager.killSession(name, backend: backend)
                // The kill lands asynchronously, and createDetachedSession
                // declines a name that still lists — leaving no session at all.
                let deadline = Date().addingTimeInterval(5)
                while SessionManager.sessionExists(name: name, backend: backend), Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                exists = false
            }
            if !exists {
                FirstMatePane.markSessionCurrent()
                DispatchQueue.main.async { [weak self] in self?.launchedAt = Date() }
                DispatchQueue.global(qos: .userInitiated).async {
                    SessionManager.createDetachedSession(name: name, backend: backend,
                                                         cwd: FirstMatePane.directory, agentCommandLine: command)
                }
                _ = SessionManager.waitUntilSessionExists(name: name, backend: backend, timeoutSeconds: 5)
            }
            DispatchQueue.main.async { [weak self] in
                self?.refreshActivity()
                done?()
            }
        }
    }

    /// Whether an AI agent is running in the session's process tree. Not the
    /// `zmx run` client that launched it: that client is reaped as an orphan
    /// whenever the app restarts, while the agent lives on in the daemon.
    private static func agentIsRunning() -> Bool {
        AgentType.fromManifestId(ProcessProbe.probeSession(paneSessionKey: FirstMatePane.sessionName).agentId)
            .isAIAgent
    }

    private func stop() {
        for id in approvals.keys { onApprovalClosed?(id) }
        approvals.removeAll()
        state.pendingApprovals = 0
        activeRules = []
        if let station {
            AgentRegistry.shared.unregister(terminalID: station.id)
            StationRegistry.shared.unregister(station.id)
        }
        station = nil
        queue.removeAll()
        awaitingTurn = false
    }

    // MARK: - Events

    /// The fleet's PRs as of now. Called whenever `WorktreePRStore` learns something.
    func observe(_ observations: [PRObservation], now: Date = Date()) {
        let events = detector.observe(observations, alreadyMerged: ledger.hasHandledMerge)
        for event in events { handle(event, now: now) }
    }

    private func handle(_ event: AutopilotEvent, now: Date) {
        if event.trigger == .prMerged, let pr = event.pr {
            ledger.markMergeHandled(AutopilotLedger.mergedKey(repoPath: event.repoPath, pr: pr.number))
        }
        guard enabled else { return }
        let loaded = config(forRepo: event.repoPath)
        guard let config = loaded.config else {
            audit.append(.init(at: now, kind: .skipped, worktreePath: event.worktreePath, pr: event.pr?.number,
                               text: "\(event.trigger.eventName) ignored — \(loaded.error ?? "rules unreadable")"))
            return
        }
        let day = AutopilotEngine.day(now)
        let dispatches = AutopilotEngine.dispatches(for: event, config: config, ledger: ledger, day: day)
        guard !dispatches.isEmpty else { return }
        for d in dispatches {
            if let pr = event.pr {
                ledger.recordAttempt(rule: d.rule.name, repoPath: event.repoPath, pr: pr.number, day: day)
            }
            let quiet = config.settings.quietHours?.contains(now) == true
            audit.append(.init(at: now, kind: .event, rule: d.rule.name, worktreePath: event.worktreePath,
                               pr: event.pr?.number,
                               text: "\(event.trigger.eventName) · \(Self.shortName(event.worktreePath))"
                                   + (event.pr.map { " · PR #\($0.number)" } ?? "")
                                   + (quiet ? " (quiet hours — queued)" : "")))
            queue.append(d)
        }
        state.queued = queue.count
        deliverIfReady(now: now)
    }

    // MARK: - Delivery

    /// First Mate's outcomes, from `AgentRegistry.onOutcome`.
    func firstMateOutcome(_ outcome: IngestOutcome) {
        if outcome.newStatus == .running { awaitingTurn = false }
        // A finished turn closes the events it was about.
        if outcome.newStatus == .idle, outcome.oldStatus == .running, !awaitingTurn {
            activeRules = []
            userSpoke = false
        }
        refreshActivity()
        deliverIfReady()
    }

    /// Hand the queue to First Mate if it is at rest and nothing holds it back.
    func deliverIfReady(now: Date = Date()) {
        guard enabled, !paused, !awaitingTurn, !queue.isEmpty, let id = station?.id,
              AgentRegistry.shared.pane(for: id)?.status == .idle else { return }
        let ready = queue.filter { d in
            let config = config(forRepo: d.event.repoPath).config
            return config?.settings.quietHours?.contains(now) != true
        }
        guard !ready.isEmpty else { return }
        queue.removeAll { d in ready.contains(d) }
        state.queued = queue.count
        let text = ready.map(\.prompt).joined(separator: "\n\n---\n\n")
        activeRules += ready.compactMap { d in
            config(forRepo: d.event.repoPath).config.map { (d.rule, $0) }
        }
        send(text, to: id)
        for d in ready {
            audit.append(.init(at: now, kind: .delivered, rule: d.rule.name, worktreePath: d.event.worktreePath,
                               pr: d.event.pr?.number, text: "handed to First Mate"))
        }
    }

    /// The user's own words. Not queued: they go in now, whatever First Mate is
    /// doing — the agent's composer takes a message mid-turn.
    func sendUserMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = station?.id else { return }
        userSpoke = true
        send(trimmed, to: id)
        audit.append(.init(at: Date(), kind: .message, text: trimmed))
    }

    private func send(_ text: String, to id: String) {
        awaitingTurn = true
        AgentRegistry.shared.sendCommand(to: id, command: text, submitWithAttachments: true,
                                         agentType: .claudeCode)
    }

    // MARK: - Gate

    /// The level an action runs at now: the strictest of the rules First Mate
    /// is working on, and the defaults while the user is talking to it (or when
    /// it is acting on nothing in particular). Talking cannot loosen a rule.
    func level(for action: AutopilotAction) -> AutonomyLevel {
        var levels = activeRules.map { $0.config.autonomy(for: action, rule: $0.rule) }
        if userSpoke || levels.isEmpty {
            levels.append(defaults[action] ?? .ask)
        }
        return levels.max(by: { Self.strictness($0) < Self.strictness($1) }) ?? .ask
    }

    private static func strictness(_ level: AutonomyLevel) -> Int {
        switch level { case .auto: return 0; case .ask: return 1; case .deny: return 2 }
    }

    /// Decide one gated call from First Mate. Main thread.
    func gate(action: AutopilotAction, method: String, params: [String: Any], now: Date = Date()) -> AutopilotGate {
        guard enabled else { return .deny("First Mate is off") }
        guard !paused else { return .deny("First Mate is paused") }
        let summary = AutopilotPolicy.describe(method: method, params: params)
        if action == .startAgent, let refusal = budgetRefusal(params: params) {
            audit.append(.init(at: now, kind: .denied, action: action.rawValue, text: "\(summary) — \(refusal)"))
            return .deny(refusal)
        }
        switch level(for: action) {
        case .auto:
            audit.append(.init(at: now, kind: .action, action: action.rawValue, level: "auto", text: summary))
            return .allow
        case .deny:
            audit.append(.init(at: now, kind: .denied, action: action.rawValue, level: "deny", text: summary))
            return .deny("\(action.rawValue) is set to deny")
        case .ask:
            let id = "autopilot-" + UUID().uuidString.prefix(8)
            approvals[id] = Approval(id: id, action: action, method: method, params: params, summary: summary)
            state.pendingApprovals = approvals.count
            audit.append(.init(at: now, kind: .approval, action: action.rawValue, level: "ask", text: summary))
            onRequestApproval?(id, summary)
            return .queued(id)
        }
    }

    /// Why a new agent may not start now, or nil when it may.
    private func budgetRefusal(params: [String: Any]) -> String? {
        let repo = params["repo_path"] as? String ?? ""
        let settings = config(forRepo: repo).config?.settings ?? AutomationSettings()
        if let cap = settings.maxConcurrentAgents {
            let live = startedWorktrees.intersection(liveWorktrees()).count
            if live >= cap { return "max_concurrent_agents (\(cap)) reached" }
        }
        if let limit = settings.pauseAboveUsage, let used = usagePercent, Double(used) >= limit {
            return "usage at \(used)% is above pause_above_usage (\(Int(limit))%)"
        }
        return nil
    }

    /// A gated call went through (auto, or approved): remember what it made.
    func didRun(method: String, result: ControlResult) {
        if method == "worktree.create", case .ok(let r) = result, let path = r["worktree_path"] as? String {
            startedWorktrees.insert(path)
        }
    }

    /// The user answered an approval card.
    func resolveApproval(_ id: String, approved: Bool) {
        guard let approval = approvals.removeValue(forKey: id) else { return }
        state.pendingApprovals = approvals.count
        onApprovalClosed?(id)
        guard approved else {
            audit.append(.init(at: Date(), kind: .denied, action: approval.action.rawValue,
                               text: "rejected: \(approval.summary)"))
            tell("[seahelm] The user rejected: \(approval.summary)")
            return
        }
        let execute = self.execute
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = execute?(approval.method, approval.params) ?? .error(code: 0, message: "unavailable")
            DispatchQueue.main.async {
                guard let self else { return }
                self.didRun(method: approval.method, result: result)
                let outcome: String
                switch result {
                case .ok(let r): outcome = Self.compact(r)
                case .error(_, let message): outcome = "failed: \(message)"
                }
                self.audit.append(.init(at: Date(), kind: .action, action: approval.action.rawValue,
                                        level: "approved", text: "\(approval.summary) — \(outcome)"))
                self.tell("[seahelm] The user approved: \(approval.summary)\nResult: \(outcome)")
            }
        }
    }

    var pendingApprovalIds: [String] { Array(approvals.keys) }
    static let approveLabel = "Approve"
    static let rejectLabel = "Reject"

    /// A note from seahelm itself. Sent like the user's words: First Mate must
    /// hear the answer to what it asked, whatever it is doing.
    private func tell(_ text: String) {
        guard let id = station?.id else { return }
        send(text, to: id)
    }

    private static func compact(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "ok" }
        return text
    }

    // MARK: - State

    private func refreshActivity() {
        guard enabled, let id = station?.id else { state.activity = .off; return }
        if paused { state.activity = .paused; return }
        switch AgentRegistry.shared.pane(for: id)?.status {
        case .running?: state.activity = .thinking
        case .waiting?, .error?: state.activity = .needsYou
        case .idle?: state.activity = .idle
        default: state.activity = .starting
        }
    }

    private func noteAudit(_ entry: AutopilotAudit.Entry) {
        guard entry.kind != .delivered else { return }
        state.latest = Self.headline(entry)
    }

    static func headline(_ entry: AutopilotAudit.Entry) -> String {
        switch entry.kind {
        case .event: return entry.text
        case .message: return "you: " + entry.text
        case .action: return "→ " + entry.text
        case .approval: return "? " + entry.text
        case .denied: return "✕ " + entry.text
        default: return entry.text
        }
    }

    private static func shortName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    /// A repo's rules, re-read when the file changes.
    private func config(forRepo repoPath: String) -> (config: AutomationConfig?, error: String?) {
        let path = (repoPath as NSString).appendingPathComponent(AutomationConfig.relativePath)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let cached = configs[repoPath], cached.mtime == mtime { return (cached.config, cached.error) }
        var loaded = AutomationConfig.load(repoPath: repoPath)
        loaded.config?.defaults = defaults
        configs[repoPath] = (loaded.config, loaded.error, mtime)
        return loaded
    }
}
