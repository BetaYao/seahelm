import Foundation

struct PendingOrder: Equatable, Identifiable {
    let id: String
    let action: FirstMateAction
}

/// 红区待批航令队列。同一 (worktreePath, kind) 至多一条(幂等)。
/// 必须在主线程使用。
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

    static func key(_ a: FirstMateAction) -> String {
        let base = "\(a.worktreePath)#\(a.kind)"
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

    /// Remove any pending suggest order for the given worktree path.
    func resolveSuggest(worktreePath: String) {
        let before = orders.count
        orders.removeAll { $0.action.kind == .suggestNextOrder && $0.action.worktreePath == worktreePath }
        if orders.count != before { notify() }
    }
}
