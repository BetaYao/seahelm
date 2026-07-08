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
        XCTAssertEqual(
            cmds[0],
            [
                ZmxLocator.executable(), "run", "amux-repo-feat",
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
