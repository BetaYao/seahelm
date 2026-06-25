import XCTest
@testable import seahelm

final class ScanDecoderTests: XCTestCase {
    func testProcessExitedMapsToExited() {
        let decoder = ScanDecoder(
            detector: StatusDetector(),
            processStatus: .exited,
            shellInfo: nil,
            content: "",
            agentDef: nil
        )
        XCTAssertEqual(decoder.decode()?.status, .exited)
    }

    func testEmptyContentRunningIsUnknown() {
        let decoder = ScanDecoder(
            detector: StatusDetector(),
            processStatus: .running,
            shellInfo: nil,
            content: "",
            agentDef: nil
        )
        XCTAssertEqual(decoder.decode()?.status, .unknown)
    }
}
