import Foundation

/// Ensures Codex CLI is configured to forward hook events into seahelm's webhook server.
/// Codex hooks are command-based, so we install a command hook that POSTs stdin JSON to localhost.
enum CodexHooksSetup {

    private static let requiredEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Stop",
    ]

    private static func hookCommand(port: UInt16) -> String {
        "/bin/sh -lc '/usr/bin/curl -fsS -X POST http://localhost:\(port)/webhook -H \"Content-Type: application/json\" --data-binary @- 2>/dev/null || true'"
    }

    private static func hookConfig(port: UInt16) -> [[String: Any]] {
        [[
            "hooks": [[
                "type": "command",
                "command": hookCommand(port: port),
            ]],
        ]]
    }

    /// Check and patch ~/.codex/config.toml + ~/.codex/hooks.json on app launch.
    /// Returns true if either file was modified.
    @discardableResult
    static func ensureHooksConfigured(port: UInt16 = 7070) -> Bool {
        let codexDir = URL(fileURLWithPath: NSString("~/.codex").expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        } catch {
            NSLog("[CodexHooksSetup] Failed to create ~/.codex: \(error)")
            return false
        }

        let configChanged = ensureCodexHooksFeatureEnabled(at: codexDir.appendingPathComponent("config.toml"))
        let hooksChanged = ensureHooksJSON(at: codexDir.appendingPathComponent("hooks.json"), port: port)
        return configChanged || hooksChanged
    }

    private static func ensureCodexHooksFeatureEnabled(at configURL: URL) -> Bool {
        let original = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let normalized = original.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var featuresHeaderIndex: Int?
        for (index, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "[features]" {
            featuresHeaderIndex = index
            break
        }

        var changed = false

        if let headerIndex = featuresHeaderIndex {
            var sectionEnd = lines.count
            if headerIndex + 1 < lines.count {
                for index in (headerIndex + 1)..<lines.count {
                    let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                        sectionEnd = index
                        break
                    }
                }
            }

            var keyIndex: Int?
            for index in (headerIndex + 1)..<sectionEnd {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("codex_hooks") {
                    keyIndex = index
                    break
                }
            }

            if let keyIndex {
                let trimmed = lines[keyIndex].trimmingCharacters(in: .whitespaces)
                if trimmed != "codex_hooks = true" {
                    lines[keyIndex] = "codex_hooks = true"
                    changed = true
                }
            } else {
                lines.insert("codex_hooks = true", at: headerIndex + 1)
                changed = true
            }
        } else {
            if !lines.isEmpty, !(lines.last?.isEmpty ?? true) {
                lines.append("")
            }
            lines.append("[features]")
            lines.append("codex_hooks = true")
            changed = true
        }

        guard changed else { return false }

        let output = lines.joined(separator: "\n") + "\n"
        do {
            try output.write(to: configURL, atomically: true, encoding: .utf8)
            NSLog("[CodexHooksSetup] Enabled codex_hooks in ~/.codex/config.toml")
            return true
        } catch {
            NSLog("[CodexHooksSetup] Failed to write config.toml: \(error)")
            return false
        }
    }

    private static func ensureHooksJSON(at hooksURL: URL, port: UInt16) -> Bool {
        var root: [String: Any]
        if let data = try? Data(contentsOf: hooksURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        } else {
            root = [:]
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let config = hookConfig(port: port)
        var changed = false

        let expectedCommand = hookCommand(port: port)
        for event in requiredEvents {
            let current = hooks[event] as? [[String: Any]]
            let currentCommand = (current?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
            if current == nil || currentCommand != expectedCommand {
                hooks[event] = config
                changed = true
                NSLog("[CodexHooksSetup] Installed/updated hook: \(event)")
            }
        }

        guard changed else { return false }

        root["hooks"] = hooks

        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: hooksURL, options: .atomic)
            NSLog("[CodexHooksSetup] Updated ~/.codex/hooks.json with \(requiredEvents.count) hooks")
            return true
        } catch {
            NSLog("[CodexHooksSetup] Failed to write hooks.json: \(error)")
            return false
        }
    }
}

#if DEBUG
extension CodexHooksSetup {
    static func ensureCodexHooksFeatureEnabledForTests(at configURL: URL) -> Bool {
        ensureCodexHooksFeatureEnabled(at: configURL)
    }

    static func ensureHooksJSONForTests(at hooksURL: URL, port: UInt16) -> Bool {
        ensureHooksJSON(at: hooksURL, port: port)
    }
}
#endif
