import Foundation

protocol ShipLogDelegate: AnyObject {
    func agentDidUpdate(_ info: SailorInfo)
}

/// Single source of truth for all agent information.
/// Consumers query ShipLog instead of assembling data from multiple sources.
/// Also manages communication channels for each agent.
/// Primary key: terminal ID (Station.id).
class ShipLog {
    static let shared = ShipLog()

    weak var delegate: ShipLogDelegate?

    /// Single output stream: one IngestOutcome per recorded event, delivered on the main thread.
    var onOutcome: ((IngestOutcome) -> Void)?

    /// Tracks when each terminal entered its current status (for holdSeconds calculation).
    private var statusEnteredAt: [String: Date] = [:]

    /// When each terminal's hook last asserted `.running` (a UserPrompt / PreToolUse
    /// leading edge). For session_only agents this lets a hook run promote over a
    /// stale scan `.idle` immediately, while a later scan `.idle` observed *after*
    /// the grace window reclaims it — so an Esc/interrupt that fires no Stop hook
    /// still self-heals instead of sticking on "running".
    private var hookRunningSince: [String: Date] = [:]
    /// Grace before a scan `.idle` is allowed to clear a hook-asserted `.running`.
    /// Long enough for the agent to start rendering its spinner after a prompt.
    /// `var` so tests can drive the trailing-edge reclaim deterministically.
    static var hookRunningGrace: TimeInterval = 3.0

    private var agents: [String: SailorInfo] = [:]       // keyed by terminal ID
    private var eventLog: [String: [NormalizedEvent]] = [:]   // tid → recent N, ring buffer, never persisted
    private var orderedIDs: [String] = []
    /// Reverse index: worktree path → terminal IDs (1:N)
    private var worktreeIndex: [String: [String]] = [:]
    /// Strong references to channels (keyed by terminal ID)
    private var channels: [String: SailorChannel] = [:]
    private var backendsByPath: [String: String] = [:]
    /// External channels (WeCom, future: Slack, etc.) — keyed by channelId
    private var externalChannels: [String: ExternalChannel] = [:]
    private let lock = NSLock()

    /// Monotonic event sequence, incremented under `lock` on every ingest.
    /// Stamped onto each IngestOutcome for ordering / future subscriber replay.
    private var globalSeq: UInt64 = 0

    private init() {}

    #if DEBUG
    /// Test helper: register an agent entry without a real Station.
    func registerForTesting(terminalID: String, worktreePath: String, branch: String, project: String) {
        lock.lock(); defer { lock.unlock() }
        agents[terminalID] = SailorInfo(
            id: terminalID, worktreePath: worktreePath, agentType: .unknown,
            project: project, branch: branch, status: .unknown, lastMessage: "",
            commandLine: nil, roundDuration: 0, startedAt: nil, station: nil,
            channel: nil, taskProgress: TaskProgress())
        worktreeIndex[worktreePath, default: []].append(terminalID)
        if !orderedIDs.contains(terminalID) { orderedIDs.append(terminalID) }
    }
    #endif

    // MARK: - Registration

    func register(station: Station, worktreePath: String, branch: String,
                  project: String, startedAt: Date?,
                  sessionName: String? = nil, backend: String = "zmx") {
        lock.lock()
        defer { lock.unlock() }

        let terminalID = station.id

        // Create a default channel if we have a session name
        var channel: SailorChannel?
        if let sessionName = sessionName {
            channel = ZmxChannel(sessionName: sessionName)
            channels[terminalID] = channel
        }
        backendsByPath[worktreePath] = backend

        let info = SailorInfo(
            id: terminalID,
            worktreePath: worktreePath,
            agentType: .unknown,
            project: project,
            branch: branch,
            status: .unknown,
            lastMessage: "",
            commandLine: nil,
            roundDuration: 0,
            startedAt: startedAt,
            station: station,
            channel: channel,
            taskProgress: TaskProgress()
        )
        agents[terminalID] = info
        var ids = worktreeIndex[worktreePath] ?? []
        if !ids.contains(terminalID) {
            ids.append(terminalID)
        }
        worktreeIndex[worktreePath] = ids
        if !orderedIDs.contains(terminalID) {
            orderedIDs.append(terminalID)
        }
    }

    func unregister(terminalID: String) {
        lock.lock()
        defer { lock.unlock() }

        if let info = agents[terminalID] {
            worktreeIndex[info.worktreePath]?.removeAll { $0 == terminalID }
            if worktreeIndex[info.worktreePath]?.isEmpty == true {
                worktreeIndex.removeValue(forKey: info.worktreePath)
            }
            backendsByPath.removeValue(forKey: info.worktreePath)
        }
        agents.removeValue(forKey: terminalID)
        channels.removeValue(forKey: terminalID)
        orderedIDs.removeAll { $0 == terminalID }
        statusEnteredAt.removeValue(forKey: terminalID)
        hookRunningSince.removeValue(forKey: terminalID)
        eventLog.removeValue(forKey: terminalID)
    }

    // MARK: - Worktree Index (1:N)

    func registerTerminalID(_ terminalID: String, forWorktree worktreePath: String) {
        lock.lock()
        defer { lock.unlock() }
        var ids = worktreeIndex[worktreePath] ?? []
        if !ids.contains(terminalID) {
            ids.append(terminalID)
        }
        worktreeIndex[worktreePath] = ids
    }

    func unregisterTerminalID(_ terminalID: String, forWorktree worktreePath: String) {
        lock.lock()
        defer { lock.unlock() }
        worktreeIndex[worktreePath]?.removeAll { $0 == terminalID }
        if worktreeIndex[worktreePath]?.isEmpty == true {
            worktreeIndex.removeValue(forKey: worktreePath)
        }
    }

    func terminalIDs(forWorktree worktreePath: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return worktreeIndex[worktreePath] ?? []
    }

    // MARK: - Updates

    func updateStatus(terminalID: String, status: SailorStatus,
                      lastMessage: String, roundDuration: TimeInterval,
                      tasks: [TaskItem] = [], lastUserPrompt: String = "") {
        lock.lock()
        guard let current = agents[terminalID] else {
            lock.unlock()
            return
        }
        let reduced = SailorReducer.apply(to: current, status: status,
                                          lastMessage: lastMessage, roundDuration: roundDuration,
                                          tasks: tasks, lastUserPrompt: lastUserPrompt)
        let info = reduced.info
        let changed = reduced.changed
        agents[terminalID] = info
        lock.unlock()

        if changed {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.agentDidUpdate(info)
            }
        }
    }

    /// THE single write entry. Faithfully record, then reduce to a station snapshot + outcome.
    /// Combine the two status sources (screen scan vs agent hook) into one, using
    /// the pane's manifest `authority` (herdr's single-authority-per-pane model):
    ///   - full_lifecycle: hook is authoritative; screen only fills an unknown.
    ///   - session_only (claude/codex): screen is authoritative (hooks miss
    ///     permission/escape transitions); hook only fills an unknown.
    ///   - screen_only / unknown: screen only.
    /// An urgent state (waiting/error) from either source always surfaces — never
    /// hide a blocked or errored agent behind an authority rule.
    static func arbitrate(scan: SailorStatus, hook: SailorStatus, agentType: SailorType) -> SailorStatus {
        arbitrateDetailed(scan: scan, hook: hook, agentType: agentType).status
    }

    /// Whether the agent's manifest makes the screen authoritative (hooks only fill
    /// gaps). Defaults to true when no manifest is registered.
    static func isSessionOnly(_ agentType: SailorType) -> Bool {
        let authority = ManifestStore.shared.manifest(for: agentType.manifestId)?.manifest.authority ?? "session_only"
        return authority == "session_only"
    }

    /// Same as `arbitrate` but also reports which source won (`urgent` / `hook` /
    /// `screen`) and the pane's authority — for `pane.explain`.
    static func arbitrateDetailed(scan: SailorStatus, hook: SailorStatus, agentType: SailorType)
        -> (status: SailorStatus, decidedBy: String, authority: String) {
        let authority = ManifestStore.shared.manifest(for: agentType.manifestId)?.manifest.authority ?? "session_only"
        let urgent = SailorStatus.highestPriority([scan, hook].filter { $0.isUrgent })
        if urgent.isUrgent { return (urgent, "urgent", authority) }
        switch authority {
        case "full_lifecycle": return hook != .unknown ? (hook, "hook", authority) : (scan, "screen", authority)
        case "screen_only":    return (scan, "screen", authority)
        default:
            // session_only: screen is authoritative EXCEPT a hook `.running` edge
            // promotes over a scan `.idle`, so the leading edge (prompt submitted,
            // spinner not yet on screen) surfaces immediately instead of waiting for
            // the next slow scan. `ingest` clears a stale hook `.running` once scan
            // sees a sustained idle, so the trailing edge stays screen-authoritative.
            if scan == .idle && hook == .running { return (hook, "hook", authority) }
            return scan != .unknown ? (scan, "screen", authority) : (hook, "hook", authority)
        }
    }

    func ingest(_ event: NormalizedEvent) {
        lock.lock()
        globalSeq &+= 1
        let seq = globalSeq
        appendToRingBufferLog(event)
        guard let current = agents[event.terminalID] else { lock.unlock(); return }

        var next = current
        var isCompletion = false
        var message = current.lastMessage
        let now = Date()

        switch event.kind {
        case .screenObserved(let status, let msg, let activity, let commandLine, let agentType, let roundDuration, let tasks):
            next.scanStatus = status
            next.roundDuration = roundDuration
            if !tasks.isEmpty { next.tasks = tasks }
            if !msg.isEmpty { message = msg }
            if let cl = commandLine { next.commandLine = cl }
            if agentType != .unknown { next.agentType = agentType }
            if !activity.isEmpty { next.activityEvents = activity }
            // Trailing-edge reclaim: once scan sees a sustained idle (past the grace
            // window since the hook's running edge), drop a stale hook `.running` so
            // an Esc/interrupt that fires no Stop hook doesn't stick on "running".
            if status == .idle, next.hookStatus == .running,
               let since = hookRunningSince[event.terminalID],
               now.timeIntervalSince(since) >= Self.hookRunningGrace,
               Self.isSessionOnly(next.agentType) {
                next.hookStatus = .unknown
                hookRunningSince[event.terminalID] = nil
            }
        case .sessionStarted(let label):
            next.hookStatus = .running
            if hookRunningSince[event.terminalID] == nil { hookRunningSince[event.terminalID] = now }
            message = label
        case .userPrompt(let text):
            next.hookStatus = .running
            if hookRunningSince[event.terminalID] == nil { hookRunningSince[event.terminalID] = now }
            next.lastUserPrompt = text
        case .toolUse(let ev):
            next.hookStatus = .running
            if hookRunningSince[event.terminalID] == nil { hookRunningSince[event.terminalID] = now }
            Self.upsertLatest(&next.activityEvents, event: ev, maxSize: 20)
            message = ev.detail.isEmpty ? message : ev.detail
        case .awaitingInput(let text):
            next.hookStatus = .waiting
            hookRunningSince[event.terminalID] = nil
            message = text
        case .question(let prompt, _):
            // Agent is blocked on an AskUserQuestion choice — same as awaiting input.
            next.hookStatus = .waiting
            hookRunningSince[event.terminalID] = nil
            message = prompt
        case .agentStopped(let success):
            next.hookStatus = success ? .idle : .error
            hookRunningSince[event.terminalID] = nil
            next.activityEvents.removeAll()
            isCompletion = true
        case .notification(let level, let text):
            // Intentionally preserves prior hookStatus for neutral notifications (old code returned .unknown, losing context).
            switch level {
            case "error": next.hookStatus = .error
            case "warning": next.hookStatus = .waiting
            default: break
            }
            if !text.isEmpty { message = text }
        case .taskUpdate(let items):
            next.tasks = items
        case .suggest:
            // Intentionally preserves prior hookStatus; suggest events carry options only, not status.
            break   // does not touch status; passed through via outcome.event
        }

        next.lastMessage = message
        let oldStatus = current.status
        let newStatus = Self.arbitrate(scan: next.scanStatus, hook: next.hookStatus,
                                       agentType: next.agentType)
        next.status = newStatus
        agents[event.terminalID] = next

        let statusChanged = oldStatus != newStatus
        var hold: Double = 0
        if statusChanged {
            let entered = statusEnteredAt[event.terminalID] ?? now
            hold = now.timeIntervalSince(entered)
            statusEnteredAt[event.terminalID] = now
        }
        let hasExternalChannels = !externalChannels.isEmpty
        lock.unlock()

        let outcome = IngestOutcome(info: next, statusChanged: statusChanged,
                                    oldStatus: oldStatus, newStatus: newStatus,
                                    holdSeconds: hold, isCompletionSignal: isCompletion,
                                    event: event, seq: seq)
        notifyObservers(outcome, hasExternalChannels: hasExternalChannels)
    }

    /// Shape an ingest outcome into a control-API event dict for EventHub.
    static func event(from o: IngestOutcome) -> [String: Any] {
        [
            "type": o.statusChanged ? "pane.status_changed" : "pane.updated",
            "seq": o.seq,
            "pane_id": o.info.id,
            "session_name": o.info.station?.sessionName ?? "",
            "status": o.newStatus.rawValue,
            "old_status": o.oldStatus.rawValue,
            "agent_type": o.info.agentType.rawValue,
            "worktree_path": o.info.worktreePath,
            "last_message": o.info.lastMessage,
        ]
    }

    /// All observer delivery hops to main for ordering. Subscribers never run on the scan queue.
    private func notifyObservers(_ outcome: IngestOutcome, hasExternalChannels: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.agentDidUpdate(outcome.info)
            self.onOutcome?(outcome)
            EventHub.shared.publish(seq: outcome.seq, event: Self.event(from: outcome))
            if hasExternalChannels && outcome.statusChanged
                && (outcome.newStatus == .waiting || outcome.newStatus == .error) {
                let i = outcome.info
                self.broadcast("[\(i.project)] \(outcome.newStatus.icon) \(outcome.newStatus.rawValue): \(i.lastMessage)",
                               format: .markdown)
            }
        }
    }

    private func appendToRingBufferLog(_ event: NormalizedEvent) {
        var log = eventLog[event.terminalID] ?? []
        log.insert(event, at: 0)
        if log.count > 50 { log.removeLast() }
        eventLog[event.terminalID] = log
    }

    /// Ring-buffer upsert used by reduce for .toolUse (mirrors upsertLatestActivityEvent).
    static func upsertLatest(_ buffer: inout [ActivityEvent], event: ActivityEvent, maxSize: Int) {
        if let latest = buffer.first, latest.tool == event.tool, latest.detail == event.detail {
            buffer[0] = event
        } else {
            appendToRingBuffer(&buffer, event: event, maxSize: maxSize)
        }
    }

    /// Update task progress for an agent
    func updateTaskProgress(terminalID: String, totalTasks: Int,
                            completedTasks: Int, currentTask: String?) {
        lock.lock()
        guard var info = agents[terminalID] else {
            lock.unlock()
            return
        }
        let changed = info.taskProgress.totalTasks != totalTasks
            || info.taskProgress.completedTasks != completedTasks
            || info.taskProgress.currentTask != currentTask
        info.taskProgress = TaskProgress(
            totalTasks: totalTasks,
            completedTasks: completedTasks,
            currentTask: currentTask
        )
        agents[terminalID] = info
        lock.unlock()

        if changed {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.agentDidUpdate(info)
            }
        }
    }

    /// Update detection results for an agent (command line and/or agent type).
    /// Type update rules:
    /// - .unknown → any type allowed
    /// - shell task (isShellTask) → any type allowed
    /// - AI agent (isAIAgent) → only another AI agent allowed (no demotion)
    /// When type supports hooks, upgrades backend channel → HooksChannel.
    func updateDetection(terminalID: String, commandLine: String?, agentType: SailorType) {
        lock.lock()
        guard var info = agents[terminalID] else {
            lock.unlock()
            return
        }

        let worktreePath = info.worktreePath

        // Upgrade channel for supported hook-based agents.
        if agentType == .claudeCode || agentType == .codex {
            let backend = backendsByPath[worktreePath] ?? "zmx"
            if let zmx = channels[terminalID] as? ZmxChannel {
                let hooks = HooksChannel(sessionName: zmx.sessionName, backend: backend)
                channels[terminalID] = hooks
                info.channel = hooks
            }
        }

        var changed = false

        // Update command line if provided
        if let cl = commandLine, info.commandLine != cl {
            info.commandLine = cl
            changed = true
        }

        // Apply type update rules
        if agentType != .unknown {
            let currentType = info.agentType
            let allowed: Bool
            if currentType == .unknown {
                allowed = true
            } else if currentType.isShellTask {
                allowed = true
            } else if currentType.isAIAgent {
                allowed = agentType.isAIAgent
            } else {
                allowed = true
            }

            if allowed && currentType != agentType {
                info.agentType = agentType
                changed = true

                // Upgrade channel for supported hook-based agents.
                if (agentType == .claudeCode || agentType == .codex),
                   let zmx = channels[terminalID] as? ZmxChannel {
                    let hooks = HooksChannel(sessionName: zmx.sessionName)
                    channels[terminalID] = hooks
                    info.channel = hooks
                }
            }
        }

        agents[terminalID] = info
        lock.unlock()

        if changed {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.agentDidUpdate(info)
            }
        }
    }

    // MARK: - Channel Communication

    /// Record the agent's final prose (Stop hook `last_assistant_message`) for a worktree
    /// WITHOUT changing status — used to give suggestion cards a summary line. Resolves
    /// pane → terminal the same way `handleWebhookEvent` does: the exact pane wins,
    /// cwd's first pane is the fallback.
    func noteAssistantMessage(cwd: String, paneId: String? = nil, message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let paneTid = paneId.flatMap { StationRegistry.shared.station(forSessionName: $0)?.id }
        lock.lock()
        let tid = (paneTid.flatMap { agents[$0] != nil ? $0 : nil })
            ?? worktreeIndex.first { cwd == $0.key || cwd.hasPrefix($0.key + "/") }?.value.first
        guard let tid, var info = agents[tid] else { lock.unlock(); return }
        info.lastMessage = trimmed
        info.lastAssistantMessage = trimmed  // preserved for suggestion-card summary
        agents[tid] = info
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.delegate?.agentDidUpdate(info) }
    }

    // MARK: - Background-task tracking (for suggestion gating)

    /// Worktree paths that currently have background work running (subagent / shell / cron).
    /// While busy, agent suggestions are suppressed — the agent will auto-resume, so it's
    /// not a real end-of-turn. Source of truth: the Stop/SubagentStop `background_tasks` field,
    /// plus SubagentStart (which precedes any voluntary seahelm-suggest call).
    private var backgroundBusy: Set<String> = []

    /// Update background-busy state from any incoming webhook event.
    func updateBackgroundBusy(from event: WebhookEvent) {
        switch event.event {
        case .subagentStart:
            setBackgroundBusy(cwd: event.cwd, busy: true)
        case .agentStop, .subagentStop:
            setBackgroundBusy(cwd: event.cwd, busy: StopHookResponder.hasRunningBackgroundTask(event.data))
        default:
            break
        }
    }

    /// True if the worktree owning `cwd` currently has background work running.
    func isBackgroundBusy(cwd: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let path = worktreePathLocked(forCwd: cwd) else { return false }
        return backgroundBusy.contains(path)
    }

    private func setBackgroundBusy(cwd: String, busy: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let path = worktreePathLocked(forCwd: cwd) else { return }
        if busy { backgroundBusy.insert(path) } else { backgroundBusy.remove(path) }
    }

    /// Resolve a cwd to the worktree path it belongs to. Caller must hold `lock`.
    private func worktreePathLocked(forCwd cwd: String) -> String? {
        worktreeIndex.first { cwd == $0.key || cwd.hasPrefix($0.key + "/") }?.key
    }

    /// Send a command to a specific agent.
    /// Prefer typing into the live terminal surface (exactly like the user) so no control-channel
    /// artifacts leak into the command line — e.g. `zmx run` appends a `ZMX_TASK_COMPLETED` marker,
    /// which showed up verbatim when a suggestion chip was clicked. Fall back to the control channel
    /// only when the surface isn't available (e.g. pane not currently rendered).
    func sendCommand(to terminalID: String, command: String) {
        if let station = StationRegistry.shared.station(forId: terminalID) {
            // Send the text first, then the Enter as a separate write. Agent TUIs
            // (Claude Code, codex) treat a `\r` arriving in the same burst as the
            // pasted text as a literal newline (multiline input) instead of a
            // submit, so the order text lands but never sends. A short gap lets the
            // TUI finish ingesting the paste before the Return submits it.
            DispatchQueue.main.async {
                station.sendText(command)
                // Submit via a real Return key event (not "\r" text), after a beat
                // so the TUI finishes ingesting the pasted text first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    station.sendEnterKey()
                }
            }
            return
        }
        lock.lock()
        let channel = channels[terminalID]
        lock.unlock()
        channel?.sendCommand(command)
    }

    /// Read recent output from a specific agent
    func readOutput(from terminalID: String, lines: Int = 50) -> String? {
        lock.lock()
        let channel = channels[terminalID]
        lock.unlock()

        return channel?.readOutput(lines: lines)
    }

    /// Get the channel for a specific agent (for direct access)
    func channel(for terminalID: String) -> SailorChannel? {
        lock.lock()
        defer { lock.unlock() }
        return channels[terminalID]
    }

    /// Route a webhook event to the appropriate HooksChannel. The exact pane the
    /// hook ran under (SEAHELM_PANE_ID → station session name) wins; cwd matching
    /// is the fallback. Resolving by cwd alone always picked the worktree's FIRST
    /// pane, so a suggestion raised in a split pane was attributed to — and its
    /// picked option sent into — a sibling pane.
    func handleWebhookEvent(_ event: WebhookEvent) {
        let paneTid = event.paneId.flatMap { StationRegistry.shared.station(forSessionName: $0)?.id }
        lock.lock()
        // Find the agent whose worktree path matches the event's cwd
        let matchingTIDs = worktreeIndex.first { (worktreePath, _) in
            event.cwd == worktreePath || event.cwd.hasPrefix(worktreePath + "/")
        }?.value
        let resolvedTid: String? = {
            if let paneTid, agents[paneTid] != nil { return paneTid }
            return matchingTIDs?.first
        }()
        guard let tid = resolvedTid else {
            let known = Array(worktreeIndex.keys)
            lock.unlock()
            if event.event == .suggest {
                NSLog("[suggest] DROP cwd-unresolved — cwd=\(event.cwd) knownWorktrees=\(known)")
            }
            return
        }
        lock.unlock()
        if event.event == .suggest {
            NSLog("[suggest] pass gate2 (cwd→tid=\(tid)) — cwd=\(event.cwd)")
        }

        switch event.source {
        case "claude-code":
            updateDetection(terminalID: tid, commandLine: nil, agentType: .claudeCode)
        case "codex":
            updateDetection(terminalID: tid, commandLine: nil, agentType: .codex)
        default:
            break
        }

        // cwd_changed only updates routing (handled above via worktreeIndex); no station event.
        guard let event2 = HookDecoder(terminalID: tid, event: event).decode() else { return }
        ingest(event2)
        if let hooks = channel(for: tid) as? HooksChannel {
            hooks.handleWebhookEvent(event)
        }
    }

    // MARK: - Activity Events

    /// Ring buffer helper: insert at front, cap at maxSize.
    /// Exposed as static for testability.
    static func appendToRingBuffer(_ buffer: inout [ActivityEvent], event: ActivityEvent, maxSize: Int) {
        buffer.insert(event, at: 0)
        if buffer.count > maxSize {
            buffer.removeLast()
        }
    }

    /// Append an activity event for a terminal's agent.
    func appendActivityEvent(_ event: ActivityEvent, forTerminalID tid: String) {
        lock.lock()
        guard agents[tid] != nil else {
            lock.unlock()
            return
        }
        Self.appendToRingBuffer(&agents[tid]!.activityEvents, event: event, maxSize: 20)
        lock.unlock()
    }

    /// Append or replace the newest activity event when the incoming event refers to the same tool/detail.
    func upsertLatestActivityEvent(_ event: ActivityEvent, forTerminalID tid: String) {
        lock.lock()
        guard agents[tid] != nil else {
            lock.unlock()
            return
        }
        if let latest = agents[tid]!.activityEvents.first,
           latest.tool == event.tool,
           latest.detail == event.detail {
            agents[tid]!.activityEvents[0] = event
        } else {
            Self.appendToRingBuffer(&agents[tid]!.activityEvents, event: event, maxSize: 20)
        }
        lock.unlock()
    }

    /// Replace activity events for a terminal (used by text-based extraction).
    func updateActivityEvents(_ events: [ActivityEvent], forTerminalID tid: String) {
        lock.lock()
        guard agents[tid] != nil else {
            lock.unlock()
            return
        }
        agents[tid]!.activityEvents = events
        lock.unlock()
    }

    /// Clear activity events for a terminal (on agent stop).
    func clearActivityEvents(forTerminalID tid: String) {
        lock.lock()
        agents[tid]?.activityEvents.removeAll()
        lock.unlock()
    }

    // MARK: - Ordering

    /// Reorder agents to match card ordering from config.
    /// Accepts worktree paths (for config persistence) and maps internally via worktreeIndex.
    func reorder(paths: [String]) {
        lock.lock()
        defer { lock.unlock() }

        orderedIDs.sort { a, b in
            let pathA = agents[a]?.worktreePath ?? ""
            let pathB = agents[b]?.worktreePath ?? ""
            let ai = paths.firstIndex(of: pathA) ?? Int.max
            let bi = paths.firstIndex(of: pathB) ?? Int.max
            return ai < bi
        }
    }

    // MARK: - Queries

    func allSailors() -> [SailorInfo] {
        lock.lock()
        defer { lock.unlock() }

        return orderedIDs.compactMap { agents[$0] }
    }

    /// Look up sailor by terminal ID
    func sailor(for terminalID: String) -> SailorInfo? {
        lock.lock()
        defer { lock.unlock() }

        return agents[terminalID]
    }

    /// Convenience lookup by worktree path via reverse index
    func sailor(forWorktree worktreePath: String) -> SailorInfo? {
        lock.lock()
        defer { lock.unlock() }

        guard let tid = worktreeIndex[worktreePath]?.first else { return nil }
        return agents[tid]
    }

    func sailorsForProject(_ project: String) -> [SailorInfo] {
        lock.lock()
        defer { lock.unlock() }

        return orderedIDs.compactMap { agents[$0] }.filter { $0.project == project }
    }

    // MARK: - TODO Status Updates (Future)

    /// Stub for future webhook-driven TODO status updates.
    /// Future logic: match event.cwd → worktree path → branch name → TodoItem.branch,
    /// then update status based on event type:
    ///   - SessionStart → "running"
    ///   - Stop (end_turn) → "completed"
    ///   - StopFailure → "failed"
    ///   - SubagentStart → update progress
    func updateTodoFromWebhook(_ event: WebhookEvent) {
        // Not yet implemented — will be filled when ShipLog status
        // pipeline is connected to TodoStore.
    }

    // MARK: - External Channel Management

    /// Register an external channel (WeCom, Slack, etc.)
    func registerChannel(_ channel: ExternalChannel) {
        lock.lock()
        externalChannels[channel.channelId] = channel
        lock.unlock()

        channel.onMessage = { [weak self] message in
            self?.handleInbound(message)
        }
    }

    /// Unregister and disconnect an external channel
    func unregisterChannel(_ channelId: String) {
        lock.lock()
        let channel = externalChannels.removeValue(forKey: channelId)
        lock.unlock()

        channel?.disconnect()
    }

    /// Remove all external channels (for testing)
    func unregisterAllExternalChannels() {
        lock.lock()
        let channels = externalChannels
        externalChannels.removeAll()
        lock.unlock()

        for (_, channel) in channels {
            channel.disconnect()
        }
    }

    // MARK: - Inbound Message Handling

    /// Process an inbound message from an external channel.
    /// Phase 1: slash command routing.
    /// Phase 2 (future): LLM intent understanding.
    func handleInbound(_ message: InboundMessage) {
        if let cmd = CommandParser.parse(message) {
            executeCommand(cmd)
        } else {
            reply(to: message, content: "Use /help to see supported commands")
        }
    }

    private func executeCommand(_ cmd: ParsedCommand) {
        switch cmd.command {
        case "help":
            let help = """
            **Seahelm Commands**
            `/idea <description>` — Add a new idea
            `/status` — Show status of all agents
            `/list` — List all agents
            `/send <project> <command>` — Send a command to an agent
            `/help` — Show this help
            """
            reply(to: cmd.rawMessage, content: help)

        case "idea":
            guard !cmd.args.isEmpty else {
                reply(to: cmd.rawMessage, content: "Usage: `/idea <description>`")
                return
            }
            let item = IdeaStore.shared.add(
                text: cmd.args,
                project: "external",
                source: "wecom:\(cmd.rawMessage.senderId)",
                tags: []
            )
            reply(to: cmd.rawMessage, content: "Idea added: \(item.text)")

        case "status":
            let agents = allSailors()
            if agents.isEmpty {
                reply(to: cmd.rawMessage, content: "No agents running.")
                return
            }
            var lines = ["**Agent Status**", ""]
            for a in agents {
                lines.append("\(a.status.icon) **\(a.project)** [\(a.branch)] — \(a.status.rawValue): \(a.lastMessage)")
            }
            reply(to: cmd.rawMessage, content: lines.joined(separator: "\n"), format: .markdown)

        case "list":
            let agents = allSailors()
            if agents.isEmpty {
                reply(to: cmd.rawMessage, content: "No agents registered.")
                return
            }
            var lines = ["**Agents**", ""]
            for a in agents {
                lines.append("- \(a.project) / \(a.branch) — \(a.status.rawValue)")
            }
            reply(to: cmd.rawMessage, content: lines.joined(separator: "\n"), format: .markdown)

        case "send":
            let parts = cmd.args.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else {
                reply(to: cmd.rawMessage, content: "Usage: `/send <project> <command>`")
                return
            }
            let project = String(parts[0])
            let command = String(parts[1])
            let matched = sailorsForProject(project)
            guard let target = matched.first else {
                reply(to: cmd.rawMessage, content: "Project not found: \(project)")
                return
            }
            sendCommand(to: target.id, command: command)
            reply(to: cmd.rawMessage, content: "Command sent to \(target.project): \(command)")

        default:
            reply(to: cmd.rawMessage, content: "Unknown command: /\(cmd.command)\nUse /help to see supported commands")
        }
    }

    /// Send a reply back through the same external channel
    private func reply(to message: InboundMessage, content: String, format: MessageFormat = .text) {
        let outbound = OutboundMessage(
            channelId: message.channelId,
            targetChatId: message.chatId,
            targetUserId: message.chatId == nil ? message.senderId : nil,
            content: content,
            format: format,
            replyToMessageId: message.messageId
        )
        pushToChannel(message.channelId, message: outbound)
    }

    /// Push a message to a specific external channel
    func pushToChannel(_ channelId: String, message: OutboundMessage) {
        lock.lock()
        let channel = externalChannels[channelId]
        lock.unlock()

        channel?.send(message)
    }

    /// Broadcast a message to all registered external channels
    func broadcast(_ content: String, format: MessageFormat = .text) {
        lock.lock()
        let channels = Array(externalChannels.values)
        lock.unlock()

        for channel in channels {
            let message = OutboundMessage(
                channelId: channel.channelId,
                content: content,
                format: format
            )
            channel.send(message)
        }
    }
}
