import XCTest
@testable import seahelm

final class StationHealthCheckTests: XCTestCase {
    /// Regression: a freshly-attached zmx shell often shows a blank/short viewport
    /// for the first few seconds. The old health check tore such panes down because
    /// the viewport read empty, leaving plain-terminal panes dead (no input, must
    /// Cmd+W). A live attach process must NOT be recovered.
    func testLiveShellWithBlankViewportIsNotRecovered() {
        XCTAssertFalse(ZmxSessionRecovery.shouldRecover(processExited: false))
    }

    /// When `zmx attach` has actually exited, the session is gone and the pane is
    /// genuinely dead — recovery is warranted.
    func testExitedAttachIsRecovered() {
        XCTAssertTrue(ZmxSessionRecovery.shouldRecover(processExited: true))
    }
}
