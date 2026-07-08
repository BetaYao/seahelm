import Foundation

/// Installs `~/.local/bin/seahelm-hook`, the command-hook bridge that reports
/// agent hook events to seahelm's control socket and relays any Stop-hook block
/// decision back to the agent via stdout. Prefers the Unix socket; falls back to
/// the HTTP webhook so a socket hiccup never breaks the Stop-hook UX.
enum SeahelmHookInstaller {
    static let versionMarker = "# seahelm-hook v1"

    static func scriptContents(port: UInt16) -> String {
        return """
        #!/bin/sh
        \(versionMarker) — managed by seahelm. Do not edit; it is overwritten on launch.
        # Command hook for Claude/Codex: reads the hook JSON on stdin, reports it to
        # seahelm, and prints any Stop-hook block decision ({"decision":"block",...})
        # to stdout so the agent continues and calls seahelm-suggest.
        set -u
        sock="${SEAHELM_SOCKET_PATH:-$HOME/.config/seahelm/seahelm.sock}"
        port="${SEAHELM_WEBHOOK_PORT:-\(port)}"

        payload="$(cat)"
        [ -n "$payload" ] || exit 0

        # 1) Unix control socket. Plain `nc -U` (Apple nc supports neither -N nor
        #    -w): it closes its write half on stdin EOF, the server replies with the
        #    base64-encoded block body (block_b64) and closes, nc exits.
        if [ -S "$sock" ] && command -v nc >/dev/null 2>&1; then
          req='{"id":"h","method":"hook","params":'"$payload"'}'
          resp="$(printf '%s\\n' "$req" | nc -U "$sock" 2>/dev/null)"
          if [ -n "$resp" ]; then
            b64="$(printf '%s' "$resp" | sed -n 's/.*"block_b64":"\\([A-Za-z0-9+/=]*\\)".*/\\1/p')"
            [ -n "$b64" ] && printf '%s' "$b64" | base64 -d 2>/dev/null
            exit 0
          fi
        fi

        # 2) HTTP webhook fallback: the response body IS the block decision (or empty).
        if command -v curl >/dev/null 2>&1; then
          curl -s -m 5 -X POST "http://127.0.0.1:$port/webhook" \\
            -H "Content-Type: application/json" -d "$payload"
        fi
        exit 0
        """
    }

    /// Absolute path to the installed hook script (used by hook config).
    static func scriptPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/seahelm-hook").path
    }

    @discardableResult
    static func ensureInstalled(port: UInt16 = 7070) -> Bool {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        return ensureInstalled(binDirectory: bin, port: port)
    }

    @discardableResult
    static func ensureInstalled(binDirectory: URL, port: UInt16) -> Bool {
        let scriptURL = binDirectory.appendingPathComponent("seahelm-hook")
        let desired = scriptContents(port: port)
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
