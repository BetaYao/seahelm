import Foundation

enum ClaudeStatuslineBridgeInstaller {
    @discardableResult
    static func ensureInstalled() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ensureInstalled(
            settingsURL: home.appendingPathComponent(".claude/settings.json"),
            supportDirectory: home.appendingPathComponent("Library/Application Support/seahelm"),
            cacheDirectory: home.appendingPathComponent("Library/Caches/seahelm")
        )
    }

    @discardableResult
    private static func ensureInstalled(settingsURL: URL, supportDirectory: URL, cacheDirectory: URL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = settings["statusLine"] as? [String: Any],
              statusLine["type"] as? String == "command",
              let originalCommand = statusLine["command"] as? String,
              !originalCommand.contains("claude-statusline-bridge.sh") else { return false }

        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let originalURL = supportDirectory.appendingPathComponent("claude-statusline-original-command")
            try originalCommand.write(to: originalURL, atomically: true, encoding: .utf8)
            let scriptURL = supportDirectory.appendingPathComponent("claude-statusline-bridge.sh")
            try bridgeScript(originalCommandURL: originalURL, cacheURL: cacheDirectory.appendingPathComponent("claude-statusline.json"))
                .write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            var updatedStatusLine = statusLine
            updatedStatusLine["type"] = "command"
            updatedStatusLine["command"] = "/bin/sh \(shellQuote(scriptURL.path))"
            settings["statusLine"] = updatedStatusLine
            let output = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            NSLog("[ClaudeStatuslineBridgeInstaller] Failed to install bridge: \(error)")
            return false
        }
    }

    private static func bridgeScript(originalCommandURL: URL, cacheURL: URL) -> String {
        let originalCommandPath = shellQuote(originalCommandURL.path)
        let cachePath = shellQuote(cacheURL.path)
        let cacheDirectoryPath = shellQuote(cacheURL.deletingLastPathComponent().path)
        return """
        #!/bin/sh
        set -eu
        input_tmp=$(mktemp "${TMPDIR:-/tmp}/claude-statusline.XXXXXX")
        cache_tmp=$(mktemp "${TMPDIR:-/tmp}/claude-statusline-cache.XXXXXX")
        trap 'rm -f "$input_tmp" "$cache_tmp"' EXIT HUP INT TERM
        cat > "$input_tmp"
        mkdir -p \(cacheDirectoryPath)
        cp "$input_tmp" "$cache_tmp"
        mv "$cache_tmp" \(cachePath)
        if [ -f \(originalCommandPath) ]; then
          original=$(cat \(originalCommandPath))
          if [ -n "$original" ]; then
            /bin/sh -lc "$original" < "$input_tmp"
          fi
        fi
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

#if DEBUG
extension ClaudeStatuslineBridgeInstaller {
    static func ensureInstalledForTests(settingsURL: URL, supportDirectory: URL, cacheDirectory: URL) -> Bool {
        ensureInstalled(settingsURL: settingsURL, supportDirectory: supportDirectory, cacheDirectory: cacheDirectory)
    }
}
#endif
