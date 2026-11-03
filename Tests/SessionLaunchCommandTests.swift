import XCTest
@testable import seahelm

final class SessionLaunchCommandTests: XCTestCase {
    private let facts = ["SEAHELMD_FACTS=fg=cdd6f4 bg=1e1e2e cursor=f5e0dc dark=1"]

    private func launch(name: String = "seahelm-repo-feat", cwd: String = "/work/repo/feat",
                        agent: String = "claude 'fix bug'", terminfoPath: String? = "/res/terminfo") -> [String] {
        let cmds = SessionManager.detachedLaunchCommands(
            backend: "seahelmd", name: name, cwd: cwd, agentCommandLine: agent,
            shell: "/bin/zsh", terminfoPath: terminfoPath, daemon: "/opt/seahelmd", facts: facts)
        XCTAssertEqual(cmds.count, 1)
        return cmds.first ?? []
    }

    /// The agent is the session's own program, held until the pane attaches, and
    /// a login shell takes over when it exits. Nothing is typed, nothing polls.
    func testLaunchIsTheSessionsProgramHeldForThePane() {
        let socket = ControlSocketServer.defaultSocketPath()
        let inner = "{ export SEAHELM_ENV=1 SEAHELM_SOCKET_PATH=\(ShellEscape.singleQuote(socket))"
            + " SEAHELM_PANE_ID='seahelm-repo-feat'"
            + " && cd '/work/repo/feat'"
            + " && printf '\\033[2J\\033[3J\\033[H' && claude 'fix bug'; }; exec '/bin/zsh' -l"
        XCTAssertEqual(
            launch(),
            ["TERM=xterm-ghostty", "TERMINFO=/res/terminfo"] + facts
                + ["/opt/seahelmd", "new", "--hold", String(SessionManager.clientWaitSeconds),
                   "seahelm-repo-feat", "--", "/bin/zsh", "-lic", inner]
        )
    }

    /// Regression: a Finder-launched build inherits launchd's environment, which
    /// carries no TERM. `clear` then exited 1 and short-circuited the `&&` chain
    /// before the agent was ever exec'd — the worktree came up with a bare shell.
    /// The launch line must both carry a TERM of its own and clear the screen
    /// without consulting terminfo.
    func testLaunchCarriesTerminalEnvironmentAndTerminfoFreeClear() {
        let argv = launch(agent: "claude")
        XCTAssertEqual(Array(argv.prefix(2)), ["TERM=xterm-ghostty", "TERMINFO=/res/terminfo"])
        let inner = argv.last ?? ""
        XCTAssertFalse(inner.contains(" clear "))
        XCTAssertTrue(inner.contains(TerminalEnvironment.clearScreenCommand))
    }

    /// Without the bundled database `xterm-ghostty` is unresolvable, so fall
    /// back to a TERM that /usr/share/terminfo always has.
    func testLaunchFallsBackWhenBundledTerminfoMissing() {
        let argv = launch(terminfoPath: nil)
        XCTAssertEqual(argv.first, "TERM=xterm-256color")
        XCTAssertFalse(argv.contains { $0.hasPrefix("TERMINFO=") })
    }

    /// The palette the daemon answers with while the pane is not there yet.
    func testLaunchPassesThePaletteToTheDaemon() {
        XCTAssertTrue(launch().contains(facts[0]))
    }

    func testUnknownBackendReturnsEmpty() {
        XCTAssertTrue(SessionManager.detachedLaunchCommands(
            backend: "local",
            name: "n", cwd: "/c", agentCommandLine: "claude", shell: "/bin/zsh",
            terminfoPath: nil
        ).isEmpty)
    }

    /// For real, against the bundled daemon: the launch creates the session
    /// without starting the agent, an attach starts it at the pane's size, and
    /// a shell is left when it exits.
    func testLaunchAgainstTheBundledDaemon() throws {
        guard SeahelmdLocator.isAvailable else { throw XCTSkip("no seahelmd in this build") }
        let dir = "/tmp/shd-xc-\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let name = "seahelm-launch-test"
        var argv = SessionManager.detachedLaunchCommands(
            backend: "seahelmd", name: name, cwd: NSTemporaryDirectory(),
            agentCommandLine: "echo agent-at-$(stty size); sleep 1",
            shell: "/bin/zsh", terminfoPath: nil, daemon: SeahelmdLocator.executable(), facts: facts)[0]
        argv.insert("SEAHELMD_DIR=\(dir)", at: 0)
        ProcessRunner.runSync(argv, currentDirectory: NSTemporaryDirectory())
        let env = ["/usr/bin/env", "SEAHELMD_DIR=\(dir)", SeahelmdLocator.executable()]
        let held = ProcessRunner.output(env + ["list"]) ?? ""
        XCTAssertTrue(held.contains("name=\(name)\tpid=\t"), "the agent started before its pane: \(held)")

        // A pane: attach from a pty sized 33x111.
        let script = "import os,pty,fcntl,termios,struct,time,select,sys\n"
            + "pid,fd=pty.fork()\n"
            + "if pid==0: os.execv(sys.argv[1],[sys.argv[1],'attach',sys.argv[2]])\n"
            + "fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',33,111,0,0))\n"
            + "end=time.time()+3\n"
            + "while time.time()<end:\n"
            + "  r,_,_=select.select([fd],[],[],0.1)\n"
            + "  if r:\n"
            + "    try: os.read(fd,65536)\n"
            + "    except OSError: break\n"
            + "os.write(fd,b'\\x1c'); os.waitpid(pid,0)\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", script, SeahelmdLocator.executable(), name]
        p.environment = ["SEAHELMD_DIR": dir]
        try p.run()
        p.waitUntilExit()
        let history = ProcessRunner.output(env + ["history", name]) ?? ""
        XCTAssertTrue(history.contains("agent-at-33 111"), history)
        let after = ProcessRunner.output(env + ["list"]) ?? ""
        XCTAssertTrue(after.contains("cmd=zsh"), "no shell left behind the agent: \(after)")
        ProcessRunner.runSync(env + ["kill", name])
    }

    /// Regression: the session must start in the worktree. Spawned from
    /// Seahelm's own launch directory, the shell left after the agent exited sat
    /// there (the inner `cd` only affects `zsh -lic`).
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
