import Foundation

enum SeahelmSuggestInstaller {
    private static let versionMarker = "# seahelm-suggest v2"

    static func scriptContents(port: UInt16) -> String {
        return """
        #!/bin/sh
        \(versionMarker) — managed by seahelm. Do not edit; it is overwritten on launch.
        # Usage: seahelm-suggest "option one" "option two" ...
        # Reports suggested next steps to seahelm; shows as one tool-call line, never raw XML.
        # Prefers the Unix control socket (fs-scoped); falls back to the HTTP webhook.
        set -u
        port="${SEAHELM_WEBHOOK_PORT:-\(port)}"
        sock="${SEAHELM_SOCKET_PATH:-$HOME/.config/seahelm/seahelm.sock}"
        pane="${SEAHELM_PANE_ID:-}"

        esc() { printf '%s' "$1" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'; }

        opts=""
        for arg in "$@"; do
          item="\\"$(esc "$arg")\\""
          if [ -z "$opts" ]; then opts="$item"; else opts="$opts,$item"; fi
        done

        cwd="$(esc "$PWD")"
        pane_field=""
        if [ -n "$pane" ]; then pane_field="\\"pane_id\\":\\"$(esc "$pane")\\","; fi

        # 1) Unix control socket via nc -U (-N: half-close after our EOF so the
        #    server closes and nc exits promptly).
        if [ -S "$sock" ] && command -v nc >/dev/null 2>&1; then
          req='{"id":"suggest","method":"suggest","params":{'"$pane_field"'"cwd":"'"$cwd"'","options":['"$opts"']}}'
          if printf '%s\\n' "$req" | nc -U -N -w 2 "$sock" >/dev/null 2>&1; then
            exit 0
          fi
        fi

        # 2) HTTP webhook fallback.
        body='{"source":"seahelm-suggest","session_id":"cli","event":"suggest","cwd":"'"$cwd"'","data":{"options":['"$opts"']}}'
        curl -s -m 2 -X POST "http://127.0.0.1:$port/webhook" \\
          -H "Content-Type: application/json" \\
          -d "$body" >/dev/null 2>&1 || true
        exit 0
        """
    }

    @discardableResult
    static func ensureInstalled(port: UInt16 = 7070) -> Bool {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        return ensureInstalled(binDirectory: bin, port: port)
    }

    @discardableResult
    static func ensureInstalled(binDirectory: URL, port: UInt16) -> Bool {
        let scriptURL = binDirectory.appendingPathComponent("seahelm-suggest")
        let desired = scriptContents(port: port)

        // Skip if an up-to-date copy already exists.
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
            NSLog("[SeahelmSuggestInstaller] Failed to install: \(error)")
            return false
        }
    }
}
