import XCTest
@testable import seahelm

final class SessionLaunchCommandTests: XCTestCase {
    func testZmxBuildsRunWithShellWrapperAndCd() {
        let cmds = SessionManager.detachedLaunchCommands(
            backend: "zmx",
            name: "seahelm-repo-feat",
            cwd: "/work/repo/feat",
            agentCommandLine: "claude 'fix bug'",
            shell: "/bin/zsh"
        )
        XCTAssertEqual(cmds.count, 1)
        let socket = ControlSocketServer.defaultSocketPath()
        let inner = "export SEAHELM_ENV=1 SEAHELM_SOCKET_PATH=\(ShellEscape.singleQuote(socket))"
            + " SEAHELM_PANE_ID='seahelm-repo-feat'"
            + " && cd '/work/repo/feat' && clear && claude 'fix bug'"
        XCTAssertEqual(
            cmds[0],
            [ZmxLocator.executable(), "run", "seahelm-repo-feat", "/bin/zsh", "-lic", inner]
        )
    }

    func testUnknownBackendReturnsEmpty() {
        XCTAssertTrue(SessionManager.detachedLaunchCommands(
            backend: "local",
            name: "n", cwd: "/c", agentCommandLine: "claude", shell: "/bin/zsh"
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
