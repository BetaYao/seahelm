import Foundation

/// Ends the zmx sessions an earlier seahelm left running.
///
/// Sessions moved to seahelmd, and without zmx in the bundle nothing can
/// attach to the ones still running from before the upgrade. Left alone, each
/// keeps its agent working where nobody can see it — while the pane, finding
/// no session, starts that agent again with `--resume` on the same
/// conversation. So the first launch ends them, as a reboot would, and panes
/// come back on seahelmd with their agents resumed. Runs before any pane is
/// restored; on later launches the directory is empty and it does nothing.
///
/// Only sessions seahelm named (`seahelm-`, `amux-`): a zmx session the user
/// started by hand is theirs.
enum LegacyZmxSessions {
    /// Where zmx kept its sockets: `$ZMX_DIR`, `$XDG_RUNTIME_DIR/zmx`, else
    /// `$TMPDIR/zmx-<uid>` — zmx's own rule (its src/cfg.zig).
    static func socketDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let dir = environment["ZMX_DIR"] { return dir }
        if let runtime = environment["XDG_RUNTIME_DIR"] { return runtime + "/zmx" }
        var tmp = environment["TMPDIR"] ?? "/tmp"
        while tmp.count > 1, tmp.hasSuffix("/") { tmp.removeLast() }
        return "\(tmp)/zmx-\(getuid())"
    }

    /// The entries of the socket directory that are seahelm's sessions.
    static func managedSessions(in entries: [String]) -> [String] {
        entries.filter { $0.hasPrefix("seahelm-") || $0.hasPrefix("amux-") }.sorted()
    }

    /// End every managed session: SIGTERM to each process holding its socket
    /// (the daemon, and any attach client), SIGKILL to what is still there half
    /// a second later, then the socket goes. Closing the daemon's PTY is what
    /// hangs up the shell and the agent in it. Returns the names ended.
    @discardableResult
    static func endAll(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let dir = socketDir(environment: environment)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let names = managedSessions(in: entries)
        guard !names.isEmpty else { return [] }
        let sockets = names.map { "\(dir)/\($0)" }
        let pids = (ProcessRunner.output(["/usr/sbin/lsof", "-t"] + sockets, timeout: 5) ?? "")
            .components(separatedBy: .newlines)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        let unique = Array(Set(pids)).filter { $0 > 1 && $0 != getpid() }
        NSLog("[LegacyZmxSessions] Ending %d zmx session(s) from before seahelmd (%d process(es)): %@",
              names.count, unique.count, names.joined(separator: ", "))
        for pid in unique { kill(pid, SIGTERM) }
        if !unique.isEmpty {
            usleep(500_000)
            for pid in unique where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        for socket in sockets { try? FileManager.default.removeItem(atPath: socket) }
        return names
    }
}
