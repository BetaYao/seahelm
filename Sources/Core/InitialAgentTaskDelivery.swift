import Foundation

/// Delivers the worktree's opening brief to a freshly launched agent TUI.
///
/// `zmx run` *types* the launch line into a shell. Embedding the task (or the
/// long `--append-system-prompt` string) there routinely truncates mid-quote and
/// leaves bash stuck in readline — the agent never starts. So the session is
/// spawned with a bare agent binary, and this type sends the task as the first
/// composer message once a pane can accept input.
enum InitialAgentTaskDelivery {
    static let initialDelay: TimeInterval = 1.0
    static let retryInterval: TimeInterval = 0.25
    static let maxAttempts = 60
    /// After this many retries (~5s), send even if status scan has not yet
    /// named the agent — the TUI is usually already accepting input.
    static let agentDetectGraceAttempts = 20

    typealias PaneLookup = (_ worktreePath: String) -> (paneId: String, canDeliver: Bool, agentReady: Bool)?
    typealias Send = (_ paneId: String, _ text: String) -> Void

    /// Schedule delivery on the main queue. Retries until a pane for
    /// `worktreePath` can take input (or `maxAttempts` is exhausted).
    static func schedule(
        task: String,
        worktreePath: String,
        expectedAgent: AgentType,
        initialDelay: TimeInterval = initialDelay,
        retryInterval: TimeInterval = retryInterval,
        maxAttempts: Int = maxAttempts,
        lookup: @escaping PaneLookup = defaultLookup,
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
                maxAttempts: maxAttempts,
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
        maxAttempts: Int,
        retryInterval: TimeInterval,
        lookup: @escaping PaneLookup,
        send: @escaping Send,
        asyncAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void
    ) {
        let attemptsUsed = maxAttempts - remaining
        if let pane = lookup(worktreePath) {
            let agentOk = pane.agentReady || attemptsUsed >= agentDetectGraceAttempts
            if pane.canDeliver && agentOk {
                send(pane.paneId, task)
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
                maxAttempts: maxAttempts,
                retryInterval: retryInterval,
                lookup: lookup,
                send: send,
                asyncAfter: asyncAfter
            )
        }
    }

    // MARK: - Live defaults

    private static func defaultLookup(worktreePath: String) -> (paneId: String, canDeliver: Bool, agentReady: Bool)? {
        guard let pane = AgentRegistry.shared.panes(forWorktree: worktreePath).first else { return nil }
        let station = StationRegistry.shared.station(forId: pane.id) ?? pane.station
        let sessionKey = station?.paneSessionKey ?? ""
        let canDeliver = station?.canDeliverInput == true || !sessionKey.isEmpty
        let agentReady = pane.agentType.isAIAgent
        return (pane.id, canDeliver, agentReady)
    }

    private static func defaultSend(paneId: String, text: String) {
        // Fresh worktree briefs must run even when they carry pasted images —
        // unlike Telegram-to-an-existing-pane, nobody is waiting to edit first.
        AgentRegistry.shared.sendCommand(to: paneId, command: text, submitWithAttachments: true)
    }

    private static func defaultAsyncAfter(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
