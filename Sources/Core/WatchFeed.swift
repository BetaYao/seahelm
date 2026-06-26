import Foundation

struct WatchItem: Equatable, Identifiable {
    let id: String
    let kind: FirstMateActionKind
    let worktreePath: String
    let branch: String
    let message: String
    /// Monotonically increasing; higher = newer.
    let seq: Int
}

/// Green-zone watch store: recent watchWaiting/watchError items, newest-first.
/// Main-thread only.
final class WatchFeed {
    private var items: [WatchItem] = []
    private var counter = 0

    /// Multiple surfaces observe the feed (sidebar First Mate tab + Helm cockpit).
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

    func record(_ action: FirstMateAction) {
        let id = "\(action.worktreePath)#\(action.kind)"
        counter += 1
        let item = WatchItem(id: id, kind: action.kind, worktreePath: action.worktreePath,
                             branch: action.branch, message: action.message, seq: counter)
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx] = item
        } else {
            items.append(item)
        }
        // cap at 20 — drop oldest by seq
        if items.count > 20 {
            items.sort { $0.seq < $1.seq }
            items = Array(items.dropFirst(items.count - 20))
        }
        notify()
    }

    func all() -> [WatchItem] {
        items.sorted { $0.seq > $1.seq }
    }

    func clear(id: String) {
        let before = items.count
        items.removeAll { $0.id == id }
        if items.count != before { notify() }
    }
}
