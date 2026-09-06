import XCTest
@testable import seahelm

final class StationZmxAttachCommandTests: XCTestCase {
    /// Regression: the attach command is a string handed to a shell, so a session
    /// key containing a space was split by the shell. `zmx attach <name> [command...]`
    /// then read the tail as the command to run — a workspace at `~/Bodkin AI`
    /// produced `zmx attach seahelm-me-Bodkin AI`, i.e. session `seahelm-me-Bodkin`
    /// running the command `AI`, which exits non-zero. Every pane for that
    /// workspace failed to launch.
    func testSessionKeyWithSpaceIsQuoted() {
        let command = Station.zmxAttachCommand(paneSessionKey: "seahelm-me-Bodkin AI")
        XCTAssertTrue(
            command.hasSuffix("attach 'seahelm-me-Bodkin AI'"),
            "session key must reach the shell as one argument, got: \(command)"
        )
    }

    func testPlainSessionKeyIsQuoted() {
        let command = Station.zmxAttachCommand(paneSessionKey: "seahelm-me-repo")
        XCTAssertTrue(command.hasSuffix("attach 'seahelm-me-repo'"), command)
    }

    /// A directory name may legitimately contain an apostrophe (`~/Nick's Repo`).
    func testSessionKeyWithApostropheIsEscaped() {
        let command = Station.zmxAttachCommand(paneSessionKey: "seahelm-me-Nick's Repo")
        XCTAssertTrue(command.hasSuffix("attach 'seahelm-me-Nick'\\''s Repo'"), command)
    }

    /// The ZMX_SESSION guard must survive the quoting change: zmx prefers the
    /// environment variable over its argument, so a leaked one would silently
    /// attach every pane to the wrong session.
    func testUnsetsLeakedZmxSession() {
        let command = Station.zmxAttachCommand(paneSessionKey: "seahelm-me-repo")
        XCTAssertTrue(command.hasPrefix("/usr/bin/env -u ZMX_SESSION "), command)
    }
}
