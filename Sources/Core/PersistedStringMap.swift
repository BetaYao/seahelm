import Foundation

/// A thread-safe `[String: String]` map persisted as JSON alongside
/// config.json. Shared implementation for the small per-worktree stores
/// (task descriptions, chosen agent types) that only differ in file name
/// and value semantics.
final class PersistedStringMap {
    private let fileURL: URL
    private let lock = NSLock()
    private var map: [String: String]

    init(fileName: String) {
        fileURL = Config.configDir.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
    }

    subscript(key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }

    func set(_ value: String, forKey key: String) {
        lock.lock()
        map[key] = value
        let snapshot = map
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ snapshot: [String: String]) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: self.fileURL, options: .atomic)
            } catch {
                NSLog("PersistedStringMap: failed to persist \(self.fileURL.lastPathComponent): \(error)")
            }
        }
    }
}
