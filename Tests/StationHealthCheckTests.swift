import XCTest
@testable import seahelm

final class StationHealthCheckTests: XCTestCase {
    /// Regression: a freshly-attached zmx shell often shows a blank/short viewport
    /// for the first few seconds. The old health check tore such panes down because
    /// the viewport read empty, leaving plain-terminal panes dead (no input, must
    /// Cmd+W). A live attach process on a healthy session must NOT be recovered.
    func testLiveShellOnReachableSessionIsNotRecovered() {
        XCTAssertEqual(
            ZmxSessionRecovery.plan(processExited: false, reachability: .reachable),
            .none
        )
    }

    /// A live client whose session isn't listed is left alone too. `zmx list` can
    /// come back empty for reasons that have nothing to do with this pane, and the
    /// pane is by all appearances working — tearing it down would kill a healthy
    /// agent over an unreadable probe.
    func testLiveShellWithMissingSessionIsNotRecovered() {
        XCTAssertEqual(
            ZmxSessionRecovery.plan(processExited: false, reachability: .missing),
            .none
        )
    }

    /// Attach client died but the zmx daemon (and any agent inside) is still
    /// alive — only re-attach. Force-killing would wipe the user's session.
    func testExitedAttachWithLiveSessionReattachesOnly() {
        XCTAssertEqual(
            ZmxSessionRecovery.plan(processExited: true, reachability: .reachable),
            .reattach
        )
    }

    /// Attach exited and the session is gone — recreate (seed agent if we have
    /// a resume ref; otherwise `zmx attach` creates an empty shell).
    func testExitedAttachWithMissingSessionRecreates() {
        XCTAssertEqual(
            ZmxSessionRecovery.plan(processExited: true, reachability: .missing),
            .recreate
        )
    }

    /// Regression (external volume dropped, 2026-08-31): every zmx daemon living
    /// on the ejected volume spun forever, keeping its socket file and its
    /// `zmx list` row but answering nothing. The attach clients hung rather than
    /// exiting, so `processExited` stayed false, and the old presence-only check
    /// called the corpse alive — between them the pane was never even looked at,
    /// and restarts kept re-attaching to dead daemons until all 14 were killed by
    /// hand. An unreachable session must be recreated either way.
    func testWedgedDaemonRecreatesEvenWhileAttachClientHangs() {
        XCTAssertEqual(
            ZmxSessionRecovery.plan(processExited: false, reachability: .unreachable),
            .recreate
        )
        XCTAssertEqual(
            ZmxSessionRecovery.plan(processExited: true, reachability: .unreachable),
            .recreate
        )
    }
}
