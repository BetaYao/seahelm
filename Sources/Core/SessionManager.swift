import Foundation
import CommonCrypto

/// One live zmx session as reported by `zmx list`.
///
/// The daemon outlives the app, so this is also the only place stray sessions
/// become visible: a pane closed while its session survived shows up here with
/// `clients == 0` and nothing pointing at it.
struct ZmxSessionInfo: Equatable {
    let name: String
    let pid: Int?
    /// Attached clients. 0 means the session is running with nobody watching —
    /// the shape an orphan takes. Nil means `zmx` didn't report the field, which
    /// is not the same as zero and must never be treated as reapable.
    let clients: Int?
    let created: Date?
    let startDir: String?
    /// RSS sum for the zmx session root process and descendants.
    var processMemoryBytes: UInt64?
    /// RSS sum for the recognized agent process and descendants, if any.
    var agentMemoryBytes: UInt64?
    /// Best human-facing command under the session, useful when memory belongs
    /// to a tool wrapped by a shell or node process.
    var processName: String?
    /// Whether Seahelm created it (current or legacy prefix). Sessions started
    /// by hand outside the app are listed but never offered for cleanup.
    let isManaged: Bool

    var isDetached: Bool { clients == 0 }
}

enum SessionManager {
    /// Maximum session name length to keep backend session names bounded.
    private static let maxSessionNameLength = 40

    /// Check whether a session name uses a prefix managed by Seahelm (current or legacy).
    private static func isManagedSessionPrefix(_ name: String) -> Bool {
        name.hasPrefix("seahelm-") || name.hasPrefix("amux-")
    }

    /// Generate a stable persistent session name from a worktree path.
    /// Format: seahelm-<parent>-<name>, with dots and colons replaced by underscores.
    /// Names exceeding maxSessionNameLength are truncated with a hash suffix for uniqueness.
    static func persistentSessionName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().lastPathComponent
        let name = url.lastPathComponent
        let raw = "seahelm-\(parent)-\(name)"
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

    /// Full `zmx list` rows, for the session monitor in Settings.
    ///
    /// Deliberately separate from `orphanZmxSessionNames`: that one answers "may
    /// I kill this unattended?" and fails closed on anything ambiguous, while
    /// this one has to show everything, including the ambiguous rows, because
    /// hiding a session from a cleanup screen is the one thing it must not do.
    static func parseZmxSessions(listOutput: String) -> [ZmxSessionInfo] {
        listOutput.components(separatedBy: .newlines).compactMap { line -> ZmxSessionInfo? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let name = zmxListField(trimmed, "name=")
                ?? String(trimmed.split(whereSeparator: \.isWhitespace).first ?? "")
            guard !name.isEmpty else { return nil }

            let created = zmxListField(trimmed, "created=")
                .flatMap(TimeInterval.init)
                .map(Date.init(timeIntervalSince1970:))
            // start_dir is last on the line and paths contain spaces, so it runs
            // to end-of-line rather than to the next whitespace.
            var startDir: String?
            if let range = trimmed.range(of: "start_dir=") {
                let value = String(trimmed[range.upperBound...])
                startDir = value.isEmpty ? nil : value
            }

            return ZmxSessionInfo(
                name: name,
                pid: zmxListField(trimmed, "pid=").flatMap(Int.init),
                clients: zmxListField(trimmed, "clients=").flatMap(Int.init),
                created: created,
                startDir: startDir,
                processMemoryBytes: nil,
                agentMemoryBytes: nil,
                processName: nil,
                isManaged: isManagedSessionPrefix(name)
            )
        }
    }

    /// Parse `zmx list` rows and attach process-tree RSS data. This is used by
    /// the Settings monitor, not the orphan sweeper: memory probing is best-
    /// effort UI detail and must never affect cleanup decisions.
    static func parseZmxSessionsWithProcessMemory(listOutput: String) -> [ZmxSessionInfo] {
        let sessions = parseZmxSessions(listOutput: listOutput)
        guard sessions.contains(where: { $0.pid != nil }) else { return sessions }
        let procs = ProcessProbe.allProcesses()
        guard !procs.isEmpty else { return sessions }
        let manifests = ManifestStore.shared.all.map(\.manifest)

        return sessions.map { session in
            guard let pid = session.pid else { return session }
            let memory = ProcessProbe.memory(rootPid: Int32(pid), in: procs, manifests: manifests)
            var enriched = session
            enriched.processMemoryBytes = memory.totalBytes
            enriched.agentMemoryBytes = memory.agentBytes
            enriched.processName = memory.processName
            return enriched
        }
    }

    static func orphanZmxSessionNames(activeSessionNames: Set<String>, listOutput: String) -> [String] {
        listOutput.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let name = zmxListField(trimmed, "name=")
                ?? String(trimmed.split(whereSeparator: \.isWhitespace).first ?? "")
            guard isManagedSessionPrefix(name), !activeSessionNames.contains(name) else { return nil }
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
        for paneSessionKey in orphaned {
            ZmxSessionRecovery.forceKillSession(paneSessionKey)
        }
        return orphaned
    }

    /// Kill a persistent zmx session.
    static func killSession(_ name: String, backend: String) {
        DispatchQueue.global(qos: .utility).async {
            ZmxSessionRecovery.forceKillSession(name)
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
            // needed. Wrap in a login shell that cd's and `clear`s before the
            // agent renders. That inner `cd` only affects the nested shell; the
            // outer session shell's cwd is set separately by spawning `zmx` with
            // `Process.currentDirectoryURL = cwd` (see `createDetachedSession`),
            // so exiting the agent lands you back in the worktree — not in
            // whatever directory Seahelm itself was launched from.
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
        // zmx's session shell inherits this process's cwd. Without it, exiting
        // the agent drops you in Seahelm's launch directory (often the seahelm
        // checkout itself) instead of the worktree.
        for argv in commands {
            ProcessRunner.runSync(argv, currentDirectory: cwd)
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
