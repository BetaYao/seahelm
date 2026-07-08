import Foundation

/// Ensures ~/.claude/settings.json contains the hooks seahelm needs.
/// Merges non-destructively: existing hooks and settings are preserved.
enum ClaudeHooksSetup {

    /// Hook events seahelm requires. Now uses a `command` hook running the
    /// seahelm-hook bridge (socket-primary, HTTP fallback) instead of a direct
    /// `type:"http"` hook — moves reporting onto the fs-scoped control socket.
    private static func requiredHooks() -> [String: [[String: Any]]] {
        let hookEntry: [String: Any] = ["type": "command", "command": SeahelmHookInstaller.scriptPath()]
        let hookGroup: [[String: Any]] = [["hooks": [hookEntry]]]
        return [
            "SessionStart": hookGroup,
            "UserPromptSubmit": hookGroup,
            "PreToolUse": hookGroup,
            "PostToolUse": hookGroup,
            "PostToolUseFailure": hookGroup,
            "Stop": hookGroup,
            "StopFailure": hookGroup,
            "SubagentStart": hookGroup,
            "SubagentStop": hookGroup,
            "Notification": hookGroup,
            "CwdChanged": hookGroup,
            "WorktreeCreate": hookGroup,
        ]
    }

    /// True if a hook entry is one seahelm previously installed (an http hook
    /// pointing at our /webhook, or our seahelm-hook command) — safe to migrate.
    static func isSeahelmManaged(_ entry: Any?) -> Bool {
        guard let entry, let data = try? JSONSerialization.data(withJSONObject: entry),
              let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("/webhook") || s.contains("seahelm-hook")
    }

    /// Structural equality of two hook entries via canonical JSON (sorted keys),
    /// so an already-correct config isn't needlessly rewritten.
    static func entriesEqual(_ a: Any?, _ b: Any?) -> Bool {
        func canon(_ v: Any?) -> String? {
            guard let v, let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        return canon(a) == canon(b)
    }

    /// Check and patch ~/.claude/settings.json on app launch.
    /// Returns true if the file was modified.
    @discardableResult
    static func ensureHooksConfigured() -> Bool {
        let settingsPath = NSString("~/.claude/settings.json").expandingTildeInPath
        let settingsURL = URL(fileURLWithPath: settingsPath)

        // Ensure ~/.claude/ directory exists
        let dirURL = settingsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        // Load existing settings or start fresh
        var settings: [String: Any]
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        } else {
            settings = [:]
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let required = requiredHooks()
        var changed = false

        for (event, config) in required {
            // Install when missing, or migrate a seahelm-managed entry (old
            // http→/webhook or a stale seahelm-hook command) to the current
            // config. A user's own unrelated hook for this event is left alone.
            if hooks[event] == nil || isSeahelmManaged(hooks[event]) {
                if !entriesEqual(hooks[event], config) {
                    hooks[event] = config
                    changed = true
                    NSLog("[ClaudeHooksSetup] Set hook: \(event)")
                }
            }
        }

        guard changed else { return false }

        settings["hooks"] = hooks

        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
            NSLog("[ClaudeHooksSetup] Updated ~/.claude/settings.json with \(required.count) hooks")
            return true
        } catch {
            NSLog("[ClaudeHooksSetup] Failed to write settings: \(error)")
            return false
        }
    }
}
