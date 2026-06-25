import XCTest
@testable import seahelm

final class ScanDecoderTests: XCTestCase {
    func testProcessExitedMapsToExited() {
        let decoder = ScanDecoder(
            terminalID: "t1",
            detector: StatusDetector(),
            processStatus: .exited,
            shellInfo: nil,
            content: "",
            agentDef: nil,
            commandLine: nil,
            agentType: .unknown,
            roundDuration: 0,
            tasks: []
        )
        guard case .screenObserved(let status, _, _, _, _, _, _) = decoder.decode()?.kind else {
            return XCTFail("expected screenObserved")
        }
        XCTAssertEqual(status, .exited)
    }

    func testEmptyContentRunningIsUnknown() {
        let decoder = ScanDecoder(
            terminalID: "t1",
            detector: StatusDetector(),
            processStatus: .running,
            shellInfo: nil,
            content: "",
            agentDef: nil,
            commandLine: nil,
            agentType: .unknown,
            roundDuration: 0,
            tasks: []
        )
        guard case .screenObserved(let status, _, _, _, _, _, _) = decoder.decode()?.kind else {
            return XCTFail("expected screenObserved")
        }
        XCTAssertEqual(status, .unknown)
    }
}
