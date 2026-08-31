import Foundation

/// Process-management helpers for zmx session recovery: seeding a fresh
/// session, deciding when to recover, and force-killing stale daemons.
/// These are subprocess/filesystem concerns, kept separate from Station's
/// surface lifecycle.
enum ZmxSessionRecovery {
    /// What to do when a Ghostty surface's `zmx attach` client has exited.
    ///
    /// Important: client disconnect ≠ session death. zmx keeps the daemon (and
    /// any agent inside) alive with `clients=0`. Force-killing a still-living
    /// session on client exit was wiping agents across app restarts.
    enum Plan: Equatable {
        case none
        /// Session daemon still up — re-attach only; never kill.
        case reattach
        /// Session gone — optionally seed an agent resume, then attach (creates).
        case recreate
    }

    /// Seed a zmx session running `agentCommandLine` if one doesn't already
    /// exist, blocking (briefly) until it comes up. Safe no-op when the session
    /// is already alive. Call off the main thread.
    static func seedSessionIfMissing(name: String, cwd: String, agentCommandLine: String) {
        guard !SessionManager.sessionExists(name: name, backend: "zmx") else { return }
        // `zmx run` blocks for the agent's whole lifetime, so spawn it detached
        // and wait only for the session to register.
        Thread.detachNewThread {
            SessionManager.createDetachedSession(
                name: name, backend: "zmx", cwd: cwd, agentCommandLine: agentCommandLine)
        }
        _ = SessionManager.waitUntilSessionExists(name: name, backend: "zmx", timeoutSeconds: 5)
    }

    /// Decide how to recover after a health check.
    ///
    /// A blank viewport alone must never trigger recovery (live shells look empty
    /// for the first few seconds). Two things do: the attach client exited, or the
    /// session's control socket stopped answering.
    ///
    /// That second trigger is why this takes reachability rather than a bare
    /// "does it exist" bool. When the volume holding the zmx binary drops out,
    /// every daemon on it wedges in a spin loop — the process is still there, the
    /// socket file is still there, `zmx list` still prints the row, it just says
    /// `status=unreachable` and nothing can ever attach to it again. Meanwhile the
    /// attach clients hang instead of exiting, so `processExited` stays false.
    /// Read together those two said "healthy session, live client" about a pane
    /// that was permanently blank, and the recovery path never ran at all.
    ///
    /// Callers must confirm an unreachable reading before passing it in: a daemon
    /// too busy to answer one probe looks identical, and recreating that one takes
    /// a working agent with it.
    static func plan(processExited: Bool, reachability: SessionManager.SessionReachability) -> Plan {
        switch reachability {
        case .unreachable:
            // Nothing can attach to a wedged daemon, so it makes no difference
            // whether our own client has noticed yet.
            return .recreate
        case .missing:
            return processExited ? .recreate : .none
        case .reachable:
            return processExited ? .reattach : .none
        }
    }

    /// Kill a zmx session, force-killing the daemon process and removing the
    /// socket file if the graceful `zmx kill` fails (e.g. unreachable session).
    static func forceKillSession(_ paneSessionKey: String) {
        // Try graceful kill first, on a short leash. The sessions most in need of
        // force-killing are exactly the ones whose daemon has stopped reading its
        // socket, and a graceful kill against one of those sits out the default
        // 60s deadline — per pane, on a path the user is waiting behind.
        ProcessRunner.runSync(
            [ZmxLocator.executable(), "kill", paneSessionKey],
            timeout: gracefulKillTimeout
        )

        // Check if session is still alive by parsing `zmx list`. Exact name match:
        // a `contains("name=seahelm-foo")` also matches the row for the adjacent
        // pane `seahelm-foo-1`.
        guard let listOutput = ProcessRunner.output([ZmxLocator.executable(), "list"]) else { return }
        let stillAlive = SessionManager.parseZmxSessionNames(listOutput: listOutput).contains(paneSessionKey)
        guard stillAlive else { return }

        NSLog("ZmxSessionRecovery: zmx session '%@' still alive after kill — force cleaning", paneSessionKey)

        // Find and kill the processes holding the session's socket
        if let socketDir = socketDir() {
            let socketPath = (socketDir as NSString).appendingPathComponent(paneSessionKey)
            // Every pid, not just a lone one: `lsof -t` prints one per line, and a
            // wedged session has the daemon *and* the clients stuck against it on
            // there. Parsing the whole output as a single Int32 quietly yielded nil
            // for any session with a client attached — i.e. the normal case — so
            // this killed nothing and left the daemon spinning behind a deleted
            // socket, which is how 14 of them survived to eat 8 cores.
            if let lsofOutput = ProcessRunner.output(["lsof", "-t", socketPath]) {
                let pids = lsofOutput
                    .components(separatedBy: .newlines)
                    .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                for pid in pids {
                    kill(pid, SIGKILL)
                    NSLog("ZmxSessionRecovery: sent SIGKILL to zmx pid %d holding '%@'", pid, paneSessionKey)
                }
                // Brief wait for the processes to exit
                if !pids.isEmpty { usleep(100_000) } // 100ms
            }
            // Remove the stale socket file
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    /// Deadline for the graceful `zmx kill` attempt before falling back to SIGKILL.
    private static let gracefulKillTimeout: TimeInterval = 5

    /// Parse the zmx socket directory from `zmx version` output.
    private static func socketDir() -> String? {
        guard let versionOutput = ProcessRunner.output([ZmxLocator.executable(), "version"]) else { return nil }
        for line in versionOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("socket_dir") {
                let parts = trimmed.components(separatedBy: CharacterSet.whitespaces)
                return parts.last
            }
        }
        return nil
    }
}
