import Foundation

enum SeahelmSuggestInstaller {
    private static let versionMarker = "# seahelm-suggest v4"

    static func scriptContents() -> String {
        return """
        #!/bin/sh
        \(versionMarker) — managed by seahelm. Do not edit; it is overwritten on launch.
        # Usage: seahelm-suggest "option one" "option two" ...
        # Reports suggested next steps to seahelm's control socket; shows as one
        # tool-call line, never raw XML.
        set -u
        sock="${SEAHELM_SOCKET_PATH:-$HOME/.config/seahelm/seahelm.sock}"
        # ZMX_SESSION is the same value SessionManager exports as SEAHELM_PANE_ID
        # (the backend session name). Panes created before that export exists still
        # carry it, so it rescues them: without a pane id this reports under the
        # literal "cli" while the Stop hook reports under Claude's session UUID, the
        # turn correlation never matches, and every Stop is blocked for a suggestion
        # that already happened.
        pane="${SEAHELM_PANE_ID:-${ZMX_SESSION:-}}"

        esc() { printf '%s' "$1" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'; }

        opts=""
        for arg in "$@"; do
          item="\\"$(esc "$arg")\\""
          if [ -z "$opts" ]; then opts="$item"; else opts="$opts,$item"; fi
        done

        cwd="$(esc "$PWD")"
        pane_field=""
        if [ -n "$pane" ]; then pane_field="\\"pane_id\\":\\"$(esc "$pane")\\","; fi

        # Unix control socket. Plain `nc -U` (Apple nc supports neither -N nor -w):
        # it closes its write half on stdin EOF, our server replies and closes.
        [ -S "$sock" ] && command -v nc >/dev/null 2>&1 || exit 0
        req='{"id":"suggest","method":"suggest","params":{'"$pane_field"'"cwd":"'"$cwd"'","options":['"$opts"']}}'
        printf '%s\\n' "$req" | nc -U "$sock" >/dev/null 2>&1 || true
        exit 0
        """
    }

    @discardableResult
    /// Absolute path to the installed script.
    ///
    /// Callers must use this rather than the bare name: nothing guarantees
    /// `~/.local/bin` is on PATH. seahelm gives panes only `SEAHELM_ENV` and
    /// `SEAHELM_SOCKET_PATH`, and macOS does not put `~/.local/bin` on PATH by
    /// default — so a bare `seahelm-suggest` resolves only on machines whose shell
    /// profile happens to add it. `SeahelmHookInstaller.scriptPath()` exists for
    /// the same reason.
    static func scriptPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/seahelm-suggest").path
    }

    static func ensureInstalled() -> Bool {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        return ensureInstalled(binDirectory: bin)
    }

    @discardableResult
    static func ensureInstalled(binDirectory: URL) -> Bool {
        let scriptURL = binDirectory.appendingPathComponent("seahelm-suggest")
        let desired = scriptContents()

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
