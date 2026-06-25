import XCTest
@testable import seahelm

final class SessionLaunchCommandTests: XCTestCase {
    func testTmuxBuildsNewSessionThenSendKeys() {
        let cmds = SessionManager.detachedLaunchCommands(
            backend: "tmux",
            name: "amux-repo-feat",
            cwd: "/work/repo/feat",
            agentCommandLine: "claude 'fix bug'",
            shell: "/bin/zsh"
        )
        XCTAssertEqual(cmds.count, 2)
        XCTAssertEqual(
            cmds[0],
            ["tmux", "new-session", "-d", "-s", "amux-repo-feat", "-c", "/work/repo/feat"]
        )
        XCTAssertEqual(
            cmds[1],
            ["tmux", "send-keys", "-t", "amux-repo-feat", "clear && claude 'fix bug'", "Enter"]
        )
    }

    func testZmxBuildsRunWithShellWrapperAndCd() {
        let cmds = SessionManager.detachedLaunchCommands(
            backend: "zmx",
            name: "amux-repo-feat",
            cwd: "/work/repo/feat",
            agentCommandLine: "claude 'fix bug'",
            shell: "/bin/zsh"
        )
        XCTAssertEqual(cmds.count, 1)
        XCTAssertEqual(
            cmds[0],
            [
                "zmx", "run", "amux-repo-feat",
                "/bin/zsh", "-lic",
                "cd '/work/repo/feat' && clear && claude 'fix bug'",
            ]
        )
    }

    func testUnknownBackendReturnsEmpty() {
        XCTAssertTrue(SessionManager.detachedLaunchCommands(
            backend: "local",
            name: "n", cwd: "/c", agentCommandLine: "claude", shell: "/bin/zsh"
        ).isEmpty)
    }
}
