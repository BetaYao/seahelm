import Foundation

/// Resumable long-poll state for one WeChat account.
struct WeChatSessionState: Codable, Equatable {
    /// Cursor handed back to getupdates so a restart resumes where we left off.
    var syncBuf: String
    /// context_token per user — sendmessage rejects replies without one.
    var contextTokens: [String: String]

    static let empty = WeChatSessionState(syncBuf: "", contextTokens: [:])

    enum CodingKeys: String, CodingKey {
        case syncBuf = "sync_buf"
        case contextTokens = "context_tokens"
    }
}

/// Persists WeChat long-poll state, keyed by account.
///
/// Deliberately kept out of `config.json`: this churns on every message, while
/// `Config.save()` writes the whole struct from an in-memory copy. Sharing that
/// file would let any component holding a stale `Config` silently wipe the
/// cursor on its next unrelated save.
enum WeChatSessionStore {
    private static let path = Config.configDir.appendingPathComponent("wechat-state.json")
    private static let queue = DispatchQueue(label: "com.seahelm.wechat-state", qos: .utility)
    private static var pendingSaves: [String: DispatchWorkItem] = [:]
    private static let saveDebounceSec: TimeInterval = 1.0

    static func load(accountId: String) -> WeChatSessionState {
        queue.sync {
            readAll()[accountId] ?? .empty
        }
    }

    /// Debounced per account — a burst of messages collapses into one write.
    static func save(_ state: WeChatSessionState, accountId: String) {
        queue.async {
            pendingSaves[accountId]?.cancel()
            let workItem = DispatchWorkItem {
                var all = readAll()
                all[accountId] = state
                writeAll(all)
                queue.async { pendingSaves[accountId] = nil }
            }
            pendingSaves[accountId] = workItem
            queue.asyncAfter(deadline: .now() + saveDebounceSec, execute: workItem)
        }
    }

    static func clear(accountId: String) {
        queue.async {
            pendingSaves[accountId]?.cancel()
            pendingSaves[accountId] = nil
            var all = readAll()
            guard all.removeValue(forKey: accountId) != nil else { return }
            writeAll(all)
        }
    }

    // MARK: - Disk

    /// Must be called on `queue`.
    private static func readAll() -> [String: WeChatSessionState] {
        guard let data = try? Data(contentsOf: path) else { return [:] }
        return (try? JSONDecoder().decode([String: WeChatSessionState].self, from: data)) ?? [:]
    }

    /// Must be called on `queue`.
    private static func writeAll(_ all: [String: WeChatSessionState]) {
        do {
            try FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(all).write(to: path, options: .atomic)
        } catch {
            NSLog("[WeChat] Failed to save session state: \(error)")
        }
    }
}
