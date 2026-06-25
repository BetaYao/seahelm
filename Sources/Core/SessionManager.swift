import Foundation
import CommonCrypto

enum SessionManager {
    /// Maximum session name length to stay within tmux socket path limits.
    private static let maxSessionNameLength = 40

    /// Generate a stable persistent session name from a worktree path.
    /// Format: amux-<parent>-<name>, with dots and colons replaced by underscores.
    /// Names exceeding maxSessionNameLength are truncated with a hash suffix for uniqueness.
    static func persistentSessionName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().lastPathComponent
        let name = url.lastPathComponent
        let raw = "amux-\(parent)-\(name)"
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        if raw.count <= maxSessionNameLength {
            return raw
        }

        let hash = shortHash(raw)
        let truncated = String(raw.prefix(maxSessionNameLength - hash.count - 1))
        return "\(truncated)-\(hash)"
    }

    /// Generate an indexed session name for an additional pane.
    static func indexedSessionName(base: String, index: Int) -> String {
        "\(base)-\(index)"
    }

    static func sessionNames(in layout: CodableSplitNode) -> [String] {
        switch layout {
        case .leaf(let sessionName):
            return [sessionName]
        case .split(_, _, let first, let second):
            return sessionNames(in: first) + sessionNames(in: second)
        }
    }

    static func expectedSessionNames(config: Config, discoveredWorktreePaths: [String]) -> Set<String> {
        var names = Set(discoveredWorktreePaths.map { persistentSessionName(for: $0) })
        for layout in config.splitLayouts.values {
            names.formUnion(sessionNames(in: layout))
        }
        return names.filter { $0.hasPrefix("amux-") }
    }

    static func parseZmxSessionNames(listOutput: String) -> [String] {
        listOutput
            .components(separatedBy: .newlines)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }

                if let range = trimmed.range(of: "name=") {
                    let suffix = trimmed[range.upperBound...]
                    let end = suffix.firstIndex(where: \.isWhitespace) ?? suffix.endIndex
                    let name = String(suffix[..<end])
                    return name.isEmpty ? nil : name
                }

                let fields = trimmed.split(whereSeparator: \.isWhitespace)
                guard let first = fields.first else { return nil }
                let candidate = String(first)
                return candidate.isEmpty ? nil : candidate
            }
    }

    static func orphanZmxSessionNames(activeSessionNames: Set<String>, listOutput: String) -> [String] {
        parseZmxSessionNames(listOutput: listOutput)
            .filter { $0.hasPrefix("amux-") && !activeSessionNames.contains($0) }
    }

    @discardableResult
    static func cleanupOrphanZmxSessions(
        activeSessionNames: Set<String>,
        listOutput: String? = nil
    ) -> [String] {
        let output = listOutput ?? ProcessRunner.output(["zmx", "list"]) ?? ""
        let orphaned = orphanZmxSessionNames(activeSessionNames: activeSessionNames, listOutput: output)
        for sessionName in orphaned {
            Station.forceKillZmxSession(sessionName)
        }
        return orphaned
    }

    /// Kill a persistent session (tmux or zmx)
    static func killSession(_ name: String, backend: String) {
        DispatchQueue.global(qos: .utility).async {
            if backend == "tmux" {
                ProcessRunner.runSync(["tmux", "kill-session", "-t", name])
            } else {
                Station.forceKillZmxSession(name)
            }
        }
    }

    /// Produce a short deterministic hash (6 hex chars) for session name deduplication.
    private static func shortHash(_ input: String) -> String {
        let data = Data(input.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    /// Resize a tmux session to match terminal grid size
    static func resizeTmuxSession(_ sessionName: String, cols: Int, rows: Int) {
        ProcessRunner.runSync(["tmux", "resize-window", "-t", sessionName, "-x", "\(cols)", "-y", "\(rows)"])
        ProcessRunner.runSync(["tmux", "refresh-client", "-t", sessionName, "-S"])
    }

    /// Refresh a tmux client display (auto-resize + refresh)
    static func refreshTmuxClient(_ sessionName: String) {
        ProcessRunner.runSync(["tmux", "resize-window", "-t", sessionName, "-A"])
        ProcessRunner.runSync(["tmux", "refresh-client", "-t", sessionName, "-S"])
    }

    // MARK: - Detached agent launch

    /// Build the backend CLI invocation(s) that create a persistent session
    /// detached, with `agentCommandLine` running in `cwd` and a shell kept alive
    /// afterward. Returns an empty array for backends without persistent
    /// sessions. Pure (no process spawning) — unit-tested.
    static func detachedLaunchCommands(
        backend: String,
        name: String,
        cwd: String,
        agentCommandLine: String,
        shell: String
    ) -> [[String]] {
        switch backend {
        case "tmux":
            // Create the detached interactive shell in cwd, then type the agent
            // command into it. The shell persists after the agent exits.
            return [
                ["tmux", "new-session", "-d", "-s", name, "-c", cwd],
                ["tmux", "send-keys", "-t", name, "clear && \(agentCommandLine)", "Enter"],
            ]
        case "zmx":
            // `zmx run` types the command into its own persistent interactive
            // shell (and appends a ZMX_TASK_COMPLETED marker), so the session
            // survives the agent exiting on its own — no `exec "$0"` trick
            // needed. Wrap only in a login shell that cd's and `clear`s the
            // echoed command line before the agent renders inline.
            let inner = "cd \(ShellEscape.singleQuote(cwd)) && clear && \(agentCommandLine)"
            return [["zmx", "run", name, shell, "-lic", inner]]
        default:
            return []
        }
    }

    /// Whether a persistent session with `name` already exists for `backend`.
    static func sessionExists(name: String, backend: String) -> Bool {
        switch backend {
        case "tmux":
            // has-session exits 0 (no stdout) when present → output() non-nil.
            return ProcessRunner.output(["tmux", "has-session", "-t", name]) != nil
        case "zmx":
            let list = ProcessRunner.output(["zmx", "list"]) ?? ""
            return parseZmxSessionNames(listOutput: list).contains(name)
        default:
            return false
        }
    }

    /// Create a detached session running the agent, unless one already exists.
    /// Spawns processes synchronously — call off the main thread.
    /// Returns whether a new session was launched.
    @discardableResult
    static func createDetachedSession(
        name: String,
        backend: String,
        cwd: String,
        agentCommandLine: String
    ) -> Bool {
        guard backend == "tmux" || backend == "zmx" else { return false }
        if sessionExists(name: name, backend: backend) { return false }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let commands = detachedLaunchCommands(
            backend: backend, name: name, cwd: cwd,
            agentCommandLine: agentCommandLine, shell: shell
        )
        guard !commands.isEmpty else { return false }
        for argv in commands {
            ProcessRunner.runSync(argv)
        }
        return true
    }
}
