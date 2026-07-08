import Foundation

class WebhookStatusProvider {
    private let queue = DispatchQueue(label: "seahelm.webhook-status")
    private var sessions: [String: SessionState] = [:]
    private var knownWorktrees: [String] = []
    var onStatusChanged: ((String) -> Void)?
    var codexPromptLookup: (String) -> String? = { sessionId in
        CodexSessionPromptLookup.lastUserPrompt(sessionId: sessionId)
    }

    /// Called when a WorktreeCreate event arrives with a path not in knownWorktrees
    var onNewWorktreeDetected: ((String) -> Void)?

    /// Called (on main) when an agent hook event resolves a persistable resume
    /// ref for a known worktree. The owner persists it and applies it to live
    /// stations so the agent can be relaunched after a session is recreated.
    var onAgentSessionResolved: ((_ worktreePath: String, _ ref: AgentSessionRef) -> Void)?

    /// Called when a WorktreeCreate event arrives, with source worktree path and worktree name.
    /// Fires before the new worktree is discoverable (the git operation may still be in progress).
    var onWorktreeCreateReceived: ((_ sourceWorktreePath: String, _ worktreeName: String, _ sessionId: String) -> Void)?

    struct SessionState {
        let sessionId: String
        let worktreePath: String
        var status: SailorStatus
        var lastEvent: Date
        var lastMessage: String?
        var lastUserPrompt: String?
        var tasks: [TaskItem] = []
        var nextTaskId: Int = 1
    }

    func updateWorktrees(_ paths: [String]) {
        queue.sync {
            knownWorktrees = paths.map { canonicalize($0) }
            // Remove sessions for worktrees no longer tracked
            sessions = sessions.filter { (_, state) in
                knownWorktrees.contains(state.worktreePath)
            }
            // Prune stale sessions (no events for >1 hour)
            let cutoff = Date().addingTimeInterval(-3600)
            sessions = sessions.filter { $0.value.lastEvent > cutoff }
        }
    }

    func handleEvent(_ event: WebhookEvent) {
        queue.sync {
            let canonCwd = canonicalize(event.cwd)

            // WorktreeCreate: record transfer intent before new worktree is discoverable
            if event.event == .worktreeCreate {
                // Claude Code sends "branch" and "worktree_path", not "worktree_name".
                // Prefer worktree_path's last component since PendingTransferTracker
                // matches by directory name, not branch name.
                let worktreeName: String = {
                    if let name = event.data?["worktree_name"] as? String, !name.isEmpty { return name }
                    if let wtPath = event.data?["worktree_path"] as? String, !wtPath.isEmpty {
                        return URL(fileURLWithPath: wtPath).lastPathComponent
                    }
                    if let branch = event.data?["branch"] as? String, !branch.isEmpty { return branch }
                    return ""
                }()
                if !worktreeName.isEmpty {
                    let sourcePath = canonCwd
                    let worktreePath = event.data?["worktree_path"] as? String
                    NSLog("[WebhookStatusProvider] WorktreeCreate from \(sourcePath): \(worktreeName)")
                    DispatchQueue.main.async { [weak self] in
                        self?.onWorktreeCreateReceived?(sourcePath, worktreeName, event.sessionId)
                    }
                    // Also trigger delayed discovery — CwdChanged may not fire
                    // if the agent stays in the original directory after creating the worktree
                    if let wtPath = worktreePath {
                        let canonWtPath = canonicalize(wtPath)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            guard let self else { return }
                            if self.matchWorktreeSync(canonWtPath) == nil {
                                NSLog("[WebhookStatusProvider] Triggering discovery for WorktreeCreate path: \(wtPath)")
                                self.onNewWorktreeDetected?(canonWtPath)
                            }
                        }
                    }
                }
                return
            }

            // CwdChanged with unknown path → notify upstream to discover it
            if event.event == .cwdChanged {
                if matchWorktree(canonCwd) == nil {
                    NSLog("[WebhookStatusProvider] New worktree detected via CwdChanged: \(event.cwd)")
                    DispatchQueue.main.async { [weak self] in
                        self?.onNewWorktreeDetected?(canonCwd)
                    }
                }
                // CwdChanged falls through to update session status
            }

            guard let worktreePath = matchWorktree(canonCwd) else {
                NSLog("[WebhookStatusProvider] No worktree match for cwd: \(event.cwd)")
                return
            }

            let status = event.event.agentStatus(data: event.data)
            let message = Self.extractMessage(from: event)
            let userPrompt = Self.extractUserPrompt(from: event) ?? fallbackUserPrompt(for: event)

            if var existing = sessions[event.sessionId] {
                existing.status = status
                existing.lastEvent = Date()
                if let message { existing.lastMessage = message }
                if let userPrompt { existing.lastUserPrompt = userPrompt }
                Self.applyTaskEvent(event, to: &existing)
                sessions[event.sessionId] = existing
            } else {
                var newSession = SessionState(
                    sessionId: event.sessionId,
                    worktreePath: worktreePath,
                    status: status,
                    lastEvent: Date(),
                    lastMessage: message,
                    lastUserPrompt: userPrompt
                )
                Self.applyTaskEvent(event, to: &newSession)
                sessions[event.sessionId] = newSession
            }

            // Persist a resume ref for recognized agents. Exclude subagent
            // events — their `agent_id` marks a nested context, and (as herdr
            // learned) letting them drive main-pane lifecycle causes false
            // revivals. `worktreeCreate` already returned early above, so its
            // cross-worktree session id never reaches here.
            if event.data?["agent_id"] == nil,
               let ref = AgentSessionRef(source: event.source, sessionId: event.sessionId) {
                DispatchQueue.main.async { [weak self] in
                    self?.onAgentSessionResolved?(worktreePath, ref)
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.onStatusChanged?(worktreePath)
            }
        }
    }

    func status(for worktreePath: String) -> SailorStatus {
        queue.sync {
            let canon = canonicalize(worktreePath)
            let sessionStatuses = sessions.values
                .filter { $0.worktreePath == canon }
                .map { $0.status }
            return SailorStatus.highestPriority(sessionStatuses)
        }
    }

    /// Returns the most recent webhook-derived message for a worktree, or nil
    func lastMessage(for worktreePath: String) -> String? {
        queue.sync {
            let canon = canonicalize(worktreePath)
            // Pick the session with the most recent event
            return sessions.values
                .filter { $0.worktreePath == canon }
                .max(by: { $0.lastEvent < $1.lastEvent })?
                .lastMessage
        }
    }

    /// Returns the most recent user prompt for a worktree, or nil
    func lastUserPrompt(for worktreePath: String) -> String? {
        queue.sync {
            let canon = canonicalize(worktreePath)
            return sessions.values
                .filter { $0.worktreePath == canon }
                .max(by: { $0.lastEvent < $1.lastEvent })?
                .lastUserPrompt
        }
    }

    /// Extract the user's prompt text from a userPrompt event
    private static func extractUserPrompt(from event: WebhookEvent) -> String? {
        guard event.event == .userPrompt else { return nil }
        // Claude Code sends the prompt text in the "prompt" field
        if let prompt = event.data?["prompt"] as? String, !prompt.isEmpty {
            return prompt
        }
        if let input = event.data?["input"] as? String, !input.isEmpty {
            return input
        }
        if let text = event.data?["text"] as? String, !text.isEmpty {
            return text
        }
        if let message = event.data?["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    private func fallbackUserPrompt(for event: WebhookEvent) -> String? {
        guard event.source == "codex", event.event == .userPrompt else { return nil }
        return codexPromptLookup(event.sessionId)
    }

    /// Extract a human-readable message from a webhook event
    private static func extractMessage(from event: WebhookEvent) -> String? {
        let data = event.data
        switch event.event {
        case .toolUseStart:
            if let toolName = data?["tool_name"] as? String {
                let toolInput = data?["tool_input"] as? [String: Any] ?? [:]
                return ActivityEventExtractor.summary(toolName: toolName, toolInput: toolInput)
            }
            return nil
        case .toolUseEnd:
            if let toolName = data?["tool_name"] as? String {
                let toolInput = data?["tool_input"] as? [String: Any] ?? [:]
                return ActivityEventExtractor.summary(toolName: toolName, toolInput: toolInput)
            }
            return nil
        case .agentStop:
            let reason = (data?["stop_reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch reason {
            case nil, "", "done", "completed", "complete", "success", "succeeded":
                return "Task completed"
            case "cancelled", "canceled":
                return "Task cancelled"
            default:
                return "Stopped"
            }
        case .error:
            let message = data?["message"] as? String ?? "Error occurred"
            return message
        case .prompt:
            let message = data?["message"] as? String ?? "Waiting for input"
            return message
        case .notification:
            if let message = data?["message"] as? String {
                return message
            }
            if let title = data?["title"] as? String {
                return title
            }
            return nil
        case .sessionStart:
            return "Session started"
        case .worktreeCreate:
            return "Creating worktree"
        case .userPrompt:
            return "Processing prompt"
        case .toolUseFailed:
            if let toolName = data?["tool_name"] as? String {
                let toolInput = data?["tool_input"] as? [String: Any] ?? [:]
                return ActivityEventExtractor.summary(toolName: toolName, toolInput: toolInput, isError: true)
            }
            return "Tool failed"
        case .stopFailure:
            return data?["error"] as? String ?? "API error"
        case .subagentStart:
            return "Subagent started"
        case .subagentStop:
            return nil
        case .cwdChanged:
            return nil
        case .suggest:
            return nil
        }
    }

    /// Parse TaskCreate/TaskUpdate from PostToolUse events and update session task list
    private static func applyTaskEvent(_ event: WebhookEvent, to session: inout SessionState) {
        // agentStop clears task list
        if event.event == .agentStop {
            session.tasks.removeAll()
            session.nextTaskId = 1
            return
        }

        guard event.event == .toolUseEnd,
              let toolName = event.data?["tool_name"] as? String,
              let toolInput = event.data?["tool_input"] as? [String: Any] else { return }

        switch toolName {
        case "TaskCreate":
            guard let subject = toolInput["subject"] as? String else { return }
            let id = String(session.nextTaskId)
            session.nextTaskId += 1
            session.tasks.append(TaskItem(id: id, subject: subject, status: .pending))

        case "TaskUpdate":
            guard let taskId = toolInput["taskId"] as? String else { return }
            if let statusStr = toolInput["status"] as? String,
               let newStatus = TaskItemStatus(rawValue: statusStr) {
                if let idx = session.tasks.firstIndex(where: { $0.id == taskId }) {
                    session.tasks[idx].status = newStatus
                }
            }

        default:
            break
        }
    }

    /// Returns tasks from the most recent session for a worktree
    func tasks(for worktreePath: String) -> [TaskItem] {
        queue.sync {
            let canon = canonicalize(worktreePath)
            return sessions.values
                .filter { $0.worktreePath == canon }
                .max(by: { $0.lastEvent < $1.lastEvent })?
                .tasks ?? []
        }
    }

    /// Thread-safe check from outside the queue (e.g. main thread delayed dispatch)
    func matchWorktreeSync(_ canonCwd: String) -> String? {
        queue.sync { matchWorktree(canonCwd) }
    }

    private func matchWorktree(_ canonCwd: String) -> String? {
        // Exact match first
        if knownWorktrees.contains(canonCwd) {
            return canonCwd
        }
        // Prefix match (agent in subdirectory)
        for worktree in knownWorktrees {
            if canonCwd.hasPrefix(worktree + "/") {
                return worktree
            }
        }
        return nil
    }

    private func canonicalize(_ path: String) -> String {
        // Resolve symlinks (e.g. /var → /private/var on macOS) so that
        // worktree paths and webhook cwd values match reliably.
        let resolved = (path as NSString).resolvingSymlinksInPath
        var cleaned = resolved
        while cleaned.hasSuffix("/") && cleaned.count > 1 {
            cleaned = String(cleaned.dropLast())
        }
        return cleaned
    }
}
