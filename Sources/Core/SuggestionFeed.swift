import Foundation

struct SuggestionItem: Equatable, Identifiable {
    let id: String          // == worktreePath
    let worktreePath: String
    let branch: String
    let terminalID: String
    let options: [String]
    /// Monotonically increasing; higher = newer.
    let seq: Int
}

/// Per-agent live suggestion chips, newest-first. Main-thread only.
/// Mirrors WatchFeed's shape so the Bridge panel can observe it the same way.
final class SuggestionFeed {
    private var items: [SuggestionItem] = []
    private var counter = 0
    var onChange: (() -> Void)?

    func set(worktreePath: String, branch: String, terminalID: String, options: [String]) {
        if options.isEmpty {
            clear(worktreePath: worktreePath)
            return
        }
        if let existing = items.first(where: { $0.id == worktreePath }), existing.options == options {
            return // no change
        }
        counter += 1
        let item = SuggestionItem(id: worktreePath, worktreePath: worktreePath, branch: branch,
                                  terminalID: terminalID, options: options, seq: counter)
        if let idx = items.firstIndex(where: { $0.id == worktreePath }) {
            items[idx] = item
        } else {
            items.append(item)
        }
        onChange?()
    }

    func all() -> [SuggestionItem] {
        items.sorted { $0.seq > $1.seq }
    }

    func clear(worktreePath: String) {
        let before = items.count
        items.removeAll { $0.id == worktreePath }
        if items.count != before { onChange?() }
    }
}
