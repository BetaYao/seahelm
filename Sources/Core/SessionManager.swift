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

    // MARK: - Orphan zmx client processes

    /// One process row as the client sweep sees it.
    struct ZmxProcess: Equatable {
        let pid: Int32
        let ppid: Int32
        let command: String

        /// The vendored binary's path, not a bare "zmx": an agent's own command
        /// line can mention zmx without being one.
        var isZmxBinary: Bool {
            command.contains("/bin/zmx ") || command.hasSuffix("/bin/zmx")
        }
    }

    /// `zmx attach`/`run` clients that no longer have anyone to serve.
    ///
    /// These do not exit when Seahelm dies — they spin at 20-70% CPU forever,
    /// and every restart leaves a few more (20 were found holding 4.3 cores
    /// after a day of restarts). The test is deliberately *not* "does the target
    /// session still exist": the two worst offenders found were spinning against
    /// sessions that were perfectly alive, and `zmx list` showed `clients=1`,
    /// i.e. they had never attached at all. What identifies them is having no
    /// live parent while not being a session daemon themselves.
    ///
    /// Which makes telling a daemon from a client the whole job, and it cannot be
    /// done from `zmx list` pids alone: `pid=` names the *process inside* the
    /// session (the shell, or the agent), never the zmx process hosting it. A
    /// set of those pids therefore never intersects the zmx processes being
    /// swept, so excluding it protected nothing and this sweep reaped every
    /// surviving daemon of the previous instance — killing all 8 live sessions
    /// about five minutes after each restart. The daemon is found by walking up
    /// from the reported pid to the nearest zmx-binary ancestor instead; the walk
    /// starts at the pid itself so a future zmx that does report the daemon pid
    /// stays correct. Any session whose daemon cannot be resolved that way
    /// abandons the whole sweep — reaping nothing costs CPU, guessing costs
    /// agents.
    static func orphanZmxClientPids(processes: [ZmxProcess], sessionPids: Set<Int32>) -> [Int32] {
        // Without session pids every daemon looks like an orphan. Refuse to guess.
        guard !sessionPids.isEmpty else { return [] }
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var daemonPids: Set<Int32> = []
        for sessionPid in sessionPids {
            guard let daemon = zmxDaemonPid(hosting: sessionPid, byPid: byPid) else { return [] }
            daemonPids.insert(daemon)
        }
        return processes.compactMap { proc in
            guard proc.isZmxBinary else { return nil }
            guard !daemonPids.contains(proc.pid) else { return nil }   // session daemon
            guard proc.ppid == 1 else { return nil }                   // has a live parent
            return proc.pid
        }
    }

    /// The zmx process hosting `sessionPid`: itself if it is one, else its
    /// nearest zmx-binary ancestor. Note the client that *created* a session is
    /// also an ancestor of it (`login` → client → daemon → shell), so only the
    /// nearest one may be treated as the daemon — stopping at the first hit is
    /// what keeps the outer client reapable.
    private static func zmxDaemonPid(hosting sessionPid: Int32, byPid: [Int32: ZmxProcess]) -> Int32? {
        var current: Int32? = sessionPid
        // Bounded: a ps snapshot can disagree with itself about parentage.
        for _ in 0..<16 {
            guard let pid = current, pid > 1, let proc = byPid[pid] else { return nil }
            if proc.isZmxBinary { return proc.pid }
            current = proc.ppid
        }
        return nil
    }

    /// Parse `ps -axo pid=,ppid=,command=`. Every row is kept, not just the zmx
    /// ones: resolving a session's daemon means walking parents through the
    /// non-zmx processes (`login`, the session's own shell) in between.
    static func parseZmxProcesses(psOutput: String) -> [ZmxProcess] {
        psOutput.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { return nil }
            return ZmxProcess(pid: pid, ppid: ppid, command: String(parts[2]))
        }
    }

    /// Kill orphaned zmx clients. Returns the pids reaped. Safe to call at
    /// startup: sessions and their daemons are left alone.
    @discardableResult
    static func cleanupOrphanZmxClients(listOutput: String? = nil, psOutput: String? = nil) -> [Int32] {
        let list = listOutput ?? ProcessRunner.output([ZmxLocator.executable(), "list"]) ?? ""
        let sessionPids = Set(list.components(separatedBy: .newlines).compactMap { line -> Int32? in
            guard let value = zmxListField(line, "pid=") else { return nil }
            return Int32(value)
        })
        let ps = psOutput ?? ProcessRunner.output(["ps", "-axo", "pid=,ppid=,command="]) ?? ""
        let processes = parseZmxProcesses(psOutput: ps)
        let orphans = orphanZmxClientPids(processes: processes, sessionPids: sessionPids)
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        for pid in orphans {
            // Log the command line before killing: the one bug this sweep has had
            // was invisible in a bare pid count.
            NSLog("[SessionManager] Reaping orphan zmx client %d: %@", pid, byPid[pid]?.command ?? "?")
            // SIGKILL, not SIGTERM: the spin loop never reaches a signal handler,
            // so a terminate is simply ignored.
            kill(pid, SIGKILL)
        }
        return orphans
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
        shell: String,
        terminfoPath: String? = TerminalEnvironment.bundledTerminfoPath()
    ) -> [[String]] {
        switch backend {
        case "zmx":
            // `zmx run` types the command into its own persistent interactive
            // shell (and appends a ZMX_TASK_COMPLETED marker), so the session
            // survives the agent exiting on its own — no `exec "$0"` trick
            // needed. Wrap in a login shell that cd's and clears the screen
            // before the agent renders — `zmx run` *types* this whole command
            // line into the session's interactive shell, so without the clear
            // the agent's TUI comes up underneath the echoed command plus the
            // login shell's own startup noise. That inner `cd` only affects the
            // nested shell; the outer session shell's cwd is set separately by
            // spawning `zmx` with `Process.currentDirectoryURL = cwd` (see
            // `createDetachedSession`), so exiting the agent lands you back in
            // the worktree — not in whatever directory Seahelm was launched from.
            //
            // Export the control-socket context first so the agent (and any tool
            // it spawns, e.g. seahelm-suggest) can reach the multiplexer socket
            // and knows it is running inside a seahelm pane.
            let socketPath = ControlSocketServer.defaultSocketPath()
            // SEAHELM_PANE_ID is the stable session name so an agent can reference
            // its own pane across app restarts (the control API resolves it).
            let exports = "export SEAHELM_ENV=1 SEAHELM_SOCKET_PATH=\(ShellEscape.singleQuote(socketPath))"
                + " SEAHELM_PANE_ID=\(ShellEscape.singleQuote(name))"
            let inner = "\(exports) && cd \(ShellEscape.singleQuote(cwd))"
                + " && \(TerminalEnvironment.clearScreenCommand) && \(agentCommandLine)"
            // Prefixed as `env` assignments rather than exported inside `inner`
            // so the *session* PTY carries them: the shell zmx spawns, the rc
            // files it sources, and the agent all see the same terminal a pane
            // opened through Ghostty would have had. `runSync` execs through
            // /usr/bin/env, so these ride along as plain argv.
            let termEnv = TerminalEnvironment.envAssignments(terminfoPath: terminfoPath)
            return [termEnv + [ZmxLocator.executable(), "run", name, shell, "-lic", inner]]
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
