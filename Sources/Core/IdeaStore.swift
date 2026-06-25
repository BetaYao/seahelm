import Foundation

struct IdeaItem: Codable, Identifiable {
    let id: String
    var text: String
    var project: String
    var source: String
    var tags: [String]
    let createdAt: Date
}

class IdeaStore {
    static let shared = IdeaStore(directory: Config.configDir)

    private let filePath: URL
    private var items: [IdeaItem] = []
    private let saveQueue = DispatchQueue(label: "com.seahelm.idea-save", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    init(directory: URL) {
        self.filePath = directory.appendingPathComponent("ideas.json")
    }

    func load() {
        guard FileManager.default.fileExists(atPath: filePath.path) else { return }
        do {
            let data = try Data(contentsOf: filePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([IdeaItem].self, from: data)
        } catch {
            NSLog("[IdeaStore] Failed to load: \(error)")
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

    private func write(_ snapshot: [IdeaItem]) {
        do {
            try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: filePath, options: .atomic)
        } catch {
            NSLog("[IdeaStore] Failed to save: \(error)")
        }
    }

    @discardableResult
    func add(text: String, project: String, source: String, tags: [String]) -> IdeaItem {
        let item = IdeaItem(
            id: UUID().uuidString,
            text: text,
            project: project,
            source: source,
            tags: tags,
            createdAt: Date()
        )
        items.append(item)
        save()
        return item
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    func allItems() -> [IdeaItem] {
        items
    }
}
