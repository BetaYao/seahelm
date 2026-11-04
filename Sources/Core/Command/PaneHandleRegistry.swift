import Foundation

/// The stable `#n` every pane carries.
///
/// A handle is minted the first time a pane is seen and never reused, so `#7`
/// means the same pane on the desktop card, in a `/status` listing and in a
/// message typed on a phone a week later. That is the whole reason it exists:
/// the positional codes it replaces shifted every time the fleet changed, and
/// a listing's "2." was a different pane on the desktop than in chat.
///
/// Keyed by the pane's persistent session name (`SEAHELM_PANE_ID`), which is
/// what survives a relaunch. A local (non-seahelmd) pane has none and is keyed by
/// its station id instead — stable within one run, which is all such a pane
/// lives for anyway.
final class PaneHandleRegistry {
    static let shared = PaneHandleRegistry()

    private struct Persisted: Codable {
        var next: Int
        var handles: [String: Int]
    }

    private let url: URL
    private let lock = NSLock()
    private var handles: [String: Int] = [:]
    private var next = 1

    init(url: URL = Config.configDir.appendingPathComponent("pane-handles.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Persisted.self, from: data) {
            handles = stored.handles
            next = max(stored.next, (stored.handles.values.max() ?? 0) + 1)
        }
    }

    /// The registry key for a pane: its session name, or `local:<id>`.
    static func key(sessionKey: String, paneId: String) -> String {
        sessionKey.isEmpty ? "local:\(paneId)" : sessionKey
    }

    /// The pane's handle, minting one on first sight.
    func handle(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let existing = handles[key] { return existing }
        let minted = next
        next += 1
        handles[key] = minted
        persistLocked()
        return minted
    }

    func existingHandle(for key: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return handles[key]
    }

    func key(for handle: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return handles.first { $0.value == handle }?.key
    }

    /// Take the core's handles (`pane.list`): seahelm-core numbers the panes
    /// for every surface, and a chat that says `#7` must mean the pane the
    /// desktop card calls #7. A number the core gives another pane is taken
    /// from whichever pane here held it; that pane gets the core's number once
    /// the core knows it, or a fresh one above every number in use.
    func adopt(_ core: [String: Int]) {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for (key, handle) in core where handles[key] != handle {
            for (other, h) in handles where h == handle && other != key {
                handles.removeValue(forKey: other)
            }
            handles[key] = handle
            changed = true
        }
        let floor = (handles.values.max() ?? 0) + 1
        if next < floor {
            next = floor
            changed = true
        }
        if changed { persistLocked() }
    }

    private func persistLocked() {
        let stored = Persisted(next: next, handles: handles)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
