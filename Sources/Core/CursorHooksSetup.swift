import Foundation

/// Ensures Cursor's `~/.cursor/hooks.json` forwards agent lifecycle events into
/// seahelm via the seahelm-hook bridge. Merges non-destructively: user-owned
/// entries are preserved (seahelm appends its own alongside), and a stale
/// seahelm-owned command (any path containing "seahelm-hook") is upgraded in
/// place to the current script path.
enum CursorHooksSetup {

    /// Cursor hook events seahelm requires, in Cursor's camelCase naming.
    private static let requiredEvents = [
        "sessionStart",
        "beforeSubmitPrompt",
        "preToolUse",
        "postToolUse",
        "stop",
    ]

    /// Bound on stop-hook re-invocation rounds — Cursor's counterpart to
    /// Claude's `stop_hook_active` guard, so a blocking stop hook can't spin
    /// the agent forever.
    private static let stopLoopLimit = 5

    private static func requiredEntry(event: String) -> [String: Any] {
        var entry: [String: Any] = ["command": SeahelmHookInstaller.scriptPath()]
        if event == "stop" {
            entry["loop_limit"] = stopLoopLimit
        }
        return entry
    }

    /// A hook entry seahelm previously installed — safe to upgrade in place.
    static func isSeahelmManaged(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains("seahelm-hook") == true
    }

    /// Check and patch `~/.cursor/hooks.json` on app launch.
    /// Returns true when the file is in the required state afterwards.
    @discardableResult
    static func ensureHooksConfigured() -> Bool {
        let path = NSString("~/.cursor/hooks.json").expandingTildeInPath
        return ensureHooksJSON(at: URL(fileURLWithPath: path))
    }

    /// Test seam: identical logic against an arbitrary file.
    @discardableResult
    static func ensureHooksJSONForTests(at url: URL) -> Bool {
        ensureHooksJSON(at: url)
    }

    private static func ensureHooksJSON(at url: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root: [String: Any]
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        } else {
            root = [:]
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        if root["version"] as? Int != 1 {
            root["version"] = 1
            changed = true
        }

        for event in requiredEvents {
            let required = requiredEntry(event: event)
            var list = hooks[event] as? [[String: Any]] ?? []
            if let idx = list.firstIndex(where: isSeahelmManaged) {
                if !NSDictionary(dictionary: list[idx]).isEqual(to: required) {
                    list[idx] = required
                    changed = true
                }
            } else {
                list.append(required)
                changed = true
            }
            hooks[event] = list
        }

        guard changed else { return true }
        root["hooks"] = hooks

        do {
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            NSLog("[CursorHooksSetup] Updated \(url.path)")
            return true
        } catch {
            NSLog("[CursorHooksSetup] Failed to write hooks.json: \(error)")
            return false
        }
    }
}
