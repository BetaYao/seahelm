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
            orders[idx] = order
        } else {
            orders.append(order)
        }
        notify()
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
            $0.action.payload == FirstMateAction.askUserQuestionPayload
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
}
