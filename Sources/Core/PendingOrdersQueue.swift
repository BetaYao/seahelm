import Foundation

struct PendingOrder: Equatable, Identifiable {
    let id: String
    let action: FirstMateAction
}

/// Red-zone pending-orders queue. At most one entry per (worktreePath, kind) — idempotent.
/// Must be used on the main thread.
final class PendingOrdersQueue {
    private(set) var orders: [PendingOrder] = []

    /// Multiple surfaces observe the queue (sidebar First Mate tab + Helm cockpit).
    /// Token-based so a recreated observer can unregister its old closure.
    private var observers: [Int: () -> Void] = [:]
    private var nextToken = 0

    @discardableResult
    func addObserver(_ block: @escaping () -> Void) -> Int {
        let token = nextToken
        nextToken += 1
        observers[token] = block
        return token
    }

    func removeObserver(_ token: Int?) {
        if let token { observers.removeValue(forKey: token) }
    }

    private func notify() { observers.values.forEach { $0() } }

    /// Pane-scoped for actions that name a terminal (suggestions and questions come
    /// from one specific pane, and two panes of a worktree must be able to hold a
    /// card each). Worktree- and app-scoped actions (returnToPort, broadcastOrder)
    /// carry no terminalID and keep their worktree-wide key.
    static func key(_ a: FirstMateAction) -> String {
        var base = "\(a.worktreePath)#\(a.kind)"
        if !a.terminalID.isEmpty { base += "#\(a.terminalID)" }
        return a.payload.map { "\(base)#\($0)" } ?? base
    }

    func enqueue(_ action: FirstMateAction) {
        let id = Self.key(action)
        guard !orders.contains(where: { $0.id == id }) else { return }
        orders.append(PendingOrder(id: id, action: action))
        notify()
    }

    /// Replace-on-same-id. Used for suggest orders where a newer suggestion supersedes the older.
    func upsert(_ action: FirstMateAction) {
        let id = Self.key(action)
        let order = PendingOrder(id: id, action: action)
        if let idx = orders.firstIndex(where: { $0.id == id }) {
            guard orders[idx] != order else { return }
            orders.remove(at: idx)
        }
        // Preserve arrival order. Replacing a pane's suggestion is a new arrival,
        // so consumers that show newest-first can move it back to the top.
        orders.append(order)
        notify()
    }

    /// Upgrade a suggest card's summary after late assistant prose arrives
    /// (Cursor `afterAgentResponse` often lands after a Shell-invoked
    /// `seahelm-suggest` already queued the options with tool-chrome as message).
    /// Leaves options untouched; never clobbers a non-junk summary already shown.
    func refreshSuggestMessage(terminalID: String, message: String) {
        let summary = FirstMate.suggestionSummaryText(from: message)
        guard !summary.isEmpty else { return }
        var changed = false
        for i in orders.indices {
            let action = orders[i].action
            guard action.kind == .suggestNextOrder,
                  action.terminalID == terminalID,
                  FirstMate.isJunkSuggestionSummary(action.message) else { continue }
            let updated = FirstMateAction(
                kind: action.kind, zone: action.zone,
                worktreePath: action.worktreePath, branch: action.branch,
                project: action.project, terminalID: action.terminalID,
                message: summary, payload: action.payload,
                options: action.options, followups: action.followups)
            orders[i] = PendingOrder(id: orders[i].id, action: updated)
            changed = true
        }
        if changed { notify() }
    }

    func all() -> [PendingOrder] { orders }

    func resolve(id: String) {
        let before = orders.count
        orders.removeAll { $0.id == id }
        if orders.count != before { notify() }
    }

    /// Remove the pending AskUserQuestion card for the given pane — its agent moved
    /// past the question (it was answered in the TUI), so the card is stale.
    /// Pane-scoped: a sibling pane's unanswered question must survive.
    func resolveQuestion(terminalID: String) {
        let before = orders.count
        orders.removeAll {
            FirstMateAction.isQuestionPayload($0.action.payload)
                && $0.action.terminalID == terminalID
        }
        if orders.count != before { notify() }
    }

    /// Remove the pending suggest order for the given pane. Pane-scoped: typing in
    /// one pane must not clear a sibling pane's suggestions.
    func resolveSuggest(terminalID: String) {
        let before = orders.count
        orders.removeAll { $0.action.kind == .suggestNextOrder && $0.action.terminalID == terminalID }
        if orders.count != before { notify() }
    }

    /// Drop every card belonging to a pane that is gone — closed, or its agent
    /// exited. Until this ran, a suggestion outlived its pane: the card stayed on
    /// screen naming a terminalID that no longer resolves, and tapping one of its
    /// options sent text to a terminal that isn't there.
    ///
    /// Only pane-scoped cards match. `returnToPort` and `broadcastOrder` carry no
    /// terminalID (see `key`) because they belong to the worktree or the whole
    /// app, and must outlive any single pane — the empty-id guard is what keeps
    /// one pane's death from sweeping them away.
    func resolvePane(terminalID: String) {
        guard !terminalID.isEmpty else { return }
        let before = orders.count
        orders.removeAll { $0.action.terminalID == terminalID }
        if orders.count != before { notify() }
    }

    /// Drop every card for a worktree that is gone. Used when a whole worktree is
    /// deleted, which takes all of its panes with it — including the
    /// worktree-scoped cards `resolvePane` deliberately spares.
    func resolveWorktree(path: String) {
        guard !path.isEmpty else { return }
        let before = orders.count
        orders.removeAll { $0.action.worktreePath == path }
        if orders.count != before { notify() }
    }
}
