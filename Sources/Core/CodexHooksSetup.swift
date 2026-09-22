import Foundation

/// Ensures Codex CLI is configured to forward hook events into seahelm.
/// Codex hooks are command-based; we install a command hook that pipes the
/// stdin JSON to the seahelm-hook bridge. The bridge only reports events;
/// Stop is never used as a reverse trigger to block Codex.
enum CodexHooksSetup {

    private static let requiredEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Stop",
    ]

    /// The `codex` argument tags the payload with its source, so the receiving
    /// side never has to infer Claude vs Codex from payload keys — an inference
    /// the two tools' converging schemas have made unreliable.
    private static func hookCommand() -> String {
        "/bin/sh -lc '\(SeahelmHookInstaller.scriptPath()) codex >/dev/null 2>&1 || true'"
    }

    /// What reconciling one file did. Separating these two matters because
    /// `OnboardingHookInstaller` renders this function's result as the wizard's
    /// `ok:` tick: returning "changed" meant a machine that was *already*
    /// configured showed Codex hooks as **failed**, which is a good way to make
    /// a customer chase a working integration.
    private enum Reconciled {
        case unchanged
        case written
        case failed

        var ok: Bool { self != .failed }
        var changed: Bool { self == .written }
    }

    /// Check and patch ~/.codex/config.toml + ~/.codex/hooks.json on app launch.
    /// Returns whether Codex ends up configured — true when it already was,
    /// false only when a write that was needed failed.
    @discardableResult
    static func ensureHooksConfigured() -> Bool {
        let codexDir = URL(fileURLWithPath: NSString("~/.codex").expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        } catch {
            NSLog("[CodexHooksSetup] Failed to create ~/.codex: \(error)")
            return false
        }

        let config = ensureHooksFeatureEnabled(at: codexDir.appendingPathComponent("config.toml"))
        let hooks = ensureHooksJSON(at: codexDir.appendingPathComponent("hooks.json"))
        return config.ok && hooks.ok
    }

    /// The bare key a `key = value` line assigns — nil for blanks, comments and
    /// table headers. Keys are compared whole rather than by prefix, so `hooks`
    /// is never confused with `codex_hooks` or a future `hooks_*`.
    private static func tomlKey(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[trimmed.startIndex..<equals].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    /// Enable `[features].hooks`, dropping the deprecated `codex_hooks` alias.
    ///
    /// `codex_hooks` was the original name and is still honoured (aliased in
    /// openai/codex#20522, 2026-05-01, so anything newer than that understands
    /// `hooks` — the 0.140.0 in the field included), but leaving it in place
    /// makes Codex print a deprecation warning into the agent's transcript on
    /// every run. Builds predating that alias know only `codex_hooks`; they are
    /// over a year stale and not carried here.
    private static func ensureHooksFeatureEnabled(at configURL: URL) -> Reconciled {
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

            // Rewrite the section as a whole rather than by index — removing the
            // alias and inserting the canonical key otherwise shift each other's
            // positions.
            var body = Array(lines[(headerIndex + 1)..<sectionEnd])

            let withoutAlias = body.filter { tomlKey(of: $0) != "codex_hooks" }
            if withoutAlias.count != body.count {
                body = withoutAlias
                changed = true
            }

            if let keyIndex = body.firstIndex(where: { tomlKey(of: $0) == "hooks" }) {
                if body[keyIndex].trimmingCharacters(in: .whitespaces) != "hooks = true" {
                    body[keyIndex] = "hooks = true"
                    changed = true
                }
            } else {
                body.insert("hooks = true", at: 0)
                changed = true
            }

            if changed {
                lines.replaceSubrange((headerIndex + 1)..<sectionEnd, with: body)
            }
        } else {
            if !lines.isEmpty, !(lines.last?.isEmpty ?? true) {
                lines.append("")
            }
            lines.append("[features]")
            lines.append("hooks = true")
            changed = true
        }

        guard changed else { return .unchanged }

        let output = lines.joined(separator: "\n") + "\n"
        do {
            try output.write(to: configURL, atomically: true, encoding: .utf8)
            NSLog("[CodexHooksSetup] Enabled [features].hooks in ~/.codex/config.toml")
            return .written
        } catch {
            NSLog("[CodexHooksSetup] Failed to write config.toml: \(error)")
            return .failed
        }
    }

    /// The entry every required event should carry.
    private static func hookEntry() -> [String: Any] {
        ["type": "command", "command": hookCommand()]
    }

    private static func ensureHooksJSON(at hooksURL: URL) -> Reconciled {
        var root: [String: Any]
        if let data = try? Data(contentsOf: hooksURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        } else {
            root = [:]
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        let entry = hookEntry()
        for event in requiredEvents {
            // A present-but-unreadable value is someone else's problem to fix;
            // clobbering their file is worse than not reporting that event.
            if hooks[event] != nil, hooks[event] as? [[String: Any]] == nil {
                NSLog("[CodexHooksSetup] Skipping \(event): unrecognised shape in hooks.json")
                continue
            }
            let groups = hooks[event] as? [[String: Any]] ?? []
            if let merged = HookEventMerge.merging(event: groups, entry: entry) {
                hooks[event] = merged
                changed = true
                NSLog("[CodexHooksSetup] Installed/updated hook: \(event)")
            }
        }

        guard changed else { return .unchanged }

        root["hooks"] = hooks

        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: hooksURL, options: .atomic)
            NSLog("[CodexHooksSetup] Updated ~/.codex/hooks.json with \(requiredEvents.count) hooks")
            return .written
        } catch {
            NSLog("[CodexHooksSetup] Failed to write hooks.json: \(error)")
            return .failed
        }
    }
}

#if DEBUG
extension CodexHooksSetup {
    /// Both shims report *changed*, which is what the tests are pinning; the
    /// public entry point reports ok.
    static func ensureHooksFeatureEnabledForTests(at configURL: URL) -> Bool {
        ensureHooksFeatureEnabled(at: configURL).changed
    }

    static func ensureHooksJSONForTests(at hooksURL: URL) -> Bool {
        ensureHooksJSON(at: hooksURL).changed
    }
}
#endif
