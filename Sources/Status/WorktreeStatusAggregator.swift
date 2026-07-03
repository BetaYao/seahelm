import Foundation

protocol WorktreeStatusDelegate: AnyObject {
    func worktreeStatusDidUpdate(_ status: WorktreeStatus)
    func paneStatusDidChange(worktreePath: String, paneIndex: Int,
                             oldStatus: SailorStatus, newStatus: SailorStatus,
                             lastMessage: String)
}

/// Thread safety: All methods must be called on the main queue.
/// StatusPublisher dispatches to main before calling agentDidUpdate.
class WorktreeStatusAggregator {
    weak var delegate: WorktreeStatusDelegate?

    private var worktreeStatuses: [String: WorktreeStatus] = [:]
    private var paneStates: [String: PaneStatus] = [:]
    private var terminalToWorktree: [String: String] = [:]
    private var worktreeTerminals: [String: [String]] = [:]

    /// Per-worktree "last real activity" time. Seeded from persisted config so
    /// it does NOT reset to launch time, and only advanced on genuine status/
    /// message changes (not on the initial post-launch detection of a pane).
    private var lastActivityAt: [String: Date] = [:]
    /// Fired when a worktree's last-activity time advances, so the owner can persist it.
    var onActivity: ((String, Date) -> Void)?

    /// Seed persisted last-activity times. Only fills entries we don't already have.
    func seedLastActivity(_ map: [String: Date]) {
        for (path, date) in map where lastActivityAt[path] == nil {
            lastActivityAt[path] = date
        }
    }

    func lastActivity(for worktreePath: String) -> Date? {
        lastActivityAt[worktreePath]
    }

    func registerTerminal(_ terminalID: String, worktreePath: String, leafIndex: Int) {
        terminalToWorktree[terminalID] = worktreePath
        var ids = worktreeTerminals[worktreePath] ?? []
        if !ids.contains(terminalID) {
            if leafIndex < ids.count {
                ids.insert(terminalID, at: leafIndex)
            } else {
                ids.append(terminalID)
            }
        }
        worktreeTerminals[worktreePath] = ids
    }

    func unregisterTerminal(_ terminalID: String, worktreePath: String) {
        terminalToWorktree.removeValue(forKey: terminalID)
        worktreeTerminals[worktreePath]?.removeAll { $0 == terminalID }
        paneStates.removeValue(forKey: terminalID)
        if worktreeTerminals[worktreePath]?.isEmpty == true {
            worktreeTerminals.removeValue(forKey: worktreePath)
            worktreeStatuses.removeValue(forKey: worktreePath)
        }
    }

    func updateLeafOrder(worktreePath: String, terminalIDs: [String]) {
        worktreeTerminals[worktreePath] = terminalIDs
        rebuildWorktreeStatus(worktreePath: worktreePath)
    }

    func agentDidUpdate(terminalID: String, status: SailorStatus, lastMessage: String, lastUserPrompt: String = "") {
        guard let worktreePath = terminalToWorktree[terminalID] else { return }

        let now = Date()
        let oldPaneState = paneStates[terminalID]
        let statusChanged = oldPaneState?.status != status
        let messageChanged = oldPaneState?.lastMessage != lastMessage
        let promptChanged = oldPaneState?.lastUserPrompt != lastUserPrompt

        guard statusChanged || messageChanged || promptChanged else { return }

        // Advance the worktree's last-activity time. A first-ever detection of a
        // pane (oldPaneState == nil) is launch/restore noise — keep any seeded/
        // persisted value, only stamping now when there is no history at all.
        if oldPaneState != nil || lastActivityAt[worktreePath] == nil {
            lastActivityAt[worktreePath] = now
            onActivity?(worktreePath, now)
        }

        let paneIndex = paneIndexForTerminal(terminalID, worktreePath: worktreePath)
        // Preserve existing prompt if new one is empty
        let effectivePrompt = lastUserPrompt.isEmpty ? (oldPaneState?.lastUserPrompt ?? "") : lastUserPrompt
        let newPaneState = PaneStatus(
            paneIndex: paneIndex,
            terminalID: terminalID,
            status: status,
            lastMessage: lastMessage,
            lastUserPrompt: effectivePrompt,
            lastUpdated: now
        )
        paneStates[terminalID] = newPaneState

        if statusChanged, let oldStatus = oldPaneState?.status {
            delegate?.paneStatusDidChange(
                worktreePath: worktreePath,
                paneIndex: paneIndex,
                oldStatus: oldStatus,
                newStatus: status,
                lastMessage: lastMessage
            )
        }

        rebuildWorktreeStatus(worktreePath: worktreePath)
    }

    func status(for worktreePath: String) -> WorktreeStatus? {
        worktreeStatuses[worktreePath]
    }

    private func paneIndexForTerminal(_ terminalID: String, worktreePath: String) -> Int {
        let ids = worktreeTerminals[worktreePath] ?? []
        let index = ids.firstIndex(of: terminalID) ?? 0
        return index + 1
    }

    private func rebuildWorktreeStatus(worktreePath: String) {
        guard let terminalIDs = worktreeTerminals[worktreePath], !terminalIDs.isEmpty else { return }

        var panes: [PaneStatus] = []
        for (index, tid) in terminalIDs.enumerated() {
            if var pane = paneStates[tid] {
                pane = PaneStatus(
                    paneIndex: index + 1,
                    terminalID: pane.terminalID,
                    status: pane.status,
                    lastMessage: pane.lastMessage,
                    lastUserPrompt: pane.lastUserPrompt,
                    lastUpdated: pane.lastUpdated
                )
                paneStates[tid] = pane
                panes.append(pane)
            }
        }

        guard !panes.isEmpty else { return }

        let mostRecent = panes.max(by: { $0.lastUpdated < $1.lastUpdated }) ?? panes[0]

        let ws = WorktreeStatus(
            worktreePath: worktreePath,
            panes: panes,
            mostRecentPaneIndex: mostRecent.paneIndex,
            mostRecentMessage: mostRecent.lastMessage,
            mostRecentUserPrompt: mostRecent.lastUserPrompt
        )
        // Skip the delegate (and the UI refresh chain behind it) when nothing
        // visible actually changed — e.g. a poll that re-detected the same state.
        let unchanged = worktreeStatuses[worktreePath] == ws
        worktreeStatuses[worktreePath] = ws
        guard !unchanged else { return }
        delegate?.worktreeStatusDidUpdate(ws)
    }
}
