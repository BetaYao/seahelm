import Foundation

class WebhookStatusProvider {
    private let queue = DispatchQueue(label: "seahelm.webhook-status")
    private var sessions: [String: SessionState] = [:]
    private var knownWorktrees: [String] = []
    var onStatusChanged: ((String) -> Void)?
    var codexPromptLookup: (String) -> String? = { sessionId in
        CodexSessionPromptLookup.lastUserPrompt(sessionId: sessionId)
    }

    /// Called (on main) when an agent's cwd names a worktree we do not track yet.
    /// `paneId` is the emitting pane's session name (SEAHELM_PANE_ID), so the owner
    /// can move that exact pane into the worktree once it is integrated instead of
    /// standing up an empty one beside it — nil when the hook carried none.
    var onNewWorktreeDetected: ((_ worktreePath: String, _ paneId: String?) -> Void)?

    /// Called (on main) when an agent hook event resolves a persistable resume
    /// ref for a known worktree. `paneId` is the emitting pane's session name
    /// (SEAHELM_PANE_ID), so the owner can route the ref to that exact pane —
    /// nil for legacy hooks that predate the export. The owner persists it and
    /// applies it to live stations so the agent can be relaunched after a session
    /// is recreated.
    var onAgentSessionResolved: ((_ worktreePath: String, _ paneId: String?, _ ref: AgentSessionRef) -> Void)?

    /// Memo for "is this path a git worktree root" — see `isWorktreeRoot`.
    private var worktreeRootProbeCache: [String: Bool] = [:]

    /// When we last asked the owner to discover a given path. The cwd check below
    /// runs on *every* hook event, so without this an agent sitting in a worktree
    /// we have not integrated yet would re-trigger discovery on every tool call.
    private var discoveryRequestedAt: [String: Date] = [:]
    private let discoveryRequestInterval: TimeInterval = 15

    struct SessionState {
        let sessionId: String
        let worktreePath: String
        var status: AgentStatus
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

            // An agent that moved into a worktree we do not track yet. Two shapes:
            // the cwd matches nothing at all, or — the case that used to be
            // invisible — it sits *inside* a known worktree while being a worktree
            // root itself, which is exactly where Claude Code's own EnterWorktree
            // puts one (`<repo>/.claude/worktrees/<name>`). Ask the owner to
            // discover it; the pane follows once it is integrated.
            let preMatch = matchWorktree(canonCwd)
            if preMatch == nil || (preMatch != canonCwd && isWorktreeRoot(canonCwd)) {
                requestDiscovery(of: canonCwd, rawCwd: event.cwd, paneId: event.paneId)
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
            // revivals.
            if event.data?["agent_id"] == nil,
               let ref = AgentSessionRef(source: event.source, sessionId: event.sessionId, sessionPath: event.sessionPath) {
                let paneId = event.paneId
                DispatchQueue.main.async { [weak self] in
                    self?.onAgentSessionResolved?(worktreePath, paneId, ref)
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.onStatusChanged?(worktreePath)
            }
        }
    }

    func status(for worktreePath: String) -> AgentStatus {
        queue.sync {
            let canon = canonicalize(worktreePath)
            let sessionStatuses = sessions.values
                .filter { $0.worktreePath == canon }
                .map { $0.status }
            return AgentStatus.highestPriority(sessionStatuses)
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
        case .suggest, .assistantResponse:
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
            // Common case is no webhook sessions at all — skip the path
            // canonicalization (filesystem resolution) the poll would otherwise
            // pay for every changed pane.
            guard !sessions.isEmpty else { return [] }
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
        // Prefix match (agent in a subdirectory). Must be the *longest* match:
        // Claude Code's own worktrees live at `<repo>/.claude/worktrees/<name>`,
        // i.e. nested inside the worktree they were created from, so a first-match
        // scan attributed every event from such a worktree to its parent — the
        // agent's move was invisible no matter which hook reported it.
        var best: String?
        for worktree in knownWorktrees where canonCwd.hasPrefix(worktree + "/") {
            if best == nil || worktree.count > best!.count { best = worktree }
        }
        return best
    }

    /// True when `path` is the root of a git worktree (linked or main): a linked
    /// worktree root holds a `.git` *file*, the main one a `.git` directory.
    ///
    /// Only consulted when an event's cwd sits inside a known worktree but is not
    /// that worktree's root — the case where an agent created a nested worktree we
    /// have not discovered yet. Memoized because it runs on the webhook queue, and
    /// probed with a short timeout so an unresponsive volume cannot wedge it.
    private func isWorktreeRoot(_ path: String) -> Bool {
        if let cached = worktreeRootProbeCache[path] { return cached }
        // A timeout must read as "no", not "yes": `exists` resolves an
        // unresponsive mount as present, and inheriting that here would make
        // every subdirectory an agent visits on a wedged volume look like a new
        // worktree and start moving panes into it. Nor is an unknown memoized —
        // the volume may come back.
        guard let result = FileSystemProbe.existsIfKnown(path + "/.git", timeout: 0.5) else {
            return false
        }
        // Agents wander through plenty of ordinary subdirectories; drop the memo
        // wholesale rather than let it grow for the life of the process.
        if worktreeRootProbeCache.count > 512 { worktreeRootProbeCache.removeAll() }
        worktreeRootProbeCache[path] = result
        return result
    }

    /// Ask the owner to discover `canonPath`, at most once per
    /// `discoveryRequestInterval`. Called on the webhook queue.
    private func requestDiscovery(of canonPath: String, rawCwd: String, paneId: String?) {
        let now = Date()
        if let last = discoveryRequestedAt[canonPath],
           now.timeIntervalSince(last) < discoveryRequestInterval {
            return
        }
        discoveryRequestedAt = discoveryRequestedAt.filter {
            now.timeIntervalSince($0.value) < discoveryRequestInterval
        }
        discoveryRequestedAt[canonPath] = now
        NSLog("[WebhookStatusProvider] Untracked worktree at agent cwd: \(rawCwd) (pane \(paneId ?? "?"))")
        DispatchQueue.main.async { [weak self] in
            self?.onNewWorktreeDetected?(canonPath, paneId)
        }
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
