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

    let audit = AutopilotAudit(path: FirstMatePane.auditPath)
    private let ledger = AutopilotLedger(path: FirstMatePane.ledgerPath)
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

    init() {
        audit.onAppend = { [weak self] entry in
            DispatchQueue.main.async { self?.noteAudit(entry) }
        }
        if let last = audit.recent(limit: 1).last { state.latest = Self.headline(last) }
    }

    // MARK: - Lifecycle

    func apply(enabled: Bool, paused: Bool, backend: String) {
        self.paused = paused
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
        // The agent is started with its own permission gate (`.claude/settings.json`
        // in its directory), never with the yolo flag: seahelm's policy covers its
        // CLI, Claude's covers the rest of the shell.
        let command = AgentType.claudeCode.bareLaunchCommand(agentYolo: false) ?? "claude"
        DispatchQueue.global(qos: .userInitiated).async {
            if !SessionManager.sessionExists(name: FirstMatePane.sessionName, backend: backend) {
                DispatchQueue.global(qos: .userInitiated).async {
                    SessionManager.createDetachedSession(name: FirstMatePane.sessionName, backend: backend,
                                                         cwd: FirstMatePane.directory, agentCommandLine: command)
                }
                _ = SessionManager.waitUntilSessionExists(name: FirstMatePane.sessionName,
                                                          backend: backend, timeoutSeconds: 5)
            }
            DispatchQueue.main.async { [weak self] in self?.refreshActivity() }
        }
    }

    private func stop() {
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
        send(trimmed, to: id)
        audit.append(.init(at: Date(), kind: .message, text: trimmed))
    }

    private func send(_ text: String, to id: String) {
        awaitingTurn = true
        AgentRegistry.shared.sendCommand(to: id, command: text, submitWithAttachments: true,
                                         agentType: .claudeCode)
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
        let loaded = AutomationConfig.load(repoPath: repoPath)
        configs[repoPath] = (loaded.config, loaded.error, mtime)
        return loaded
    }
}
