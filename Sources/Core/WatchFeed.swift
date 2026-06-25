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
    var onChange: (() -> Void)?

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
        onChange?()
    }

    func all() -> [WatchItem] {
        items.sorted { $0.seq > $1.seq }
    }

    func clear(id: String) {
        let before = items.count
        items.removeAll { $0.id == id }
        if items.count != before { onChange?() }
    }
}
