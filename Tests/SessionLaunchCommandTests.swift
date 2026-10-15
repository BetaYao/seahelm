import XCTest
@testable import seahelm

final class SessionLaunchCommandTests: XCTestCase {
    func testZmxBuildsRunWithShellWrapperAndCd() {
        let cmds = SessionManager.detachedLaunchCommands(
            backend: "zmx",
            name: "seahelm-repo-feat",
            cwd: "/work/repo/feat",
            agentCommandLine: "claude 'fix bug'",
            shell: "/bin/zsh",
            terminfoPath: "/Apps/Seahelm.app/Contents/Resources/terminfo"
        )
        XCTAssertEqual(cmds.count, 1)
        let socket = ControlSocketServer.defaultSocketPath()
        let inner = "export SEAHELM_ENV=1 SEAHELM_SOCKET_PATH=\(ShellEscape.singleQuote(socket))"
            + " SEAHELM_PANE_ID='seahelm-repo-feat'"
            + " && cd '/work/repo/feat'"
            + " && " + SessionManager.waitForClientCommand(zmx: ZmxLocator.executable(),
                                                           name: "seahelm-repo-feat")
            + " && printf '\\033[2J\\033[3J\\033[H' && claude 'fix bug'"
        XCTAssertEqual(
            cmds[0],
            ["TERM=xterm-ghostty", "TERMINFO=/Apps/Seahelm.app/Contents/Resources/terminfo",
             ZmxLocator.executable(), "run", "seahelm-repo-feat", "/bin/zsh", "-lic", inner]
        )
    }

    /// Regression: a Finder-launched build inherits launchd's environment, which
    /// carries no TERM. `clear` then exited 1 and short-circuited the `&&` chain
    /// before the agent was ever exec'd — the worktree came up with a bare shell.
    /// The launch line must both carry a TERM of its own and clear the screen
    /// without consulting terminfo.
    func testZmxLaunchCarriesTerminalEnvironmentAndTerminfoFreeClear() {
        let cmds = SessionManager.detachedLaunchCommands(
            backend: "zmx", name: "n", cwd: "/c", agentCommandLine: "claude",
            shell: "/bin/zsh", terminfoPath: "/res/terminfo"
        )
        XCTAssertEqual(Array(cmds[0].prefix(2)),
                       ["TERM=xterm-ghostty", "TERMINFO=/res/terminfo"])
        let inner = cmds[0].last ?? ""
        XCTAssertFalse(inner.contains(" clear "))
        XCTAssertTrue(inner.contains(TerminalEnvironment.clearScreenCommand))
    }

    /// Without the bundled database `xterm-ghostty` is unresolvable, so fall
    /// back to a TERM that /usr/share/terminfo always has.
    func testZmxLaunchFallsBackWhenBundledTerminfoMissing() {
        let cmds = SessionManager.detachedLaunchCommands(
            backend: "zmx", name: "n", cwd: "/c", agentCommandLine: "claude",
            shell: "/bin/zsh", terminfoPath: nil
        )
        XCTAssertEqual(cmds[0].first, "TERM=xterm-256color")
        XCTAssertFalse(cmds[0].contains { $0.hasPrefix("TERMINFO=") })
    }

    /// The agent must not start before a client is attached: its startup
    /// terminal queries (OSC 7501, OSC 10/11) are answered only by a client.
    func testZmxLaunchHoldsTheAgentUntilAClientAttaches() {
        let inner = SessionManager.detachedLaunchCommands(
            backend: "zmx", name: "seahelm-repo-feat.x", cwd: "/c", agentCommandLine: "claude",
            shell: "/bin/zsh", terminfoPath: nil
        )[0].last ?? ""
        let wait = SessionManager.waitForClientCommand(zmx: ZmxLocator.executable(),
                                                       name: "seahelm-repo-feat.x")
        let waitAt = inner.range(of: wait)?.lowerBound
        let agentAt = inner.range(of: "&& claude")?.lowerBound
        XCTAssertNotNil(waitAt)
        XCTAssertNotNil(agentAt)
        if let waitAt, let agentAt { XCTAssertLessThan(waitAt, agentAt) }
        XCTAssertTrue(wait.contains(#"name=seahelm-repo-feat\.x[[:space:]]"#),
                      "the name is matched literally, not as a regex")
    }

    /// Run the wait for real against a fake `zmx` whose `list` reads its rows
    /// from a file: it returns once the session's client count rises — the `zmx
    /// run` already holding one does not count — and gives up (successfully)
    /// when no client comes.
    func testWaitForClientCommandWaitsForTheCountToRise() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-wait-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("zmx")
        let rows = dir.appendingPathComponent("rows")
        try "#!/bin/sh\ncat \(ShellEscape.singleQuote(rows.path))\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        func setRows(s1 clients: Int) throws {
            // `s-10` is busy throughout and must never count for `s-1`.
            try "  name=s-10\tpid=1\tclients=3\n  name=s-1\tpid=2\tclients=\(clients)\tcreated=0\n"
                .write(to: rows, atomically: true, encoding: .utf8)
        }
        func start() -> (Process, Date) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", SessionManager.waitForClientCommand(zmx: fake.path, name: "s-1")]
            try? p.run()
            return (p, Date())
        }

        try setRows(s1: 1)   // just the `zmx run` client
        let (attach, t0) = start()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(attach.isRunning, "one client is the run itself; keep waiting")
        try setRows(s1: 2)
        attach.waitUntilExit()
        XCTAssertEqual(attach.terminationStatus, 0)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)

        try setRows(s1: 1)
        let (alone, t1) = start()
        alone.waitUntilExit()
        XCTAssertEqual(alone.terminationStatus, 0, "gives up successfully so the agent still starts")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t1), Double(SessionManager.clientWaitSeconds) - 1)
    }

    func testUnknownBackendReturnsEmpty() {
        XCTAssertTrue(SessionManager.detachedLaunchCommands(
            backend: "local",
            name: "n", cwd: "/c", agentCommandLine: "claude", shell: "/bin/zsh",
            terminfoPath: nil
        ).isEmpty)
    }

    /// Regression: the outer zmx session shell must inherit the worktree cwd.
    /// Spawning `zmx run` from Seahelm's own launch directory left the shell
    /// there after the agent exited (the inner `cd` only affects `zsh -lic`).
    func testRunSyncHonorsCurrentDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let out = tmp.appendingPathComponent("pwd.txt")
        ProcessRunner.runSync(
            ["/bin/sh", "-c", "pwd > \(ShellEscape.singleQuote(out.path))"],
            currentDirectory: tmp.path)
        let pwd = try String(contentsOf: out, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            URL(fileURLWithPath: pwd).resolvingSymlinksInPath().path,
            tmp.resolvingSymlinksInPath().path)
    }
}
