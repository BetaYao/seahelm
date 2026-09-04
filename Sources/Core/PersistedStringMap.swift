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

    /// Snapshot of the stored values. Callers that ask on every render need an
    /// in-memory answer, not a file read.
    var values: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(map.values)
    }

    /// Snapshot of the whole map, for the callers that need the keys too.
    var entries: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return map
    }

    /// Drop a key. Worktree paths get reused — a stale entry left behind by a
    /// deleted worktree would answer for whatever is created at that path next.
    func remove(forKey key: String) {
        lock.lock()
        guard map.removeValue(forKey: key) != nil else { lock.unlock(); return }
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
