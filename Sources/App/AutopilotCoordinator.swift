import AppKit

/// Runs First Mate: keeps its session alive, turns PR changes into events,
/// matches them to each repo's rules, and hands the prompts to First Mate when
/// it is free. Main thread.
final class AutopilotCoordinator {
    /// What the dock and First Mate's view draw.
    struct State: Equatable {
        enum Activity: Equatable { case off, starting, idle, thinking, needsYou, paused }
        var activity: Activity = .off
        /// The newest thing First Mate was woken by or did ("→ told #3 to fix
        /// CI"), and when. Not the user's own messages: echoing those back
        /// tells them nothing.
        var latest: String = ""
        var latestAt: Date?
        /// While it works: what it is doing right now (its pane's last activity).
        var doing: String = ""
        /// Projects whose rules it watches.
        var watching: Int = 0
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
    /// A recommendation waiting on the user: its options, each an action.
    struct Proposal {
        let id: String
        let summary: String
        let options: [(label: String, action: AutopilotAction, method: String, params: [String: Any])]
    }
    private var proposals: [String: Proposal] = [:]
    static let dismissLabel = "Not now"
    /// Raise the card for a proposal (owner: the pending-orders queue).
    var onRequestProposal: ((_ id: String, _ summary: String, _ labels: [String]) -> Void)?
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
    /// The projects whose rules are consulted for schedules.
    var repoPaths: () -> [String] = { [] }
    private var scheduleTimer: Timer?
    private var lastScheduleMinute: Int?

    init(auditPath: String = FirstMatePane.auditPath, ledgerPath: String = FirstMatePane.ledgerPath) {
        audit = AutopilotAudit(path: auditPath)
        ledger = AutopilotLedger(path: ledgerPath)
        audit.onAppend = { [weak self] entry in
            DispatchQueue.main.async { self?.noteAudit(entry) }
        }
        if let last = audit.recent(limit: 50).last(where: { Self.isNotable($0) }) {
            state.latest = Self.headline(last)
            state.latestAt = last.at
        }
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

    /// Which agent First Mate is (Settings ▸ First Mate).
    private(set) var agent: AgentType = .claudeCode

    func apply(enabled: Bool, paused: Bool, backend: String, agent: AgentType = .claudeCode,
               defaults: AutonomyMap = AutomationConfig.defaultAutonomy, ownerCore: Bool = false) {
        self.paused = paused
        // seahelm-core owns First Mate: this app only shows it. The local one
        // stops (its session is left; the core replaces it, its stamp being
        // another's) and the core's is followed instead.
        if enabled && ownerCore {
            if self.enabled {
                self.enabled = false
                stop()
            }
            self.agent = agent
            if !remote { startRemote(backend: backend) }
            refreshActivity()
            return
        }
        if remote { stopRemote() }
        if defaults != self.defaults {
            self.defaults = defaults
            configs.removeAll()
        }
        let switchedAgent = agent != self.agent
        self.agent = agent
        if enabled, self.enabled, switchedAgent {
            // A session stamped with the other agent is replaced by ensureSession.
            ensureSession()
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
        scheduleTimer?.invalidate()
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.checkSchedules()
        }
    }

    /// Fire the schedule rules whose cron matches this minute, once per minute.
    /// Missed minutes (the app closed, the Mac asleep) are not caught up: a
    /// morning triage at noon is not what anyone asked for.
    func checkSchedules(now: Date = Date()) {
        let minute = Int(now.timeIntervalSince1970 / 60)
        guard minute != lastScheduleMinute else { return }
        lastScheduleMinute = minute
        for repo in repoPaths() {
            guard let config = config(forRepo: repo).config else { continue }
            var crons = Set<String>()
            for rule in config.rules where rule.enabled {
                if case .schedule(let cron) = rule.trigger, CronSchedule(cron)?.matches(now) == true {
                    crons.insert(cron)
                }
            }
            for cron in crons.sorted() {
                handle(AutopilotEvent(trigger: .schedule(cron), repoPath: repo, worktreePath: repo,
                                      branch: "", pr: nil), now: now)
            }
        }
    }

    private var backend = "seahelmd"
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
        if remote {
            // The core's session: never created or replaced from here. Wait
            // for it to exist — attaching to a missing one would start an
            // empty shell under its name.
            let backend = self.backend
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = SessionManager.waitUntilSessionExists(name: FirstMatePane.sessionName, backend: backend, timeoutSeconds: 5)
                DispatchQueue.main.async { [weak self] in
                    self?.refreshActivity()
                    if ok { done?() }
                }
            }
            return
        }
        let backend = self.backend
        // The agent is started with its own permission gate (`.claude/settings.json`
        // in its directory), never with the yolo flag: seahelm's policy covers its
        // CLI, Claude's covers the rest of the shell.
        let agent = FirstMatePane.agents.contains(self.agent) ? self.agent : .claudeCode
        let command = FirstMatePane.launchCommand(for: agent)
        let young = launchedAt.map { Date().timeIntervalSince($0) < 60 } ?? false
        DispatchQueue.global(qos: .userInitiated).async {
            let name = FirstMatePane.sessionName
            var exists = SessionManager.sessionExists(name: name, backend: backend)
            if exists, !FirstMatePane.sessionIsCurrent(agent: agent) || (!young && !Self.agentIsRunning()) {
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
                FirstMatePane.markSessionCurrent(agent: agent)
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
    /// `seahelmd run` client that launched it: that client is reaped as an orphan
    /// whenever the app restarts, while the agent lives on in the daemon.
    private static func agentIsRunning() -> Bool {
        AgentType.fromManifestId(ProcessProbe.probeSession(paneSessionKey: FirstMatePane.sessionName).agentId)
            .isAIAgent
    }

    private func stop() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        for id in Array(approvals.keys) + Array(proposals.keys) { onApprovalClosed?(id) }
        approvals.removeAll()
        proposals.removeAll()
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
        // A merge seen while First Mate is off stays unhandled: turned on later,
        // the worktree it left behind is still something to clean up.
        guard enabled else { return }
        if event.trigger == .prMerged, let pr = event.pr {
            ledger.markMergeHandled(AutopilotLedger.mergedKey(repoPath: event.repoPath, pr: pr.number))
        }
        // A worktree event carries what is actually in the worktree, measured
        // here (off main: git) rather than left to First Mate to describe.
        if event.facts == nil, event.trigger == .prMerged || event.trigger == .ciFailed {
            let path = event.worktreePath
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var facts = WorktreeFacts.probe(worktreePath: path)
                facts.busyPanes = WorktreeFacts.busyPanes(worktreePath: path)
                DispatchQueue.main.async {
                    var measured = event
                    measured.facts = facts
                    self?.handle(measured, now: now)
                }
            }
            return
        }
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
                                   + (event.facts.map { " — \($0.summary)" } ?? "")
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
        // A finished turn closes the events it was about, and answers whoever asked.
        if outcome.newStatus == .idle, outcome.oldStatus == .running, !awaitingTurn {
            activeRules = []
            userSpoke = false
            let answer = outcome.info.lastAssistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !replyTargets.isEmpty, !answer.isEmpty {
                onReply?(replyTargets, answer)
                replyTargets = []
            }
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
    /// doing — the agent's composer takes a message mid-turn. `replyTo` is a
    /// chat (a `CommandSession` key) that gets First Mate's answer when its
    /// turn ends. False when First Mate is not running.
    @discardableResult
    func sendUserMessage(_ text: String, replyTo: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if remote {
            guard remoteRunning, !trimmed.isEmpty else { return false }
            if let replyTo, !replyTargets.contains(replyTo) { replyTargets.append(replyTo) }
            DispatchQueue.global(qos: .userInitiated).async {
                _ = CoreSocketClient.call("autopilot.say", ["text": trimmed])
            }
            return true
        }
        guard enabled, !trimmed.isEmpty, let id = station?.id else { return false }
        userSpoke = true
        if let replyTo, !replyTargets.contains(replyTo) { replyTargets.append(replyTo) }
        send(trimmed, to: id)
        audit.append(.init(at: Date(), kind: .message, text: trimmed))
        return true
    }

    /// Chats waiting on First Mate's answer, and where it is sent.
    private var replyTargets: [String] = []
    var onReply: ((_ targets: [String], _ text: String) -> Void)?
    var isRunning: Bool { (enabled || (remote && remoteRunning)) && station != nil }

    private func send(_ text: String, to id: String) {
        awaitingTurn = true
        PaneInput.shared.sendCommand(to: id, command: text, submitWithAttachments: true,
                                         agentType: agent)
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
            state.pendingApprovals = approvals.count + proposals.count
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
        if remote {
            answerRemote(id, option: approved ? Self.approveLabel : Self.rejectLabel)
            return
        }
        guard let approval = approvals.removeValue(forKey: id) else { return }
        state.pendingApprovals = approvals.count + proposals.count
        onApprovalClosed?(id)
        guard approved else {
            audit.append(.init(at: Date(), kind: .denied, action: approval.action.rawValue,
                               text: "rejected: \(approval.summary)"))
            tell("[seahelm] The user rejected: \(approval.summary)")
            return
        }
        let execute = self.execute
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = execute?(approval.method, Self.asUser(approval.params)) ?? .error(code: 0, message: "unavailable")
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

    /// The call as the user's, for running once they have said yes. The params
    /// First Mate sent still name it in `_meta.caller`, and the router gates on
    /// that alone: left in, an approved call was gated again — a fresh card went
    /// up, nothing ran, and the `{"queued": …}` answer read as "done".
    static func asUser(_ params: [String: Any]) -> [String: Any] {
        var params = params
        params.removeValue(forKey: "_meta")
        return params
    }

    // MARK: - Proposals

    /// `seahelm propose`: a card whose options are actions. Each option must be
    /// one First Mate could ask for (`AutopilotPolicy` gated) and not set to
    /// deny; picking it is the user's approval of exactly that action.
    func propose(summary: String, options raw: [[String: Any]], now: Date = Date()) -> ControlResult {
        guard enabled else { return .error(code: ControlError.autopilotRefused, message: "First Mate is off") }
        var options: [(label: String, action: AutopilotAction, method: String, params: [String: Any])] = []
        for (i, option) in raw.enumerated() {
            guard let label = (option["label"] as? String)?.trimmingCharacters(in: .whitespaces), !label.isEmpty,
                  let method = option["action"] as? String else {
                return .error(code: ControlError.invalidParams, message: "option \(i + 1) needs a label and an action")
            }
            guard case .gated(let action) = AutopilotPolicy.classify(method: method) else {
                return .error(code: ControlError.autopilotRefused, message: "option \(i + 1): \(method) cannot be proposed")
            }
            if level(for: action) == .deny {
                return .error(code: ControlError.autopilotRefused, message: "option \(i + 1): \(action.rawValue) is set to deny")
            }
            options.append((label, action, method, option["params"] as? [String: Any] ?? [:]))
        }
        guard !options.isEmpty, options.count <= 5 else {
            return .error(code: ControlError.invalidParams, message: "between one and five options")
        }
        let id = "proposal-" + UUID().uuidString.prefix(8)
        proposals[id] = Proposal(id: id, summary: summary, options: options)
        state.pendingApprovals = approvals.count + proposals.count
        audit.append(.init(at: now, kind: .approval, text: "proposed: \(summary)"))
        onRequestProposal?(id, summary, options.map(\.label) + [Self.dismissLabel])
        return .ok(["queued": "proposal", "card": id,
                    "message": "Shown to the user; you will be told what they picked."])
    }

    /// The user picked an option on a proposal card (or dismissed it).
    func resolveProposal(_ id: String, picked label: String) {
        if remote {
            answerRemote(id, option: label)
            return
        }
        guard let proposal = proposals.removeValue(forKey: id) else { return }
        state.pendingApprovals = approvals.count + proposals.count
        onApprovalClosed?(id)
        guard let option = proposal.options.first(where: { $0.label == label }) else {
            audit.append(.init(at: Date(), kind: .denied, text: "not now: \(proposal.summary)"))
            tell("[seahelm] The user passed on your proposal: \(proposal.summary)")
            return
        }
        // The level may have changed since the card went up.
        if level(for: option.action) == .deny {
            audit.append(.init(at: Date(), kind: .denied, action: option.action.rawValue,
                               text: "\(option.label) — \(option.action.rawValue) is set to deny"))
            tell("[seahelm] The user picked \"\(option.label)\" but \(option.action.rawValue) is set to deny; nothing ran.")
            return
        }
        let execute = self.execute
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = execute?(option.method, Self.asUser(option.params)) ?? .error(code: 0, message: "unavailable")
            DispatchQueue.main.async {
                guard let self else { return }
                self.didRun(method: option.method, result: result)
                let outcome: String
                switch result {
                case .ok(let r): outcome = Self.compact(r)
                case .error(_, let message): outcome = "failed: \(message)"
                }
                self.audit.append(.init(at: Date(), kind: .action, action: option.action.rawValue, level: "picked",
                                        text: "\(option.label) — \(outcome)"))
                self.tell("[seahelm] The user picked \"\(option.label)\".\nResult: \(outcome)")
            }
        }
    }
    static let approveLabel = "Approve"
    static let rejectLabel = "Reject"

    /// A note from seahelm itself. Sent like the user's words: First Mate must
    /// hear the answer to what it asked, whatever it is doing.
    private func tell(_ text: String) {
        guard let id = station?.id else { return }
        send(text, to: id)
    }

    /// A call's result in words, for the audit line, the dock and the phone —
    /// not the JSON the control socket answered with.
    static func compact(_ dict: [String: Any]) -> String {
        let name = (dict["worktree_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        if dict["deleted"] as? Bool == true { return "deleted \(name ?? "the worktree")" }
        if dict["deleting"] as? Bool == true { return "deleting \(name ?? "the worktree")" }
        if dict["pane_session_key"] != nil, let name { return "started in \(name)" }
        if dict["sent"] as? Bool == true || dict["ok"] as? Bool == true { return "sent" }
        return "done"
    }

    // MARK: - State

    private func refreshActivity() {
        guard enabled || (remote && remoteRunning), let id = station?.id else { state.activity = .off; return }
        state.watching = repoPaths().count
        if paused { state.activity = .paused; return }
        let pane = AgentRegistry.shared.pane(for: id)
        state.doing = pane?.status == .running ? (pane?.lastMessage ?? "") : ""
        switch pane?.status {
        case .running?: state.activity = .thinking
        case .waiting?, .error?: state.activity = .needsYou
        case .idle?: state.activity = .idle
        default: state.activity = .starting
        }
    }

    private func noteAudit(_ entry: AutopilotAudit.Entry) {
        guard Self.isNotable(entry) else { return }
        state.latest = Self.headline(entry)
        state.latestAt = entry.at
    }

    /// What the dock reports as "the last thing that happened".
    static func isNotable(_ entry: AutopilotAudit.Entry) -> Bool {
        switch entry.kind {
        case .event, .action, .approval, .denied: return true
        case .delivered, .queued, .skipped, .message: return false
        }
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

    // MARK: - Following the core's First Mate

    /// seahelm-core runs First Mate (`autopilot_owner: "core"`); this app
    /// shows its state and cards and answers through it.
    private(set) var remote = false
    /// The core says First Mate is running.
    private var remoteRunning = false
    private var remoteTimer: Timer?
    /// The core's First Mate cards on offer here, by approval/proposal id.
    private var remoteCards: Set<String> = []
    /// How far into `audit.jsonl` this app has read (the core writes it).
    private var auditOffset: UInt64 = 0

    private func startRemote(backend: String) {
        remote = true
        self.backend = backend
        state.activity = .starting
        // A Station on the core's session, so First Mate's view can show its
        // terminal and the status publisher tracks it.
        let station = Station()
        station.paneSessionKey = FirstMatePane.sessionName
        station.backend = backend
        self.station = station
        StationRegistry.shared.register(station)
        AgentRegistry.shared.register(station: station, worktreePath: FirstMatePane.directory, branch: "",
                                      project: FirstMatePane.project, startedAt: Date(),
                                      paneSessionKey: FirstMatePane.sessionName, backend: backend)
        auditOffset = (try? FileManager.default.attributesOfItem(atPath: FirstMatePane.auditPath))?[.size] as? UInt64 ?? 0
        remoteTimer?.invalidate()
        remoteTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollRemote() }
        pollRemote()
    }

    private func stopRemote() {
        remoteTimer?.invalidate()
        remoteTimer = nil
        for id in remoteCards { onApprovalClosed?(id) }
        remoteCards = []
        state.pendingApprovals = 0
        if let station {
            AgentRegistry.shared.unregister(terminalID: station.id)
            StationRegistry.shared.unregister(station.id)
        }
        station = nil
        remote = false
        remoteRunning = false
        replyTargets = []
    }

    /// The core's First Mate as of now, off main; then cards and the audit
    /// lines it wrote since the last look, on main.
    private func pollRemote() {
        let auditPath = FirstMatePane.auditPath
        let offset = auditOffset
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reply = CoreSocketClient.call("autopilot.state")
            let (entries, next) = Self.readAudit(path: auditPath, from: offset)
            DispatchQueue.main.async {
                guard let self, self.remote else { return }
                self.auditOffset = next
                // As if appended here: the dock's headline and the phone's
                // action lines hang off `onAppend`.
                for entry in entries { self.audit.onAppend?(entry) }
                guard case .success(let state) = reply else {
                    self.remoteRunning = false
                    self.refreshActivity()
                    return
                }
                self.applyRemote(state)
            }
        }
    }

    /// Mirror the core's First Mate cards into this app's queue (island,
    /// Telegram, web all read it), keyed by their approval/proposal id.
    func applyRemote(_ remoteState: [String: Any]) {
        remoteRunning = remoteState["enabled"] as? Bool ?? false
        let cards = remoteState["cards"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        for card in cards {
            guard let id = card["card"] as? String, !id.isEmpty else { continue }
            seen.insert(id)
            guard !remoteCards.contains(id) else { continue }
            remoteCards.insert(id)
            let message = card["message"] as? String ?? ""
            let options = card["options"] as? [String] ?? []
            if card["kind"] as? String == "proposal" {
                onRequestProposal?(id, Self.stripping("First Mate suggests: ", from: message), options)
            } else {
                onRequestApproval?(id, Self.stripping("First Mate asks: ", from: message))
            }
        }
        for id in remoteCards.subtracting(seen) { onApprovalClosed?(id) }
        remoteCards = seen
        state.pendingApprovals = seen.count
        refreshActivity()
    }

    private func answerRemote(_ id: String, option: String) {
        remoteCards.remove(id)
        state.pendingApprovals = remoteCards.count
        onApprovalClosed?(id)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CoreSocketClient.call("autopilot.answer", ["card": id, "option": option])
        }
    }

    /// Stop First Mate's turn: Esc into its session, which every agent TUI
    /// reads as "stop". The core's session through the core.
    func interrupt() {
        if remote {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = CoreSocketClient.call("pane.send_keys", ["pane_id": FirstMatePane.sessionName, "keys": ["escape"]])
            }
        } else {
            _ = station?.interruptTurn()
        }
    }

    /// First Mate's timeline: the core's while it runs First Mate (`remote`,
    /// read on main by the caller), else the app's own. Blocking (a socket
    /// call) — off main.
    static func timeline(remote: Bool) -> [MessageEvent] {
        if remote {
            guard case .success(let r) = CoreSocketClient.call("message.snapshot", ["pane_id": FirstMatePane.sessionName]) else { return [] }
            return (r["messages"] as? [[String: Any]] ?? []).compactMap(MessageEvent.init(dict:))
        }
        return MessageStreamHub.shared.snapshot(paneId: FirstMatePane.sessionName)
    }

    private static func stripping(_ prefix: String, from text: String) -> String {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    /// Complete lines of `path` past `offset`, and where the next read starts.
    /// A file shorter than `offset` was replaced: read it from the top.
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
