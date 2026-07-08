import Foundation
import CommonCrypto

enum SessionManager {
    /// Maximum session name length to keep backend session names bounded.
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
        listOutput.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let name = zmxListField(trimmed, "name=")
                ?? String(trimmed.split(whereSeparator: \.isWhitespace).first ?? "")
            guard name.hasPrefix("amux-"), !activeSessionNames.contains(name) else { return nil }
            // Only reap a session we can *positively* confirm is idle. A busy
            // daemon that misses the `zmx list` control-socket probe reports
            // `status=unreachable`/`err=…` with no `clients=` field — but a pane
            // may still be attached to it. Failing open there would end the
            // user's session mid-use ("Process exited. Press any key to close
            // the terminal."). So: skip anything unreachable/errored, skip when
            // the clients count is absent (unknown), and reap only when we can
            // read clients=0 from a reachable session.
            if let status = zmxListField(trimmed, "status="), status != "reachable" { return nil }
            if zmxListField(trimmed, "err=") != nil { return nil }
            guard let clientsField = zmxListField(trimmed, "clients="),
                  let clients = Int(clientsField) else { return nil }
            return clients >= 1 ? nil : name
        }
    }

    /// Extract a `key=value` field (value runs up to the next whitespace) from a
    /// `zmx list` line, or nil if absent.
    private static func zmxListField(_ line: String, _ key: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let suffix = line[range.upperBound...]
        let end = suffix.firstIndex(where: \.isWhitespace) ?? suffix.endIndex
        let value = String(suffix[..<end])
        return value.isEmpty ? nil : value
    }

    @discardableResult
    static func cleanupOrphanZmxSessions(
        activeSessionNames: Set<String>,
        listOutput: String? = nil
    ) -> [String] {
        let output = listOutput ?? ProcessRunner.output([ZmxLocator.executable(), "list"]) ?? ""
        let orphaned = orphanZmxSessionNames(activeSessionNames: activeSessionNames, listOutput: output)
        for sessionName in orphaned {
            Station.forceKillZmxSession(sessionName)
        }
        return orphaned
    }

    /// Kill a persistent zmx session.
    static func killSession(_ name: String, backend: String) {
        DispatchQueue.global(qos: .utility).async {
            Station.forceKillZmxSession(name)
        }
    }

    /// Produce a short deterministic hash (6 hex chars) for session name deduplication.
    private static func shortHash(_ input: String) -> String {
        let data = Data(input.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.prefix(3).map { String(format: "%02x", $0) }.joined()
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
        case "zmx":
            // `zmx run` types the command into its own persistent interactive
            // shell (and appends a ZMX_TASK_COMPLETED marker), so the session
            // survives the agent exiting on its own — no `exec "$0"` trick
            // needed. Wrap only in a login shell that cd's and `clear`s the
            // echoed command line before the agent renders inline.
            //
            // Export the control-socket context first so the agent (and any tool
            // it spawns, e.g. seahelm-suggest) can reach the multiplexer socket
            // and knows it is running inside a seahelm pane.
            let socketPath = ControlSocketServer.defaultSocketPath()
            // SEAHELM_PANE_ID is the stable session name so an agent can reference
            // its own pane across app restarts (the control API resolves it).
            let exports = "export SEAHELM_ENV=1 SEAHELM_SOCKET_PATH=\(ShellEscape.singleQuote(socketPath))"
                + " SEAHELM_PANE_ID=\(ShellEscape.singleQuote(name))"
            let inner = "\(exports) && cd \(ShellEscape.singleQuote(cwd)) && clear && \(agentCommandLine)"
            return [[ZmxLocator.executable(), "run", name, shell, "-lic", inner]]
        default:
            return []
        }
    }

    /// Whether a persistent session with `name` already exists for `backend`.
    static func sessionExists(name: String, backend: String) -> Bool {
        switch backend {
        case "zmx":
            let list = ProcessRunner.output([ZmxLocator.executable(), "list"]) ?? ""
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
        guard backend == "zmx" else { return false }
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

    /// Block until a session named `name` exists, or `timeoutSeconds` elapses.
    /// Returns whether the session exists at the end. Call off the main thread.
    /// Used to decouple "the agent session is up" from "the agent has exited":
    /// `zmx run` blocks for the agent's whole lifetime, so the session is spawned
    /// on a detached thread and the caller waits only for it to come up.
    static func waitUntilSessionExists(name: String, backend: String, timeoutSeconds: Double) -> Bool {
        guard backend == "zmx" else { return true }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if sessionExists(name: name, backend: backend) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return sessionExists(name: name, backend: backend)
    }
}
