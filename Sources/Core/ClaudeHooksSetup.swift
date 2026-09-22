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
    private static func hookEntry() -> [String: Any] {
        [
            "type": "command",
            "command": "\(SeahelmHookInstaller.scriptPath()) claude-code",
        ]
    }

    private static let requiredEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "Stop",
        "StopFailure",
        "SubagentStart",
        "SubagentStop",
        "Notification",
        "CwdChanged",
    ]

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
        HookEventMerge.canonical(a) == HookEventMerge.canonical(b)
    }

    /// Pure merge: given the hooks already in settings.json, return what they
    /// should become and whether anything moved. Split out from the file I/O so
    /// the install/migrate/retire rules can be tested without writing to the
    /// user's real ~/.claude/settings.json.
    static func reconcile(existingHooks: [String: Any]) -> (hooks: [String: Any], changed: Bool) {
        var hooks = existingHooks
        var changed = false
        let entry = hookEntry()

        for event in requiredEvents {
            // A present-but-unreadable value is the user's to fix; clobbering
            // their settings.json is worse than not reporting one event.
            if hooks[event] != nil, hooks[event] as? [[String: Any]] == nil {
                NSLog("[ClaudeHooksSetup] Skipping \(event): unrecognised shape in settings.json")
                continue
            }
            // Ours goes in beside whatever else the event holds, and migrates in
            // place if it is an older form — see `HookEventMerge` for why this is
            // not "install only when the event is ours or absent".
            let groups = hooks[event] as? [[String: Any]] ?? []
            if let merged = HookEventMerge.merging(event: groups, entry: entry) {
                hooks[event] = merged
                changed = true
                NSLog("[ClaudeHooksSetup] Set hook: \(event)")
            }
        }

        // Dropping an event from `requiredEvents` is not enough — the merge above
        // only ever adds, so an entry we wrote in an earlier version stays on
        // disk forever. Sweep ours out, and only ours: a hook the user wrote
        // themselves for the same event is theirs to keep, including when it
        // sits in the same event as ours.
        for event in retiredHooks {
            guard let groups = hooks[event] as? [[String: Any]],
                  let remaining = HookEventMerge.removing(event: groups) else {
                if hooks[event] != nil {
                    NSLog("[ClaudeHooksSetup] Leaving user-owned hook in place: \(event)")
                }
                continue
            }
            if remaining.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = remaining
            }
            changed = true
            NSLog("[ClaudeHooksSetup] Removed retired hook: \(event)")
        }

        return (hooks, changed)
    }

    /// Check and patch ~/.claude/settings.json on app launch.
    ///
    /// Returns whether Claude ends up configured — true when it already was,
    /// false only when a write that was needed failed. Not "was it modified":
    /// `OnboardingHookInstaller` shows this as the wizard's `ok:` tick, so
    /// reporting "unchanged" as failure made an already-working install look
    /// broken to the user.
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

        guard changed else { return true }   // already says what it should

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
