import Foundation

struct NotificationEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let workspaceName: String
    let branch: String
    let worktreePath: String
    let status: SailorStatus
    let message: String
    var isRead: Bool
    let paneIndex: Int?  // nil for single-pane worktrees

    init(workspaceName: String = "", branch: String, worktreePath: String, status: SailorStatus, message: String, paneIndex: Int? = nil) {
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
///
/// Persistence mirrors the other JSON stores (`TodoStore`/`IdeaStore`): a
/// debounced, atomic write on a background queue. `load()` must be called
/// explicitly at startup (see `AppDelegate`), so the shared instance never
/// reads the disk mid-construction. Pass `directory: nil` for an in-memory-only
/// instance (used by tests so they never touch the user's real config).
final class NotificationHistory {
    static let shared = NotificationHistory(directory: Config.configDir)
    static let maxEntries = 100

    private(set) var entries: [NotificationEntry] = []

    private let filePath: URL?
    private let saveQueue = DispatchQueue(label: "com.seahelm.notification-history-save", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    init(directory: URL?) {
        self.filePath = directory?.appendingPathComponent("notifications.json")
    }

    var unreadCount: Int {
        entries.filter { !$0.isRead }.count
    }

    func load() {
        guard let filePath, FileManager.default.fileExists(atPath: filePath.path) else { return }
        do {
            let data = try Data(contentsOf: filePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([NotificationEntry].self, from: data)
            if entries.count > Self.maxEntries {
                entries.removeLast(entries.count - Self.maxEntries)
            }
            NotificationCenter.default.post(name: .notificationHistoryDidChange, object: nil)
        } catch {
            NSLog("[NotificationHistory] Failed to load: \(error)")
        }
    }

    func add(_ entry: NotificationEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        didMutate()
    }

    func markRead(id: UUID) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].isRead = true
            didMutate()
        }
    }

    func markLatestRead(worktreePath: String, paneIndex: Int?) {
        if let index = entries.firstIndex(where: {
            $0.worktreePath == worktreePath && $0.paneIndex == paneIndex && !$0.isRead
        }) {
            entries[index].isRead = true
            didMutate()
        }
    }

    func markAllRead() {
        for i in entries.indices {
            entries[i].isRead = true
        }
        didMutate()
    }

    func clear() {
        entries.removeAll()
        didMutate()
    }

    private func didMutate() {
        NotificationCenter.default.post(name: .notificationHistoryDidChange, object: nil)
        save()
    }

    private func save() {
        guard let filePath else { return }
        let snapshot = entries
        pendingSave?.cancel()
        let work = DispatchWorkItem { Self.write(snapshot, to: filePath) }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private static func write(_ snapshot: [NotificationEntry], to filePath: URL) {
        do {
            try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: filePath, options: .atomic)
        } catch {
            NSLog("[NotificationHistory] Failed to save: \(error)")
        }
    }
}

extension Notification.Name {
    static let notificationHistoryDidChange = Notification.Name("notificationHistoryDidChange")
}
