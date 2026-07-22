import Foundation

/// Installs a Pi extension that reports agent lifecycle to seahelm's control
/// socket, so a Pi pane shows precise running/idle status instead of relying on
/// screen-scan heuristics alone. (Waiting-for-project-trust stays a scan concern
/// — Pi's `project_trust` handler must *return* a decision, so subscribing to it
/// would hijack the user's trust choice.)
///
/// Two steps, both non-destructive:
///  1. Write the extension file to `~/.pi/agent/extensions/seahelm.js`.
///  2. Register that path in `~/.pi/agent/settings.json`'s `extensions` array —
///     Pi loads extensions from an explicit list, not by scanning a directory.
///
/// Unlike the OpenCode plugin (which shells out through the suggest script), the
/// Pi extension opens the socket itself via `node:net`: Pi runs on Node/Bun and
/// gives extensions no shell primitive, and a direct socket write is dependency-
/// free and never blocks the agent.
enum PiExtensionInstaller {
    // Ownership marker (no version in the match string): the overwrite guard
    // checks `contains`, so a versioned marker would make every older install
    // look foreign and freeze it.
    private static let versionMarker = "// seahelm-pi-extension"

    static func extensionContents() -> String {
        return """
        \(versionMarker) v1 — managed by seahelm. Do not edit; it is overwritten on launch.
        //
        // Reports Pi agent lifecycle to seahelm's control socket so a Pi pane shows
        // precise running/idle status. Fire-and-forget: it never blocks or fails the
        // agent, and silently no-ops when not launched inside a seahelm pane.
        import { createConnection } from "node:net"

        const HOME = process.env.HOME || ""
        const SOCK = process.env.SEAHELM_SOCKET_PATH || `${HOME}/.config/seahelm/seahelm.sock`
        // SEAHELM_PANE_ID is seahelm's stable pane id; ZMX_SESSION carries the same
        // value for panes created before that export existed.
        const PANE = process.env.SEAHELM_PANE_ID || process.env.ZMX_SESSION || ""

        function send(event, data) {
          if (!PANE) return
          let line
          try {
            line = JSON.stringify({
              id: "pi",
              method: "hook",
              params: {
                source: "pi",
                event,
                session_id: PANE,
                seahelm_pane_id: PANE,
                cwd: process.cwd(),
                data: data || {},
              },
            }) + "\\n"
          } catch {
            return
          }
          try {
            const sock = createConnection(SOCK)
            sock.on("error", () => {})            // socket absent / seahelm down — ignore
            sock.on("connect", () => sock.end(line))
            sock.setTimeout(2000, () => sock.destroy())
          } catch {}
        }

        export default function seahelm(pi) {
          // The agent started working on the user's message → running.
          pi.on("agent_start", () => send("user_prompt", { message: "Working" }))
          // Tool calls keep the pane running and add activity detail.
          pi.on("tool_execution_start", (e) =>
            send("tool_use_start", { tool_name: (e && e.toolName) || "tool", tool_input: e && e.args }))
          pi.on("tool_execution_end", (e) =>
            send((e && e.isError) ? "tool_use_failed" : "tool_use_end", { tool_name: (e && e.toolName) || "tool" }))
          // Fully settled — no retry, compaction, or queued continuation → idle.
          pi.on("agent_settled", () => send("agent_stop", {}))
        }
        """
    }

    /// `~/.pi/agent` — Pi's user config dir (config.ts: CONFIG_DIR_NAME ".pi").
    static func agentDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent", isDirectory: true)
    }

    static func extensionFileURL(agentDir: URL) -> URL {
        agentDir.appendingPathComponent("extensions/seahelm.js", isDirectory: false)
    }

    static func settingsURL(agentDir: URL) -> URL {
        agentDir.appendingPathComponent("settings.json", isDirectory: false)
    }

    @discardableResult
    static func ensureInstalled() -> Bool {
        ensureInstalled(agentDir: agentDirectory())
    }

    @discardableResult
    static func ensureInstalled(agentDir: URL) -> Bool {
        let fileURL = extensionFileURL(agentDir: agentDir)
        var changed = writeExtensionFile(to: fileURL)
        if registerInSettings(settingsURL: settingsURL(agentDir: agentDir),
                              extensionPath: fileURL.path) {
            changed = true
        }
        return changed
    }

    /// Write the extension, refusing to clobber a same-named file that isn't ours.
    private static func writeExtensionFile(to fileURL: URL) -> Bool {
        let desired = extensionContents()
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            if existing == desired { return false }
            guard existing.contains(versionMarker) else {
                NSLog("[PiExtensionInstaller] extensions/seahelm.js exists but is not ours; leaving it alone")
                return false
            }
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try desired.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("[PiExtensionInstaller] Failed to write extension: \(error)")
            return false
        }
    }

    /// Add `extensionPath` to settings.json's `extensions` array, preserving every
    /// other key. Skips (rather than clobbers) a settings file we can't parse as a
    /// JSON object or whose `extensions` isn't an array — the user's file wins.
    @discardableResult
    static func registerInSettings(settingsURL: URL, extensionPath: String) -> Bool {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                NSLog("[PiExtensionInstaller] settings.json is not a JSON object; skipping registration")
                return false
            }
            root = parsed
        }

        var extensions: [Any]
        if let existing = root["extensions"] {
            guard let arr = existing as? [Any] else {
                NSLog("[PiExtensionInstaller] settings.json `extensions` is not an array; skipping registration")
                return false
            }
            extensions = arr
        } else {
            extensions = []
        }

        // Already registered (match on the string path) → nothing to do.
        if extensions.contains(where: { ($0 as? String) == extensionPath }) { return false }
        extensions.append(extensionPath)
        root["extensions"] = extensions

        do {
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            NSLog("[PiExtensionInstaller] Failed to update settings.json: \(error)")
            return false
        }
    }
}
