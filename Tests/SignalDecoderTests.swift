import XCTest
@testable import seahelm

final class SignalDecoderTests: XCTestCase {
    func testStubDecoderProducesEvent() {
        struct StubDecoder: SignalDecoder {
            func decode() -> NormalizedEvent? {
                NormalizedEvent(terminalID: "t1", source: .scan,
                                kind: .agentStopped(success: true))
            }
        }
        let event = StubDecoder().decode()
        XCTAssertNotNil(event)
        guard case .agentStopped(let success) = event?.kind else {
            return XCTFail("wrong kind")
        }
        XCTAssertTrue(success)
    }
}
