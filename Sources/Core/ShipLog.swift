import Foundation

protocol ShipLogDelegate: AnyObject {
    func agentDidUpdate(_ info: AgentInfo)
}

/// Single source of truth for all agent information.
/// Consumers query ShipLog instead of assembling data from multiple sources.
/// Also manages communication channels for each agent.
/// Primary key: terminal ID (TerminalSurface.id).
class ShipLog {
    static let shared = ShipLog()

    weak var delegate: ShipLogDelegate?

    /// First Mate observer: status-edge and completion signals, called on main thread.
    var onStatusTransition: ((StatusTransition) -> Void)?

    /// Tracks when each terminal entered its current status (for holdSeconds calculation).
    private var statusEnteredAt: [String: Date] = [:]

    private var agents: [String: AgentInfo] = [:]       // keyed by terminal ID
    private var orderedIDs: [String] = []
    /// Reverse index: worktree path → terminal IDs (1:N)
    private var worktreeIndex: [String: [String]] = [:]
    /// Strong references to channels (keyed by terminal ID)
    private var channels: [String: AgentChannel] = [:]
    private var backendsByPath: [String: String] = [:]
    /// External channels (WeCom, future: Slack, etc.) — keyed by channelId
    private var externalChannels: [String: ExternalChannel] = [:]
    private let lock = NSLock()

    private init() {}

    #if DEBUG
    /// Test helper: register an agent entry without a real TerminalSurface.
    func registerForTesting(terminalID: String, worktreePath: String, branch: String, project: String) {
        lock.lock(); defer { lock.unlock() }
        agents[terminalID] = AgentInfo(
            id: terminalID, worktreePath: worktreePath, agentType: .unknown,
            project: project, branch: branch, status: .unknown, lastMessage: "",
            commandLine: nil, roundDuration: 0, startedAt: nil, surface: nil,
            channel: nil, taskProgress: TaskProgress())
        worktreeIndex[worktreePath, default: []].append(terminalID)
        if !orderedIDs.contains(terminalID) { orderedIDs.append(terminalID) }
    }
    #endif

    // MARK: - Registration

    func register(surface: TerminalSurface, worktreePath: String, branch: String,
                  project: String, startedAt: Date?,
                  tmuxSessionName: String? = nil, backend: String = "zmx") {
        lock.lock()
        defer { lock.unlock() }

        let terminalID = surface.id

        // Create a default channel if we have a session name
        var channel: AgentChannel?
        if let sessionName = tmuxSessionName {
            if backend == "tmux" {
                channel = TmuxChannel(sessionName: sessionName)
            } else {
                channel = ZmxChannel(sessionName: sessionName)
            }
            channels[terminalID] = channel
        }
        backendsByPath[worktreePath] = backend

        let info = AgentInfo(
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
            surface: surface,
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

    func updateStatus(terminalID: String, status: AgentStatus,
                      lastMessage: String, roundDuration: TimeInterval,
                      tasks: [TaskItem] = [], lastUserPrompt: String = "") {
        lock.lock()
        guard var info = agents[terminalID] else {
            lock.unlock()
            return
        }
        let previousStatus = info.status
        let changed = info.status != status || info.lastMessage != lastMessage
            || info.tasks.count != tasks.count
        info.status = status
        info.lastMessage = lastMessage
        if !lastUserPrompt.isEmpty {
            info.lastUserPrompt = lastUserPrompt
        }
        info.roundDuration = roundDuration
        info.tasks = tasks
        agents[terminalID] = info
        let hasExternalChannels = !externalChannels.isEmpty
        lock.unlock()

        if changed {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.agentDidUpdate(info)
            }

            if previousStatus != status {
                let now = Date()
                lock.lock()
                let entered = statusEnteredAt[terminalID] ?? now
                statusEnteredAt[terminalID] = now
                lock.unlock()
                let hold = now.timeIntervalSince(entered)
                let transition = StatusTransition(
                    worktreePath: info.worktreePath, branch: info.branch,
                    project: info.project, terminalID: terminalID,
                    oldStatus: previousStatus, newStatus: status,
                    holdSeconds: hold, isCompletionSignal: false)
                DispatchQueue.main.async { [weak self] in
                    self?.onStatusTransition?(transition)
                }
            }

            // Notify external channels on critical status transitions
            if hasExternalChannels && previousStatus != status
                && (status == .waiting || status == .error) {
                let text = "[\(info.project)] \(status.icon) \(status.rawValue): \(lastMessage)"
                broadcast(text, format: .markdown)
            }
        }
    }

    /// Unified entry point: unpack a StatusReport and apply to ShipLog.
    /// All channels (active scan, passive hook) funnel through here.
    /// roundDuration and tasks are supplied by the caller when the report doesn't carry them
    /// (e.g. ScanDecoder leaves lastMessage blank; StatusPublisher fills it in via messageOverride).
    func ingest(terminalID: String, report: StatusReport,
                lastUserPrompt: String = "",
                messageOverride: String? = nil,
                roundDuration: TimeInterval = 0,
                tasks: [TaskItem] = []) {
        let message = messageOverride ?? report.lastMessage
        updateStatus(
            terminalID: terminalID,
            status: report.status,
            lastMessage: message,
            roundDuration: roundDuration,
            tasks: tasks,
            lastUserPrompt: lastUserPrompt
        )
        for event in report.activityEvents {
            upsertLatestActivityEvent(event, forTerminalID: terminalID)
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
    func updateDetection(terminalID: String, commandLine: String?, agentType: AgentType) {
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

    /// Send a command to a specific agent
    func sendCommand(to terminalID: String, command: String) {
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
    func channel(for terminalID: String) -> AgentChannel? {
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

        let hooks = channel(for: tid) as? HooksChannel

        hooks?.handleWebhookEvent(event)

        // Decode the event via HookDecoder and route through ingest.
        if let report = HookDecoder(event: event).decode() {
            ingest(terminalID: tid, report: report)
        }

        // agentStop: clear activity buffer and fire completion signal
        if event.event == .agentStop {
            clearActivityEvents(forTerminalID: tid)
            if let info = agent(for: tid) {
                let t = StatusTransition(
                    worktreePath: info.worktreePath, branch: info.branch,
                    project: info.project, terminalID: tid,
                    oldStatus: info.status, newStatus: info.status,
                    holdSeconds: 0, isCompletionSignal: true)
                DispatchQueue.main.async { [weak self] in self?.onStatusTransition?(t) }
            }
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

    func allAgents() -> [AgentInfo] {
        lock.lock()
        defer { lock.unlock() }

        return orderedIDs.compactMap { agents[$0] }
    }

    /// Look up agent by terminal ID
    func agent(for terminalID: String) -> AgentInfo? {
        lock.lock()
        defer { lock.unlock() }

        return agents[terminalID]
    }

    /// Convenience lookup by worktree path via reverse index
    func agent(forWorktree worktreePath: String) -> AgentInfo? {
        lock.lock()
        defer { lock.unlock() }

        guard let tid = worktreeIndex[worktreePath]?.first else { return nil }
        return agents[tid]
    }

    func agentsForProject(_ project: String) -> [AgentInfo] {
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
            let agents = allAgents()
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
            let agents = allAgents()
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
            let matched = agentsForProject(project)
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
