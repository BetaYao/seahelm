import Foundation

/// Chrome-title cue when a pane's agent/shell is not in the worktree the pane
/// is filed under. Auto-rehome used to move the pane; now the pane stays put
/// and the title says so.
enum PaneAwayIndicator {
    /// ` · ~/path` when away, else nil. Hook location (when present) outranks
    /// OSC pwd: agents inside zmx often never report OSC 7.
    static func titleSuffix(
        filedWorktree: String,
        hookWorktree: String?,
        hookCwd: String?,
        hasHookLocation: Bool,
        pwd: String,
        shorten: (String) -> String = PaneTitleResolver.shortenPath
    ) -> String? {
        let filed = canonicalize(filedWorktree)
        guard !filed.isEmpty else { return nil }

        if hasHookLocation {
            if let hook = hookWorktree.map(canonicalize), !hook.isEmpty, hook == filed {
                return nil
            }
            let raw = firstNonEmpty(hookCwd, hookWorktree) ?? ""
            guard !raw.isEmpty else { return nil }
            return " · " + shorten(canonicalize(raw))
        }

        let cwd = pwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cwd.isEmpty else { return nil }
        let c = canonicalize(cwd)
        if c == filed || c.hasPrefix(filed + "/") { return nil }
        return " · " + shorten(c)
    }

    static func canonicalize(_ path: String) -> String {
        var cleaned = (path as NSString).resolvingSymlinksInPath
        while cleaned.hasSuffix("/") && cleaned.count > 1 {
            cleaned = String(cleaned.dropLast())
        }
        return cleaned
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
