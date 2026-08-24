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
