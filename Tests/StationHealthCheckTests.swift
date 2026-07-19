import XCTest
@testable import seahelm

final class StationHealthCheckTests: XCTestCase {
    /// Regression: a freshly-attached zmx shell often shows a blank/short viewport
    /// for the first few seconds. The old health check tore such panes down because
    /// the viewport read empty, leaving plain-terminal panes dead (no input, must
    /// Cmd+W). A live attach process must NOT be recovered.
    func testLiveShellWithBlankViewportIsNotRecovered() {
        XCTAssertEqual(
            ZmxSessionRecovery.plan(processExited: false, sessionExists: true),
            .none
        )
        XCTAssertEqual(
            ZmxSessionRecovery.plan(processExited: false, sessionExists: false),
            .none
        )
    }

    /// Attach client died but the zmx daemon (and any agent inside) is still
    /// alive — only re-attach. Force-killing would wipe the user's session.
    func testExitedAttachWithLiveSessionReattachesOnly() {
        XCTAssertEqual(
            ZmxSessionRecovery.plan(processExited: true, sessionExists: true),
            .reattach
        )
    }

    /// Attach exited and the session is gone — recreate (seed agent if we have
    /// a resume ref; otherwise `zmx attach` creates an empty shell).
    func testExitedAttachWithMissingSessionRecreates() {
        XCTAssertEqual(
            ZmxSessionRecovery.plan(processExited: true, sessionExists: false),
            .recreate
        )
    }

    /// Legacy bool helper: still true only when the attach process exited.
    func testShouldRecoverMatchesProcessExited() {
        XCTAssertFalse(ZmxSessionRecovery.shouldRecover(processExited: false))
        XCTAssertTrue(ZmxSessionRecovery.shouldRecover(processExited: true))
    }
}
