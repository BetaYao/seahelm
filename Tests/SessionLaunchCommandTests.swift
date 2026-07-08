import XCTest
@testable import seahelm

final class SessionLaunchCommandTests: XCTestCase {
    func testZmxBuildsRunWithShellWrapperAndCd() {
        let cmds = SessionManager.detachedLaunchCommands(
            backend: "zmx",
            name: "amux-repo-feat",
            cwd: "/work/repo/feat",
            agentCommandLine: "claude 'fix bug'",
            shell: "/bin/zsh"
        )
        XCTAssertEqual(cmds.count, 1)
        let socket = ControlSocketServer.defaultSocketPath()
        let inner = "export SEAHELM_ENV=1 SEAHELM_SOCKET_PATH=\(ShellEscape.singleQuote(socket))"
            + " && cd '/work/repo/feat' && clear && claude 'fix bug'"
        XCTAssertEqual(
            cmds[0],
            [ZmxLocator.executable(), "run", "amux-repo-feat", "/bin/zsh", "-lic", inner]
        )
    }

    func testUnknownBackendReturnsEmpty() {
        XCTAssertTrue(SessionManager.detachedLaunchCommands(
            backend: "local",
            name: "n", cwd: "/c", agentCommandLine: "claude", shell: "/bin/zsh"
        ).isEmpty)
    }
}
