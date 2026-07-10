import Foundation

/// Process-management helpers for zmx session recovery: seeding a fresh
/// session, deciding when to recover, and force-killing stale daemons.
/// These are subprocess/filesystem concerns, kept separate from Station's
/// surface lifecycle.
enum ZmxSessionRecovery {
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

    /// Decide whether a zmx-attached surface should be torn down and re-attached.
    /// A freshly-attached shell legitimately shows a blank/short viewport for the
    /// first few seconds, so an empty viewport must NOT trigger recovery — only a
    /// genuinely exited attach process (the session is gone) warrants it. Keying
    /// on "viewport empty" was killing live plain-terminal panes, leaving them
    /// unresponsive until the user closed them with Cmd+W.
    static func shouldRecover(processExited: Bool) -> Bool {
        processExited
    }

    /// Kill a zmx session, force-killing the daemon process and removing the
    /// socket file if the graceful `zmx kill` fails (e.g. unreachable session).
    static func forceKillSession(_ sessionName: String) {
        // Try graceful kill first
        ProcessRunner.runSync([ZmxLocator.executable(), "kill", sessionName])

        // Check if session is still alive by parsing `zmx list`
        guard let listOutput = ProcessRunner.output([ZmxLocator.executable(), "list"]) else { return }
        let stillAlive = listOutput
            .components(separatedBy: "\n")
            .contains { $0.contains("name=\(sessionName)") }
        guard stillAlive else { return }

        NSLog("ZmxSessionRecovery: zmx session '%@' still alive after kill — force cleaning", sessionName)

        // Find and kill the daemon process via its socket
        if let socketDir = socketDir() {
            let socketPath = (socketDir as NSString).appendingPathComponent(sessionName)
            // Use lsof to find the PID holding the socket
            if let lsofOutput = ProcessRunner.output(["lsof", "-t", socketPath]),
               let pid = Int32(lsofOutput.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
                NSLog("ZmxSessionRecovery: sent SIGKILL to zmx daemon pid %d", pid)
                // Brief wait for process to exit
                usleep(100_000) // 100ms
            }
            // Remove the stale socket file
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

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
