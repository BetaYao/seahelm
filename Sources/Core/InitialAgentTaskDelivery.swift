import Foundation

/// Delivers the worktree's opening brief to a freshly launched agent TUI.
///
/// `zmx run` *types* the launch line into a shell. Embedding the task (or the
/// long `--append-system-prompt` string) there routinely truncates mid-quote and
/// leaves bash stuck in readline — the agent never starts. So the session is
/// spawned with a bare agent binary, and this type sends the task as the first
/// composer message once the agent is at its prompt.
///
/// "At its prompt" has to be observed, not guessed. A brief typed while the
/// agent is still booting is mangled: bytes that arrive before Claude Code reads
/// the terminal are lost, and its startup capture keeps the text but drops
/// control keys — the ctrl+v that attaches an image, and the Return. A brief
/// sent on a timer arrived as a truncated path with no text and was never
/// submitted.
enum InitialAgentTaskDelivery {
    static let initialDelay: TimeInterval = 1.0
    static let retryInterval: TimeInterval = 0.25
    /// Two minutes. The launch sources a login shell's rc files before the agent
    /// even starts, Claude Code with MCP servers takes seconds more, and a
    /// folder-trust dialog waits on the user.
    static let maxAttempts = 480
    /// Readiness must hold on this many consecutive attempts. The launch clears
    /// the screen and then execs the agent, and the process tree can show the
    /// agent a moment before the screen stops showing the shell that launched it.
    static let readyConfirmations = 2

    /// What one look at the new worktree's pane found.
    struct PaneSnapshot {
        let paneId: String
        /// The AI agent the process tree shows running in the pane's session, or
        /// nil before it starts. Not the registry's `agentType`: that is also set
        /// by the agent's name appearing on screen, and the launch line echoed
        /// into the shell names the agent long before it runs.
        let runningAgent: AgentType?
        /// The pane's screen as text; nil when it cannot be read.
        let screen: String?
    }

    typealias PaneLookup = (_ worktreePath: String) -> PaneSnapshot?
    typealias Send = (_ paneId: String, _ text: String, _ agent: AgentType) -> Void

    /// Schedule delivery. Retries until the agent in a pane for `worktreePath`
    /// is ready for input (or `maxAttempts` is exhausted). The live lookup forks
    /// processes, so the default schedule runs off the main thread.
    static func schedule(
        task: String,
        worktreePath: String,
        expectedAgent: AgentType,
        initialDelay: TimeInterval = initialDelay,
        retryInterval: TimeInterval = retryInterval,
        maxAttempts: Int = maxAttempts,
        lookup: @escaping PaneLookup = liveLookup(),
        send: @escaping Send = defaultSend,
        asyncAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = defaultAsyncAfter
    ) {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = expectedAgent // reserved for future per-agent settle timing
        asyncAfter(initialDelay) {
            attempt(
                task: trimmed,
                worktreePath: worktreePath,
                remaining: maxAttempts,
                retryInterval: retryInterval,
                lookup: lookup,
                send: send,
                asyncAfter: asyncAfter
            )
        }
    }

    static func attempt(
        task: String,
        worktreePath: String,
        remaining: Int,
        readyStreak: Int = 0,
        retryInterval: TimeInterval,
        lookup: @escaping PaneLookup,
        send: @escaping Send,
        asyncAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void
    ) {
        var streak = 0
        if let pane = lookup(worktreePath), let agent = pane.runningAgent, isReady(pane) {
            streak = readyStreak + 1
            if streak >= readyConfirmations {
                send(pane.paneId, task, agent)
                return
            }
        }
        guard remaining > 0 else {
            NSLog("[Launch] Timed out delivering initial task to \(worktreePath)")
            return
        }
        asyncAfter(retryInterval) {
            attempt(
                task: task,
                worktreePath: worktreePath,
                remaining: remaining - 1,
                readyStreak: streak,
                retryInterval: retryInterval,
                lookup: lookup,
                send: send,
                asyncAfter: asyncAfter
            )
        }
    }

    /// Whether the agent can take the brief now: it is running, it has drawn
    /// something, and what it drew is not a dialog.
    ///
    /// The launch clears the screen right before exec'ing the agent, and an agent
    /// draws nothing until its input loop is up — Claude Code paints its banner
    /// and prompt in the frame it starts reading keys, fullscreen or not. So text
    /// on screen once the agent is running means its prompt is there.
    ///
    /// A numbered choice with a cursor (Claude's folder-trust prompt) is the
    /// user's to answer: the brief's Return would pick the highlighted option.
    static func isReady(_ pane: PaneSnapshot) -> Bool {
        guard pane.runningAgent?.isAIAgent == true,
              let screen = pane.screen,
              screen.contains(where: { !$0.isWhitespace }) else { return false }
        return ChoiceOptionParser.parse(screen).isEmpty
    }

    // MARK: - Live defaults

    private static let queue = DispatchQueue(label: "seahelm.initial-task-delivery", qos: .userInitiated)

    /// A lookup for one delivery. It probes the process tree only until the agent
    /// shows up — a probe forks `zmx list` — and reads the screen only after.
    static func liveLookup() -> PaneLookup {
        var runningAgent: AgentType?
        return { worktreePath in
            guard let pane = AgentRegistry.shared.panes(forWorktree: worktreePath).first,
                  let station = StationRegistry.shared.station(forId: pane.id) ?? pane.station,
                  let sessionKey = station.paneSessionKey, !sessionKey.isEmpty else { return nil }
            if runningAgent == nil {
                let found = AgentType.fromManifestId(ProcessProbe.probeSession(paneSessionKey: sessionKey).agentId)
                if found.isAIAgent { runningAgent = found }
            }
            guard runningAgent != nil else {
                return PaneSnapshot(paneId: pane.id, runningAgent: nil, screen: nil)
            }
            // A blank viewport reads as nil; with a live surface that is still a
            // screen, just an empty one.
            let screen = station.hasLiveSurface ? (station.readViewportText() ?? "") : station.readBackendText()
            return PaneSnapshot(paneId: pane.id, runningAgent: runningAgent, screen: screen)
        }
    }

    private static func defaultSend(paneId: String, text: String, agent: AgentType) {
        // Fresh worktree briefs must run even when they carry pasted images —
        // unlike Telegram-to-an-existing-pane, nobody is waiting to edit first.
        // The agent is passed along because the registry learns it from a screen
        // scan that can lag the agent's start, and an unknown agent gets its
        // images typed as paths instead of attached.
        DispatchQueue.main.async {
            AgentRegistry.shared.sendCommand(to: paneId, command: text, submitWithAttachments: true, agentType: agent)
        }
    }

    private static func defaultAsyncAfter(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
