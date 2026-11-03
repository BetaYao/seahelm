import XCTest
@testable import seahelm

final class StationSeahelmdAttachCommandTests: XCTestCase {
    /// Regression: the attach command is a string handed to a shell, so a session
    /// key containing a space was split by the shell. `seahelmd attach <name> [command...]`
    /// then read the tail as the command to run — a workspace at `~/Bodkin AI`
    /// produced `seahelmd attach seahelm-me-Bodkin AI`, i.e. session `seahelm-me-Bodkin`
    /// running the command `AI`, which exits non-zero. Every pane for that
    /// workspace failed to launch.
    func testSessionKeyWithSpaceIsQuoted() {
        let command = Station.seahelmdAttachCommand(paneSessionKey: "seahelm-me-Bodkin AI")
        XCTAssertTrue(
            command.hasSuffix("attach 'seahelm-me-Bodkin AI'"),
            "session key must reach the shell as one argument, got: \(command)"
        )
    }

    func testPlainSessionKeyIsQuoted() {
        let command = Station.seahelmdAttachCommand(paneSessionKey: "seahelm-me-repo")
        XCTAssertTrue(command.hasSuffix("attach 'seahelm-me-repo'"), command)
    }

    /// A directory name may legitimately contain an apostrophe (`~/Nick's Repo`).
    func testSessionKeyWithApostropheIsEscaped() {
        let command = Station.seahelmdAttachCommand(paneSessionKey: "seahelm-me-Nick's Repo")
        XCTAssertTrue(command.hasSuffix("attach 'seahelm-me-Nick'\\''s Repo'"), command)
    }
}
