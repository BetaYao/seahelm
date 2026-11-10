import Foundation
import CommonCrypto

/// One live seahelmd session as reported by `seahelmd list`.
///
/// The daemon outlives the app, so this is also the only place stray sessions
/// become visible: a pane closed while its session survived shows up here with
/// `clients == 0` and nothing pointing at it.
struct SeahelmdSessionInfo: Equatable {
    let name: String
    let pid: Int?
    /// Attached clients. 0 means the session is running with nobody watching —
    /// the shape an orphan takes. Nil means `seahelmd` didn't report the field, which
    /// is not the same as zero and must never be treated as reapable.
    let clients: Int?
    let created: Date?
    let startDir: String?
    /// RSS sum for the seahelmd session root process and descendants.
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

        return boundedSessionName(raw)
    }

    /// Generate an indexed session name for an additional pane.
    ///
    /// Uses `--pane-N` so `base-2` cannot collide with another worktree whose
    /// directory is literally `…-2`. The `--pane-N` suffix is kept intact when
    /// truncating — `nextPaneIndex` parses it — and only the base head is
    /// shortened (with a hash) to stay within the backend name limit.
    static func indexedSessionName(base: String, index: Int) -> String {
        let suffix = "--pane-\(index)"
        let budget = max(0, maxSessionNameLength - suffix.utf8.count)
        return boundedSessionName(base, maxLength: budget) + suffix
    }

    private static func boundedSessionName(_ raw: String) -> String {
        boundedSessionName(raw, maxLength: maxSessionNameLength)
    }

    private static func boundedSessionName(_ raw: String, maxLength: Int) -> String {
        guard raw.utf8.count > maxLength else { return raw }

        let hash = shortHash(raw)
        let prefixLength = max(0, maxLength - hash.utf8.count - 1)
        let prefix = String(decoding: raw.utf8.prefix(prefixLength), as: UTF8.self)
        return "\(prefix)-\(hash)"
    }

    static func parseSeahelmdSessionNames(listOutput: String) -> [String] {
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

    /// What `seahelmd list` says about one session's control socket.
    enum SessionReachability: Equatable {
        /// Not listed at all — the daemon is gone.
        case missing
        /// Listed, and the control socket answered.
        case reachable
        /// Listed, but the control-socket probe timed out or errored. The daemon
        /// process is still around; whether it can serve anyone is another matter.
        case unreachable
    }

    /// Reachability of `name` within an already-captured `seahelmd list` output.
    ///
    /// Deliberately a different question from `sessionExists`, which only asks
    /// whether the name appears. A daemon wedged by its volume dropping out keeps
    /// its socket file and its `seahelmd list` row — it just stops answering — so
    /// "listed" and "usable" part company exactly when it matters most, and
    /// answering the first when the caller meant the second is what left panes
    /// re-attaching to a corpse forever.
    static func reachability(of name: String, listOutput: String) -> SessionReachability {
        for line in listOutput.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let rowName = seahelmdListField(trimmed, "name=")
                ?? String(trimmed.split(whereSeparator: \.isWhitespace).first ?? "")
            // Exact match, never a prefix: `seahelm-foo` and `seahelm-foo-1` are
            // separate panes and routinely have opposite health.
            guard rowName == name else { continue }
            if seahelmdListField(trimmed, "err=") != nil { return .unreachable }
            if let status = seahelmdListField(trimmed, "status="), status != "reachable" { return .unreachable }
            return .reachable
        }
        return .missing
    }

    /// Full `seahelmd list` rows, for the session monitor in Settings.
    ///
    /// Deliberately separate from `orphanSeahelmdSessionNames`: that one answers "may
    /// I kill this unattended?" and fails closed on anything ambiguous, while
    /// this one has to show everything, including the ambiguous rows, because
    /// hiding a session from a cleanup screen is the one thing it must not do.
    static func parseSeahelmdSessions(listOutput: String) -> [SeahelmdSessionInfo] {
        listOutput.components(separatedBy: .newlines).compactMap { line -> SeahelmdSessionInfo? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let name = seahelmdListField(trimmed, "name=")
                ?? String(trimmed.split(whereSeparator: \.isWhitespace).first ?? "")
            guard !name.isEmpty else { return nil }

            let created = seahelmdListField(trimmed, "created=")
                .flatMap(TimeInterval.init)
                .map(Date.init(timeIntervalSince1970:))
            // start_dir is last on the line and paths contain spaces, so it runs
            // to end-of-line rather than to the next whitespace.
            var startDir: String?
            if let range = trimmed.range(of: "start_dir=") {
                let value = String(trimmed[range.upperBound...])
                startDir = value.isEmpty ? nil : value
            }

            return SeahelmdSessionInfo(
                name: name,
                pid: seahelmdListField(trimmed, "pid=").flatMap(Int.init),
                clients: seahelmdListField(trimmed, "clients=").flatMap(Int.init),
                created: created,
                startDir: startDir,
                processMemoryBytes: nil,
                agentMemoryBytes: nil,
                processName: nil,
                isManaged: isManagedSessionPrefix(name)
            )
        }
    }

    /// Parse `seahelmd list` rows and attach process-tree RSS data. This is used by
    /// the Settings monitor, not the orphan sweeper: memory probing is best-
    /// effort UI detail and must never affect cleanup decisions.
    static func parseSeahelmdSessionsWithProcessMemory(listOutput: String) -> [SeahelmdSessionInfo] {
        let sessions = parseSeahelmdSessions(listOutput: listOutput)
        guard sessions.contains(where: { $0.pid != nil }) else { return sessions }
        let procs = ProcessProbe.allProcesses()
        guard !procs.isEmpty else { return sessions }
        let manifests = ManifestStore.shared.all

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

    static func orphanSeahelmdSessionNames(activeSessionNames: Set<String>, listOutput: String) -> [String] {
        listOutput.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let name = seahelmdListField(trimmed, "name=")
                ?? String(trimmed.split(whereSeparator: \.isWhitespace).first ?? "")
            guard isManagedSessionPrefix(name), !activeSessionNames.contains(name) else { return nil }
            // Only reap a session we can *positively* confirm is idle. A busy
            // daemon that misses the `seahelmd list` control-socket probe reports
            // `status=unreachable`/`err=…` with no `clients=` field — but a pane
            // may still be attached to it. Failing open there would end the
            // user's session mid-use ("Process exited. Press any key to close
            // the terminal."). So: skip anything unreachable/errored, skip when
            // the clients count is absent (unknown), and reap only when we can
            // read clients=0 from a reachable session.
            if let status = seahelmdListField(trimmed, "status="), status != "reachable" { return nil }
            if seahelmdListField(trimmed, "err=") != nil { return nil }
            guard let clientsField = seahelmdListField(trimmed, "clients="),
                  let clients = Int(clientsField) else { return nil }
            return clients >= 1 ? nil : name
        }
    }

    // MARK: - Orphan attach clients

    /// One process row as the client sweep sees it.
    struct SeahelmdProcess: Equatable {
        let pid: Int32
        let ppid: Int32
        let command: String

        /// A pane's attach client: the bundled daemon binary run as `attach`.
        /// Matched on the path and the verb, not a bare "seahelmd": an agent's
        /// own command line can mention it without being one, and the session
        /// daemons (`seahelmd __serve`) must never match.
        var isAttachClient: Bool {
            command.contains("/bin/seahelmd attach ")
        }
    }

    /// Attach clients that no longer have anyone to serve: re-parented to
    /// launchd because the pane that ran them is gone.
    ///
    /// A client exits on its own when its terminal closes; this is the net for
    /// one that did not (one spinning at 20-70% CPU would otherwise outlive
    /// every restart). seahelmd names its roles in argv — `__serve` for a
    /// session's daemon, `attach` for a pane's client — so telling them apart
    /// needs no walk from session pids, which a session still held for its pane
    /// does not even have yet.
    static func orphanSeahelmdClientPids(processes: [SeahelmdProcess]) -> [Int32] {
        processes.compactMap { proc in
            guard proc.isAttachClient, proc.ppid == 1 else { return nil }
            return proc.pid
        }
    }

    /// Parse `ps -axo pid=,ppid=,command=`. Every row is kept, not just the seahelmd
    /// ones: resolving a session's daemon means walking parents through the
    /// non-seahelmd processes (`login`, the session's own shell) in between.
    static func parseSeahelmdProcesses(psOutput: String) -> [SeahelmdProcess] {
        psOutput.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { return nil }
            return SeahelmdProcess(pid: pid, ppid: ppid, command: String(parts[2]))
        }
    }

    /// Kill orphaned seahelmd clients. Returns the pids reaped. Safe to call at
    /// startup: sessions and their daemons are left alone.
    @discardableResult
    static func cleanupOrphanSeahelmdClients(psOutput: String? = nil) -> [Int32] {
        let ps = psOutput ?? ProcessRunner.output(["ps", "-axo", "pid=,ppid=,command="]) ?? ""
        let processes = parseSeahelmdProcesses(psOutput: ps)
        let orphans = orphanSeahelmdClientPids(processes: processes)
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        for pid in orphans {
            // Log the command line before killing: the one bug this sweep has had
            // was invisible in a bare pid count.
            NSLog("[SessionManager] Reaping orphan attach client %d: %@", pid, byPid[pid]?.command ?? "?")
            // SIGKILL, not SIGTERM: the spin loop never reaches a signal handler,
            // so a terminate is simply ignored.
            kill(pid, SIGKILL)
        }
        return orphans
    }

    /// `seahelmd attach` clients whose target session is missing or unreachable.
    ///
    /// Distinct from `orphanSeahelmdClientPids`: those only reap `ppid == 1` clients
    /// left behind after Seahelm itself died. After a volume drop the attach
    /// client hangs rather than exiting, so it still has a live Seahelm parent
    /// and the orphan sweep leaves it spinning at ~100% CPU forever. The
    /// one-shot Station health check has already run by then, so nothing else
    /// looks at these corpses unless we do.
    ///
    /// Only `attach` is targeted. `seahelmd run` hosts the session and must go
    /// through `forceKillSession`.
    static func wedgedAttachClientPids(processes: [SeahelmdProcess], listOutput: String) -> [Int32] {
        var reachabilityByName: [String: SessionReachability] = [:]
        for line in listOutput.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let name = seahelmdListField(trimmed, "name=")
                ?? String(trimmed.split(whereSeparator: \.isWhitespace).first ?? "")
            guard !name.isEmpty else { continue }
            if seahelmdListField(trimmed, "err=") != nil {
                reachabilityByName[name] = .unreachable
            } else if let status = seahelmdListField(trimmed, "status="), status != "reachable" {
                reachabilityByName[name] = .unreachable
            } else {
                reachabilityByName[name] = .reachable
            }
        }
        return processes.compactMap { proc in
            guard proc.isAttachClient else { return nil }
            guard let session = attachSessionName(fromCommand: proc.command) else { return nil }
            let status = reachabilityByName[session] ?? .missing
            switch status {
            case .missing, .unreachable:
                return proc.pid
            case .reachable:
                return nil
            }
        }
    }

    /// Session name targeted by a `seahelmd attach <name>` command line, if any.
    static func attachSessionName(fromCommand command: String) -> String? {
        guard let range = command.range(of: "/bin/seahelmd attach ") else { return nil }
        let rest = command[range.upperBound...]
        guard let token = rest.split(whereSeparator: \.isWhitespace).first else { return nil }
        let name = String(token)
        return name.isEmpty ? nil : name
    }

    /// Managed sessions whose control socket is unreachable *and* whose
    /// `start_dir` is not known to be reachable. That is the volume-drop
    /// corpse: the row survives, the daemon answers nothing, and the checkout
    /// path is gone or wedged. A busy daemon that merely missed one probe keeps
    /// a reachable `start_dir` and is left alone.
    static func unreachableSessionNames(
        listOutput: String,
        startDirReachable: (String) -> Bool
    ) -> [String] {
        parseSeahelmdSessions(listOutput: listOutput).compactMap { session in
            guard isManagedSessionPrefix(session.name) else { return nil }
            guard reachability(of: session.name, listOutput: listOutput) == .unreachable else {
                return nil
            }
            guard let startDir = session.startDir, !startDir.isEmpty else {
                // No start_dir to probe — treat as wedged so a nameless corpse
                // cannot sit forever after a volume drop.
                return session.name
            }
            return startDirReachable(startDir) ? nil : session.name
        }
    }

    /// Force-kill managed sessions wedged by a dead/unreachable start_dir, then
    /// reap any attach clients left spinning against them (or against sessions
    /// that have already disappeared). Returns session names that were cleaned.
    ///
    /// Deliberately does **not** reap attaches for an unreachable session whose
    /// `start_dir` is still reachable — that shape is also what a busy daemon
    /// looks like for one probe, and killing the live pane's attach would blank
    /// a working agent.
    @discardableResult
    static func cleanupWedgedVolumeSessions(
        listOutput: String? = nil,
        psOutput: String? = nil,
        startDirReachable: ((String) -> Bool)? = nil
    ) -> [String] {
        let list = listOutput ?? SeahelmdLocator.listOutput() ?? ""
        let reachable = startDirReachable ?? { path in
            // nil (probe timed out) and false (gone) both mean "not usable".
            FileSystemProbe.existsIfKnown(path, timeout: 0.5) == true
        }
        let names = unreachableSessionNames(listOutput: list, startDirReachable: reachable)
        for name in names {
            NSLog("[SessionManager] Force-killing volume-wedged seahelmd session '%@'", name)
            SeahelmdSessionRecovery.forceKillSession(name)
        }
        let ps = psOutput ?? ProcessRunner.output(["ps", "-axo", "pid=,ppid=,command="]) ?? ""
        let processes = parseSeahelmdProcesses(psOutput: ps)
        // After force-kill the rows are often already gone; classify against the
        // pre-kill list so we still catch attaches whose session name we just
        // tore down, plus any attach whose session is simply missing.
        let wedged = wedgedAttachClientPids(processes: processes, listOutput: list)
        let confirmed = Set(names)
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        for pid in wedged {
            guard let command = byPid[pid]?.command,
                  let session = attachSessionName(fromCommand: command) else { continue }
            let status = reachability(of: session, listOutput: list)
            // Missing attaches are always safe to reap. Unreachable attaches are
            // only reaped when we already confirmed the start_dir is dead.
            let shouldKill = status == .missing || confirmed.contains(session)
            guard shouldKill else { continue }
            NSLog("[SessionManager] Reaping volume-wedged seahelmd attach %d: %@", pid, command)
            kill(pid, SIGKILL)
        }
        return names
    }

    /// Extract a `key=value` field (value runs up to the next whitespace) from a
    /// `seahelmd list` line, or nil if absent.
    private static func seahelmdListField(_ line: String, _ key: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let suffix = line[range.upperBound...]
        let end = suffix.firstIndex(where: \.isWhitespace) ?? suffix.endIndex
        let value = String(suffix[..<end])
        return value.isEmpty ? nil : value
    }

    @discardableResult
    static func cleanupOrphanSeahelmdSessions(
        activeSessionNames: Set<String>,
        listOutput: String? = nil
    ) -> [String] {
        let output = listOutput ?? SeahelmdLocator.listOutput() ?? ""
        let orphaned = orphanSeahelmdSessionNames(activeSessionNames: activeSessionNames, listOutput: output)
        for paneSessionKey in orphaned {
            SeahelmdSessionRecovery.forceKillSession(paneSessionKey)
        }
        return orphaned
    }

    /// Kill a persistent seahelmd session.
    static func killSession(_ name: String, backend: String) {
        DispatchQueue.global(qos: .utility).async {
            SeahelmdSessionRecovery.forceKillSession(name)
            ShellRunIntegration.removeSpool(session: name)
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

    /// Build the daemon invocation(s) that create a persistent session with
    /// `agentCommandLine` running in `cwd`, a shell kept alive afterward.
    /// Returns an empty array for backends without persistent sessions. Pure
    /// (no process spawning) — unit-tested.
    ///
    /// The agent is the session's own program — `shell -lic` running it, then
    /// `exec`-ing an interactive login shell so the pane is left at a prompt
    /// when the agent exits — and seahelmd holds it until the pane attaches
    /// (`new --hold`). An agent asks its terminal what it is once, at startup
    /// (OSC 7501 program status, OSC 10/11 colours), and a pane attached then
    /// answers as the app will keep answering; it also draws its first frame at
    /// the pane's size. Nothing is typed into a shell, so the launch line never
    /// shows in the pane.
    ///
    /// The control-socket context is exported first so the agent (and any tool
    /// it spawns, e.g. seahelm-suggest) can reach the multiplexer socket and
    /// knows it is running inside a seahelm pane. SEAHELM_PANE_ID is the stable
    /// session name so an agent can reference its own pane across app restarts.
    /// The terminal environment rides along as `env` assignments so the session
    /// PTY carries the same terminal a pane opened through Ghostty would have:
    /// `runSync` execs through /usr/bin/env, so they are plain argv.
    static func detachedLaunchCommands(
        backend: String,
        name: String,
        cwd: String,
        agentCommandLine: String,
        shell: String,
        terminfoPath: String? = TerminalEnvironment.bundledTerminfoPath(),
        daemon: String = SeahelmdLocator.executable(),
        facts: [String] = SeahelmdLocator.sessionEnvironment()
    ) -> [[String]] {
        guard backend == "seahelmd" else { return [] }
        let socketPath = ControlSocketServer.defaultSocketPath()
        let exports = "export SEAHELM_ENV=1 SEAHELM_SOCKET_PATH=\(ShellEscape.singleQuote(socketPath))"
            + " SEAHELM_PANE_ID=\(ShellEscape.singleQuote(name))"
        let inner = "{ \(exports) && cd \(ShellEscape.singleQuote(cwd))"
            + " && \(TerminalEnvironment.clearScreenCommand) && \(agentCommandLine); }"
            + "; exec \(ShellEscape.singleQuote(shell)) -l"
        let env = TerminalEnvironment.envAssignments(terminfoPath: terminfoPath) + facts
        return [env + [daemon, "new", "--hold", String(clientWaitSeconds), name, "--", shell, "-lic", inner]]
    }

    /// How long a detached launch holds the agent for its pane before starting
    /// it anyway. Measured on seahelmd: an attach 0.2s after creation caught Claude's
    /// startup probe and one at 1s missed it; the hold makes that moot.
    static let clientWaitSeconds = 10

    /// Whether a persistent session with `name` already exists for `backend`.
    ///
    /// Presence only — an unreachable session still counts as existing here, on
    /// purpose. Every caller is asking "should I create one?"
    /// (`createDetachedSession`, `seedSessionIfMissing`), and a daemon that merely
    /// missed a probe while busy must not get a second session spawned on top of
    /// it. Callers asking "can I still use it?" want `sessionReachability`.
    static func sessionExists(name: String, backend: String) -> Bool {
        switch backend {
        case "seahelmd":
            let list = ProcessRunner.output([SeahelmdLocator.executable(), "list"]) ?? ""
            return parseSeahelmdSessionNames(listOutput: list).contains(name)
        default:
            return false
        }
    }

    /// Live reachability of `name`. Spawns `seahelmd list`, which is slow precisely
    /// when sessions are wedged — call off the main thread.
    ///
    /// A `seahelmd list` that fails outright reads as `.missing`, which on its own
    /// never triggers a teardown (see `SeahelmdSessionRecovery.plan`).
    static func sessionReachability(name: String, backend: String) -> SessionReachability {
        guard backend == "seahelmd" else { return .missing }
        let list = ProcessRunner.output([SeahelmdLocator.executable(), "list"]) ?? ""
        return reachability(of: name, listOutput: list)
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
        guard backend == "seahelmd" else { return false }
        if sessionExists(name: name, backend: backend) { return false }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let commands = detachedLaunchCommands(
            backend: backend, name: name, cwd: cwd,
            agentCommandLine: agentCommandLine, shell: shell
        )
        guard !commands.isEmpty else { return false }
        // The session daemon starts where it is spawned. Without this, exiting
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
    /// the session is spawned on a detached thread and the caller waits only for
    /// it to come up.
    static func waitUntilSessionExists(name: String, backend: String, timeoutSeconds: Double) -> Bool {
        guard backend == "seahelmd" else { return true }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if sessionExists(name: name, backend: backend) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return sessionExists(name: name, backend: backend)
    }
}
