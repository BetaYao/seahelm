import Foundation

/// Ensures ~/.claude/settings.json contains the hooks seahelm needs.
/// Merges non-destructively: existing hooks and settings are preserved.
enum ClaudeHooksSetup {

    /// Hook events seahelm requires. Now uses a `command` hook running the
    /// seahelm-hook bridge (socket-primary, HTTP fallback) instead of a direct
    /// `type:"http"` hook — moves reporting onto the fs-scoped control socket.
    ///
    /// The `claude-code` argument tags every payload with its source. Without it
    /// the receiving side has to guess Claude vs Codex from payload keys, and
    /// Claude's own `agent_id`/`agent_type`/`duration_ms` fields make that guess
    /// land on Codex — retyping the pane on every tool call.
    private static func requiredHooks() -> [String: [[String: Any]]] {
        let hookEntry: [String: Any] = [
            "type": "command",
            "command": "\(SeahelmHookInstaller.scriptPath()) claude-code",
        ]
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
        ]
    }

    /// Hook events seahelm used to install and must now actively remove.
    ///
    /// `WorktreeCreate` is not an observation hook: per Claude Code's docs it
    /// "replaces default git behavior", so registering it makes Claude delegate
    /// worktree creation to us and wait for the new path on stdout — and any
    /// non-zero exit aborts creation outright. Our bridge only ever prints Stop
    /// decisions, so Claude got an empty stdout and failed every worktree
    /// create with "hook succeeded but returned no worktree path". All we ever
    /// wanted from it was a "Creating worktree" activity label, which is not
    /// worth breaking `--worktree` for; `CwdChanged` already reports the move
    /// once the new worktree is live.
    private static let retiredHooks = ["WorktreeCreate"]

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

    /// Pure merge: given the hooks already in settings.json, return what they
    /// should become and whether anything moved. Split out from the file I/O so
    /// the install/migrate/retire rules can be tested without writing to the
    /// user's real ~/.claude/settings.json.
    static func reconcile(existingHooks: [String: Any]) -> (hooks: [String: Any], changed: Bool) {
        var hooks = existingHooks
        var changed = false

        for (event, config) in requiredHooks() {
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

        // Dropping an event from `requiredHooks` is not enough — the merge above
        // only ever adds, so an entry we wrote in an earlier version stays on
        // disk forever. Sweep ours out, and only ours: a hook the user wrote
        // themselves for the same event is theirs to keep.
        for event in retiredHooks where hooks[event] != nil {
            guard isSeahelmManaged(hooks[event]) else {
                NSLog("[ClaudeHooksSetup] Leaving user-owned hook in place: \(event)")
                continue
            }
            hooks.removeValue(forKey: event)
            changed = true
            NSLog("[ClaudeHooksSetup] Removed retired hook: \(event)")
        }

        return (hooks, changed)
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

        let existing = settings["hooks"] as? [String: Any] ?? [:]
        let (hooks, changed) = reconcile(existingHooks: existing)

        guard changed else { return false }

        settings["hooks"] = hooks

        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
            NSLog("[ClaudeHooksSetup] Updated ~/.claude/settings.json")
            return true
        } catch {
            NSLog("[ClaudeHooksSetup] Failed to write settings: \(error)")
            return false
        }
    }
}
