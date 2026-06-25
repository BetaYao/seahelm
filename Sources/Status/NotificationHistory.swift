import Foundation

struct NotificationEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let workspaceName: String
    let branch: String
    let worktreePath: String
    let status: AgentStatus
    let message: String
    var isRead: Bool
    let paneIndex: Int?  // nil for single-pane worktrees

    init(workspaceName: String = "", branch: String, worktreePath: String, status: AgentStatus, message: String, paneIndex: Int? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.workspaceName = workspaceName
        self.branch = branch
        self.worktreePath = worktreePath
        self.status = status
        self.message = message
        self.isRead = false
        self.paneIndex = paneIndex
    }
}

/// In-app notification history — stores recent agent status change notifications.
class NotificationHistory {
    static let shared = NotificationHistory()
    static let maxEntries = 100

    private(set) var entries: [NotificationEntry] = []

    var unreadCount: Int {
        entries.filter { !$0.isRead }.count
    }

    func add(_ entry: NotificationEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        NotificationCenter.default.post(name: .notificationHistoryDidChange, object: nil)
    }

    func markRead(id: UUID) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].isRead = true
            NotificationCenter.default.post(name: .notificationHistoryDidChange, object: nil)
        }
    }

    func markLatestRead(worktreePath: String, paneIndex: Int?) {
        if let index = entries.firstIndex(where: {
            $0.worktreePath == worktreePath && $0.paneIndex == paneIndex && !$0.isRead
        }) {
            entries[index].isRead = true
            NotificationCenter.default.post(name: .notificationHistoryDidChange, object: nil)
        }
    }

    func markAllRead() {
        for i in entries.indices {
            entries[i].isRead = true
        }
        NotificationCenter.default.post(name: .notificationHistoryDidChange, object: nil)
    }

    func clear() {
        entries.removeAll()
        NotificationCenter.default.post(name: .notificationHistoryDidChange, object: nil)
    }
}

extension Notification.Name {
    static let notificationHistoryDidChange = Notification.Name("notificationHistoryDidChange")
}
