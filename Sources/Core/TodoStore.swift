import Foundation

struct TodoItem: Codable, Identifiable {
    let id: String
    var task: String
    var status: String
    var project: String
    var branch: String?
    var issue: String?
    var progress: String?
    let createdAt: Date
    var updatedAt: Date
}

class TodoStore {
    static let shared = TodoStore(directory: Config.configDir)

    private let filePath: URL
    private var items: [TodoItem] = []
    private let saveQueue = DispatchQueue(label: "com.seahelm.todo-save", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    init(directory: URL) {
        self.filePath = directory.appendingPathComponent("todos.json")
    }

    func load() {
        guard FileManager.default.fileExists(atPath: filePath.path) else { return }
        do {
            let data = try Data(contentsOf: filePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([TodoItem].self, from: data)
        } catch {
            NSLog("[TodoStore] Failed to load: \(error)")
        }
    }

    func save() {
        let snapshot = items
        pendingSave?.cancel()
        let work = DispatchWorkItem {
            self.write(snapshot)
        }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func saveSync() {
        write(items)
    }

    private func write(_ snapshot: [TodoItem]) {
        do {
            try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: filePath, options: .atomic)
        } catch {
            NSLog("[TodoStore] Failed to save: \(error)")
        }
    }

    @discardableResult
    func add(task: String, project: String, branch: String?, issue: String?) -> TodoItem {
        let now = Date()
        let item = TodoItem(
            id: UUID().uuidString,
            task: task,
            status: "pending_approval",
            project: project,
            branch: branch,
            issue: issue,
            progress: nil,
            createdAt: now,
            updatedAt: now
        )
        items.append(item)
        save()
        return item
    }

    func update(id: String, status: String?, progress: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let status { items[idx].status = status }
        if let progress { items[idx].progress = progress }
        items[idx].updatedAt = Date()
        save()
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    func allItems() -> [TodoItem] {
        items
    }
}
