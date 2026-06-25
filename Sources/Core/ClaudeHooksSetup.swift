import Foundation

/// Ensures ~/.claude/settings.json contains the hooks seahelm needs.
/// Merges non-destructively: existing hooks and settings are preserved.
enum ClaudeHooksSetup {

    /// Hook events seahelm requires, mapped to their webhook config.
    /// Add new hooks here as seahelm gains features.
    private static func requiredHooks(port: UInt16) -> [String: [[String: Any]]] {
        let hookEntry: [String: Any] = ["type": "http", "url": "http://localhost:\(port)/webhook"]
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

    /// Check and patch ~/.claude/settings.json on app launch.
    /// Returns true if the file was modified.
    @discardableResult
    static func ensureHooksConfigured(port: UInt16 = 7070) -> Bool {
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
        let required = requiredHooks(port: port)
        var changed = false

        for (event, config) in required {
            if hooks[event] == nil {
                hooks[event] = config
                changed = true
                NSLog("[ClaudeHooksSetup] Added missing hook: \(event)")
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
