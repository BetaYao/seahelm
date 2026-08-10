import Foundation

/// Identifies which agent runs in a pane by walking the process tree, instead of
/// scraping the agent's name off the screen. The pane's persistent session runs
/// under the zmx daemon (not our Ghostty child), so the entry point is the
/// session's shell pid from `zmx list`; from there we enumerate descendants and
/// match their argv against each manifest's `process` block, penetrating generic
/// runtimes (node → codex).
enum ProcessProbe {

    // MARK: - Pure matching (unit-tested)

    /// Extract `pid=<N>` for `paneSessionKey` from `zmx list` output, or nil.
    static func sessionPid(paneSessionKey: String, zmxListOutput: String) -> Int32? {
        for line in zmxListOutput.split(separator: "\n") {
            let s = String(line)
            guard field(s, "name=") == paneSessionKey else { continue }
            if let pidStr = field(s, "pid="), let pid = Int32(pidStr) { return pid }
        }
        return nil
    }

    /// One process's identity for matching.
    struct Proc {
        let pid: Int32
        let ppid: Int32
        let argv: [String]
        let residentBytes: UInt64?

        init(pid: Int32, ppid: Int32, argv: [String], residentBytes: UInt64? = nil) {
            self.pid = pid
            self.ppid = ppid
            self.argv = argv
            self.residentBytes = residentBytes
        }

        var execBasename: String {
            (argv.first.map { ($0 as NSString).lastPathComponent } ?? "").lowercased()
        }
    }

    struct SessionMemory: Equatable {
        let totalBytes: UInt64
        let agentBytes: UInt64
        let processName: String?
    }

    /// Given the descendant processes of a session (any order) and the loaded
    /// manifests, return the manifest id of the agent running in the pane, or nil.
    /// A process matches a manifest when its argv0 basename is in `exec_names`, or
    /// (when argv0 is a generic runtime, or `argv_contains` is set) any argv token
    /// contains one of `argv_contains`. More specific (`exec_names`) wins over the
    /// generic-runtime drill.
    static func identify(procs: [Proc], manifests: [AgentManifest]) -> String? {
        // Pass 1: direct exec_names match (most specific).
        for p in procs {
            for m in manifests where directlyMatches(p, manifest: m) {
                return m.id
            }
        }
        // Pass 2: argv_contains, prioritizing processes whose argv0 is a generic
        // runtime (the wrapper case), then any process.
        for p in procs {
            for m in manifests {
                guard let pm = m.process, !pm.argvContains.isEmpty else { continue }
                let isGeneric = pm.genericRuntimes.contains(p.execBasename)
                let hit = argvMatches(p, manifest: m)
                if hit && (isGeneric || pm.genericRuntimes.isEmpty) { return m.id }
            }
        }
        return nil
    }

    /// Resolve an agent id from an `env_hint` value carried in a process's env, if
    /// a manifest declares that hint. (env is read separately; this is pure.)
    static func identifyByEnvHint(_ envValue: String, manifests: [AgentManifest]) -> String? {
        manifests.first { $0.process?.envHint != nil && $0.id == envValue }?.id
    }

    // MARK: - System probe (macOS, isolated)

    /// Full identification for a live session: read the session pid from zmx,
    /// enumerate its descendants, and match against the manifest store.
    static func identifyAgent(paneSessionKey: String) -> String? {
        probeSession(paneSessionKey: paneSessionKey).agentId
    }

    /// Everything a probe needs from the system, captured once and shared by every
    /// pane in a poll cycle. Both halves are identical for all panes, and paying
    /// for them per pane — one `zmx list` fork plus one full process walk each —
    /// was what pinned a core with the app idle.
    struct ProbeContext {
        let zmxListOutput: String
        let table: [Proc]

        static func capture() -> ProbeContext? {
            guard let out = ProcessRunner.output([ZmxLocator.executable(), "list"]) else { return nil }
            return ProbeContext(zmxListOutput: out, table: processTable())
        }
    }

    /// One sysctl walk: agent identity (if any) + foreground command line.
    static func probeSession(paneSessionKey: String) -> (agentId: String?, commandLine: String?) {
        guard let context = ProbeContext.capture() else { return (nil, nil) }
        return probeSession(paneSessionKey: paneSessionKey, context: context)
    }

    /// As above, against a context already captured for this cycle.
    static func probeSession(
        paneSessionKey: String,
        context: ProbeContext
    ) -> (agentId: String?, commandLine: String?) {
        guard let root = sessionPid(paneSessionKey: paneSessionKey,
                                    zmxListOutput: context.zmxListOutput) else {
            return (nil, nil)
        }
        // argv is read only for this session's own descendants — a handful —
        // rather than for every process on the machine, almost all of which the
        // very next line would have discarded.
        let descendants = withArgv(descendants(of: root, in: context.table))
        guard !descendants.isEmpty else { return (nil, nil) }
        let agentId = identify(procs: descendants, manifests: ManifestStore.shared.all.map(\.manifest))
        return (agentId, foregroundCommandLine(from: descendants))
    }

    /// Aggregate memory under a zmx session root. `totalBytes` includes the root
    /// process (usually the session shell) and all descendants. `agentBytes`
    /// includes any recognized agent process and its children, so Claude Code's
    /// node/helper subprocesses are counted with the agent rather than only the
    /// thin launcher process.
    static func memory(rootPid: Int32, in all: [Proc], manifests: [AgentManifest]) -> SessionMemory {
        let descendants = descendants(of: rootPid, in: all)
        let root = all.first { $0.pid == rootPid }
        let sessionProcs = (root.map { [$0] } ?? []) + descendants
        let total = uniqueMemoryBytes(sessionProcs)

        var childrenOf: [Int32: [Proc]] = [:]
        for p in all { childrenOf[p.ppid, default: []].append(p) }

        let agentRoots = descendants.filter { processMatchesAnyAgent($0, manifests: manifests) }
        var agentPids = Set<Int32>()
        for root in agentRoots {
            collect(root.pid, childrenOf: childrenOf, into: &agentPids)
        }
        let byPid = Dictionary(uniqueKeysWithValues: all.map { ($0.pid, $0) })
        let agentProcs = agentPids.compactMap { byPid[$0] }
        let agent = uniqueMemoryBytes(agentProcs)

        return SessionMemory(
            totalBytes: total,
            agentBytes: agent,
            processName: foregroundCommandLine(from: descendants)
        )
    }

    /// Human-facing command for pane titles: prefer a non-shell leaf under the
    /// session shell (e.g. `brew update` over a `bash -c` wrapper).
    static func foregroundCommandLine(from procs: [Proc]) -> String? {
        let candidates = procs.filter { !isShellBasename($0.execBasename) && !$0.argv.isEmpty }
        guard !candidates.isEmpty else { return nil }
        let leaves = candidates.filter { cand in
            !candidates.contains { $0.ppid == cand.pid }
        }
        let pick = leaves.last ?? candidates.last
        guard let pick else { return nil }
        return displayCommandLine(argv: pick.argv)
    }

    private static let shellBasenames: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "login",
    ]

    private static func isShellBasename(_ name: String) -> Bool {
        shellBasenames.contains(name)
    }

    /// Basename argv0 so titles read `brew update` not `/opt/homebrew/bin/brew update`.
    private static func displayCommandLine(argv: [String]) -> String {
        guard let first = argv.first else { return "" }
        let head = (first as NSString).lastPathComponent
        if argv.count == 1 { return head }
        return ([head] + argv.dropFirst()).joined(separator: " ")
    }

    /// Collect the descendant processes (excluding the root shell itself) of `root`.
    static func descendants(of root: Int32, in all: [Proc]) -> [Proc] {
        var childrenOf: [Int32: [Proc]] = [:]
        for p in all { childrenOf[p.ppid, default: []].append(p) }
        var result: [Proc] = []
        var stack = childrenOf[root] ?? []
        while let p = stack.popLast() {
            result.append(p)
            if let kids = childrenOf[p.pid] { stack.append(contentsOf: kids) }
        }
        return result
    }

    /// Enumerate all processes with pid/ppid/argv (plus rss) via sysctl. Callers
    /// that only need the tree shape should use `processTable()` — this reads
    /// argv for every process on the machine and forks `ps` for the rss map.
    static func allProcesses() -> [Proc] {
        let rss = residentBytesByPid()
        var buffer = [CChar](repeating: 0, count: argMax)
        return kinfoProcs().map { kp in
            let pid = kp.kp_proc.p_pid
            return Proc(pid: pid,
                        ppid: kp.kp_eproc.e_ppid,
                        argv: argv(of: pid, buffer: &buffer),
                        residentBytes: rss[pid])
        }
    }

    /// pid/ppid only. Walking the tree needs neither argv nor rss, so this skips
    /// both the per-process `KERN_PROCARGS2` reads and the `ps` fork.
    static func processTable() -> [Proc] {
        kinfoProcs().map { Proc(pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid, argv: []) }
    }

    /// Resident bytes of one session's whole process tree, root included.
    ///
    /// Deliberately not `memory(rootPid:in:manifests:)`: that splits the total
    /// into an agent share, which needs argv on every process to match manifests
    /// — the read that used to pin a core. A headline figure only needs the tree
    /// shape (sysctl) and an rss map (one `ps`), so this stays cheap enough to
    /// sit on a UI refresh.
    static func sessionResidentBytes(paneSessionKey: String, zmxListOutput: String) -> UInt64? {
        guard let root = sessionPid(paneSessionKey: paneSessionKey, zmxListOutput: zmxListOutput) else {
            return nil
        }
        let rss = residentBytesByPid()
        let table = processTable().map {
            Proc(pid: $0.pid, ppid: $0.ppid, argv: [], residentBytes: rss[$0.pid])
        }
        let tree = (table.first { $0.pid == root }.map { [$0] } ?? []) + descendants(of: root, in: table)
        guard !tree.isEmpty else { return nil }
        return uniqueMemoryBytes(tree)
    }

    /// Read argv for a chosen few, reusing one buffer across the batch.
    static func withArgv(_ procs: [Proc]) -> [Proc] {
        guard !procs.isEmpty else { return [] }
        var buffer = [CChar](repeating: 0, count: argMax)
        return procs.map {
            Proc(pid: $0.pid,
                 ppid: $0.ppid,
                 argv: argv(of: $0.pid, buffer: &buffer),
                 residentBytes: $0.residentBytes)
        }
    }

    private static func kinfoProcs() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return Array(procs.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    /// `kern.argmax` is fixed for the life of the boot (1 MB on current macOS).
    /// It used to be re-read on every `argv(of:)` call.
    private static let argMax: Int = {
        var value = 0
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var size = MemoryLayout<Int>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 256 * 1024 }
        return value
    }()

    /// Read a process's argv via KERN_PROCARGS2. Returns [] on failure.
    static func argv(of pid: Int32) -> [String] {
        var buffer = [CChar](repeating: 0, count: argMax)
        return argv(of: pid, buffer: &buffer)
    }

    /// Parses straight out of `buffer`. The previous version allocated a fresh
    /// 1 MB zero-filled buffer per process and then copied the whole thing again
    /// to reinterpret it as bytes — together the top entry of every CPU profile.
    private static func argv(of pid: Int32, buffer: inout [CChar]) -> [String] {
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size >= MemoryLayout<Int32>.size else { return [] }
        let byteCount = size
        return buffer.withUnsafeBufferPointer { raw in
            guard let base = raw.baseAddress else { return [] }
            return base.withMemoryRebound(to: UInt8.self, capacity: byteCount) {
                parseProcArgs2($0, count: byteCount)
            }
        }
    }

    /// Layout: `[argc:4][exec_path\0][padding\0...][argv0\0 argv1\0 ...]`.
    private static func parseProcArgs2(_ bytes: UnsafePointer<UInt8>, count: Int) -> [String] {
        let argc = Int(UnsafeRawPointer(bytes).loadUnaligned(as: Int32.self))
        guard argc > 0 else { return [] }
        var result: [String] = []
        var i = MemoryLayout<Int32>.size
        while i < count && bytes[i] != 0 { i += 1 }      // skip exec_path
        while i < count && bytes[i] == 0 { i += 1 }      // skip padding NULs
        var collected = 0
        while i < count && collected < argc {
            let start = i
            while i < count && bytes[i] != 0 { i += 1 }
            if i > start {
                result.append(String(decoding: UnsafeBufferPointer(start: bytes + start, count: i - start),
                                     as: UTF8.self))
            }
            i += 1
            collected += 1
        }
        return result
    }

    private static func residentBytesByPid() -> [Int32: UInt64] {
        guard let output = ProcessRunner.output(["ps", "-axo", "pid=,rss="]) else { return [:] }
        var result: [Int32: UInt64] = [:]
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let pid = Int32(parts[0]),
                  let rssKB = UInt64(parts[1]) else { continue }
            result[pid] = rssKB * 1024
        }
        return result
    }

    private static func directlyMatches(_ p: Proc, manifest m: AgentManifest) -> Bool {
        m.process?.execNames.contains(p.execBasename) == true
    }

    private static func argvMatches(_ p: Proc, manifest m: AgentManifest) -> Bool {
        guard let pm = m.process, !pm.argvContains.isEmpty else { return false }
        return p.argv.contains { token in
            let t = token.lowercased()
            return pm.argvContains.contains { t.contains($0) }
        }
    }

    private static func processMatchesAnyAgent(_ p: Proc, manifests: [AgentManifest]) -> Bool {
        manifests.contains { m in
            directlyMatches(p, manifest: m) || argvMatches(p, manifest: m)
        }
    }

    private static func collect(_ pid: Int32, childrenOf: [Int32: [Proc]], into pids: inout Set<Int32>) {
        guard pids.insert(pid).inserted else { return }
        for child in childrenOf[pid] ?? [] {
            collect(child.pid, childrenOf: childrenOf, into: &pids)
        }
    }

    private static func uniqueMemoryBytes(_ procs: [Proc]) -> UInt64 {
        var seen = Set<Int32>()
        return procs.reduce(UInt64(0)) { total, proc in
            guard seen.insert(proc.pid).inserted else { return total }
            return total + (proc.residentBytes ?? 0)
        }
    }

    // MARK: - Field parsing helpers

    private static func field(_ line: String, _ key: String) -> String? {
        guard let r = line.range(of: key) else { return nil }
        let suffix = line[r.upperBound...]
        let end = suffix.firstIndex(where: \.isWhitespace) ?? suffix.endIndex
        let v = String(suffix[..<end])
        return v.isEmpty ? nil : v
    }
}
