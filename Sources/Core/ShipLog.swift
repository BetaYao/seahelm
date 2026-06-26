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
                  tmuxSessionName: String? = nil, backend: String = "zmx") {
        lock.lock()
        defer { lock.unlock() }

        let terminalID = station.id

        // Create a default channel if we have a session name
        var channel: SailorChannel?
        if let sessionName = tmuxSessionName {
            if backend == "tmux" {
                channel = TmuxChannel(sessionName: sessionName)
            } else {
                channel = ZmxChannel(sessionName: sessionName)
            }
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
    func ingest(_ event: NormalizedEvent) {
        lock.lock()
        appendToRingBufferLog(event)
        guard let current = agents[event.terminalID] else { lock.unlock(); return }

        var next = current
        var isCompletion = false
        var message = current.lastMessage

        switch event.kind {
        case .screenObserved(let status, let msg, let activity, let commandLine, let agentType, let roundDuration, let tasks):
            next.scanStatus = status
            next.roundDuration = roundDuration
            if !tasks.isEmpty { next.tasks = tasks }
            if !msg.isEmpty { message = msg }
            if let cl = commandLine { next.commandLine = cl }
            if agentType != .unknown { next.agentType = agentType }
            if !activity.isEmpty { next.activityEvents = activity }
        case .sessionStarted(let label):
            next.hookStatus = .running
            message = label
        case .userPrompt(let text):
            next.hookStatus = .running
            next.lastUserPrompt = text
        case .toolUse(let ev):
            next.hookStatus = .running
            Self.upsertLatest(&next.activityEvents, event: ev, maxSize: 20)
            message = ev.detail.isEmpty ? message : ev.detail
        case .awaitingInput(let text):
            next.hookStatus = .waiting
            message = text
        case .agentStopped(let success):
            next.hookStatus = success ? .idle : .error
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
        let newStatus = SailorStatus.highestPriority([next.scanStatus, next.hookStatus])
        next.status = newStatus
        agents[event.terminalID] = next

        let now = Date()
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
                                    event: event)
        notifyObservers(outcome, hasExternalChannels: hasExternalChannels)
    }

    /// All observer delivery hops to main for ordering. Subscribers never run on the scan queue.
    private func notifyObservers(_ outcome: IngestOutcome, hasExternalChannels: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.agentDidUpdate(outcome.info)
            self.onOutcome?(outcome)
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
            } else if let tmux = channels[terminalID] as? TmuxChannel {
                let hooks = HooksChannel(sessionName: tmux.sessionName, backend: backend)
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
                   let tmux = channels[terminalID] as? TmuxChannel {
                    let hooks = HooksChannel(sessionName: tmux.sessionName)
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

    /// Send a command to a specific agent.
    /// Prefer typing into the live terminal surface (exactly like the user) so no control-channel
    /// artifacts leak into the command line — e.g. `zmx run` appends a `ZMX_TASK_COMPLETED` marker,
    /// which showed up verbatim when a suggestion chip was clicked. Fall back to the control channel
    /// only when the surface isn't available (e.g. pane not currently rendered).
    func sendCommand(to terminalID: String, command: String) {
        if let station = StationRegistry.shared.station(forId: terminalID) {
            DispatchQueue.main.async { station.sendText(command + "\r") }
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

    /// Route a webhook event to the appropriate HooksChannel based on cwd matching
    func handleWebhookEvent(_ event: WebhookEvent) {
        lock.lock()
        // Find the agent whose worktree path matches the event's cwd
        let matchingTIDs = worktreeIndex.first { (worktreePath, _) in
            event.cwd == worktreePath || event.cwd.hasPrefix(worktreePath + "/")
        }?.value
        guard let tid = matchingTIDs?.first else {
            lock.unlock()
            return
        }
        lock.unlock()

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
            reply(to: message, content: "请使用 /help 查看支持的命令")
        }
    }

    private func executeCommand(_ cmd: ParsedCommand) {
        switch cmd.command {
        case "help":
            let help = """
            **Seahelm 命令列表**
            `/idea <描述>` — 新增一个 idea
            `/status` — 查看所有 agent 状态
            `/list` — 列出所有 agent
            `/send <project> <command>` — 给指定 agent 下指令
            `/help` — 显示帮助
            """
            reply(to: cmd.rawMessage, content: help)

        case "idea":
            guard !cmd.args.isEmpty else {
                reply(to: cmd.rawMessage, content: "用法: `/idea <描述>`")
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
                reply(to: cmd.rawMessage, content: "用法: `/send <project> <command>`")
                return
            }
            let project = String(parts[0])
            let command = String(parts[1])
            let matched = sailorsForProject(project)
            guard let target = matched.first else {
                reply(to: cmd.rawMessage, content: "未找到 project: \(project)")
                return
            }
            sendCommand(to: target.id, command: command)
            reply(to: cmd.rawMessage, content: "Command sent to \(target.project): \(command)")

        default:
            reply(to: cmd.rawMessage, content: "未知命令: /\(cmd.command)\n请使用 /help 查看支持的命令")
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
