import Foundation

/// Installs `~/.local/bin/seahelm-hook`, the command-hook bridge that reports
/// agent hook events to seahelm's control socket and relays any Stop-hook block
/// decision back to the agent via stdout. Prefers the Unix socket; falls back to
/// the HTTP webhook so a socket hiccup never breaks the Stop-hook UX.
enum SeahelmHookInstaller {
    static let versionMarker = "# seahelm-hook v4"

    static func scriptContents() -> String {
        return """
        #!/bin/sh
        \(versionMarker) — managed by seahelm. Do not edit; it is overwritten on launch.
        # Command hook for Claude/Codex: reads the hook JSON on stdin, reports it to
        # seahelm, and prints any Stop-hook block decision ({"decision":"block",...})
        # to stdout so the agent continues and calls seahelm-suggest.
        set -u
        sock="${SEAHELM_SOCKET_PATH:-$HOME/.config/seahelm/seahelm.sock}"

        payload="$(cat)"
        [ -n "$payload" ] || exit 0

        # Tag the event with our stable pane id so seahelm can attribute it to the
        # exact pane (e.g. to transfer only that pane when it creates a worktree).
        # Session names are [A-Za-z0-9_-], so no JSON escaping is needed.
        # ZMX_SESSION holds the same value SessionManager exports as SEAHELM_PANE_ID,
        # and panes predating that export still have it — keep this fallback
        # identical to seahelm-suggest's, or the two sides key the turn differently
        # and every Stop blocks for a suggestion that already arrived.
        pid="${SEAHELM_PANE_ID:-${ZMX_SESSION:-}}"
        case "$payload" in
          '{'*) [ -n "$pid" ] && payload='{"seahelm_pane_id":"'"$pid"'",'"${payload#\\{}" ;;
        esac

        # Unix control socket. Plain `nc -U` (Apple nc supports neither -N nor -w):
        # it closes its write half on stdin EOF, the server replies with the
        # base64-encoded block body (block_b64) and closes, nc exits.
        [ -S "$sock" ] && command -v nc >/dev/null 2>&1 || exit 0
        req='{"id":"h","method":"hook","params":'"$payload"'}'
        resp="$(printf '%s\\n' "$req" | nc -U "$sock" 2>/dev/null)"
        b64="$(printf '%s' "$resp" | sed -n 's/.*"block_b64":"\\([A-Za-z0-9+/=]*\\)".*/\\1/p')"
        [ -n "$b64" ] && printf '%s' "$b64" | base64 -d 2>/dev/null
        exit 0
        """
    }

    /// Absolute path to the installed hook script (used by hook config).
    static func scriptPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/seahelm-hook").path
    }

    @discardableResult
    static func ensureInstalled() -> Bool {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        return ensureInstalled(binDirectory: bin)
    }

    @discardableResult
    static func ensureInstalled(binDirectory: URL) -> Bool {
        let scriptURL = binDirectory.appendingPathComponent("seahelm-hook")
        let desired = scriptContents()
        if let existing = try? String(contentsOf: scriptURL, encoding: .utf8),
           existing.contains(versionMarker), existing == desired {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            try desired.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            return true
        } catch {
            NSLog("[SeahelmHookInstaller] Failed to install: \(error)")
            return false
        }
    }
}
