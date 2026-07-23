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
        var execBasename: String {
            (argv.first.map { ($0 as NSString).lastPathComponent } ?? "").lowercased()
        }
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
            for m in manifests where m.process?.execNames.contains(p.execBasename) == true {
                return m.id
            }
        }
        // Pass 2: argv_contains, prioritizing processes whose argv0 is a generic
        // runtime (the wrapper case), then any process.
        for p in procs {
            for m in manifests {
                guard let pm = m.process, !pm.argvContains.isEmpty else { continue }
                let isGeneric = pm.genericRuntimes.contains(p.execBasename)
                let hit = p.argv.contains { token in
                    let t = token.lowercased()
                    return pm.argvContains.contains { t.contains($0) }
                }
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

    /// One sysctl walk: agent identity (if any) + foreground command line.
    static func probeSession(paneSessionKey: String) -> (agentId: String?, commandLine: String?) {
        guard let out = ProcessRunner.output([ZmxLocator.executable(), "list"]),
              let root = sessionPid(paneSessionKey: paneSessionKey, zmxListOutput: out) else {
            return (nil, nil)
        }
        let descendants = descendants(of: root, in: allProcesses())
        guard !descendants.isEmpty else { return (nil, nil) }
        let agentId = identify(procs: descendants, manifests: ManifestStore.shared.all.map(\.manifest))
        return (agentId, foregroundCommandLine(from: descendants))
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

    /// Enumerate all processes with pid/ppid/argv via sysctl.
    static func allProcesses() -> [Proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let actual = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(actual).map { kp in
            let pid = kp.kp_proc.p_pid
            let ppid = kp.kp_eproc.e_ppid
            return Proc(pid: pid, ppid: ppid, argv: argv(of: pid))
        }
    }

    /// Read a process's argv via KERN_PROCARGS2. Returns [] on failure.
    static func argv(of pid: Int32) -> [String] {
        var argmax = 0
        var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var maxSize = MemoryLayout<Int>.size
        guard sysctl(&mibMax, 2, &argmax, &maxSize, nil, 0) == 0, argmax > 0 else { return [] }

        var buf = [CChar](repeating: 0, count: argmax)
        var size = argmax
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size >= MemoryLayout<Int32>.size else { return [] }

        let bytes = buf.prefix(size).map { UInt8(bitPattern: $0) }
        let argc = bytes.withUnsafeBytes { $0.load(as: Int32.self) }
        // Layout: [argc:4][exec_path\0][padding\0...][argv0\0 argv1\0 ...]
        var result: [String] = []
        var i = MemoryLayout<Int32>.size
        while i < bytes.count && bytes[i] != 0 { i += 1 }      // skip exec_path
        while i < bytes.count && bytes[i] == 0 { i += 1 }      // skip padding NULs
        var collected: Int32 = 0
        while i < bytes.count && collected < argc {
            let start = i
            while i < bytes.count && bytes[i] != 0 { i += 1 }
            if i > start {
                result.append(String(decoding: bytes[start..<i], as: UTF8.self))
            }
            i += 1
            collected += 1
        }
        return result
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
