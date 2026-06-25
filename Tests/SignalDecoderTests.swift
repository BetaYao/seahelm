import XCTest
@testable import seahelm

final class SignalDecoderTests: XCTestCase {
    func testStubDecoderProducesReport() {
        struct StubDecoder: SignalDecoder {
            func decode() -> StatusReport? {
                StatusReport(status: .waiting, lastMessage: "hi", activityEvents: [])
            }
        }
        let report = StubDecoder().decode()
        XCTAssertEqual(report?.status, .waiting)
        XCTAssertEqual(report?.lastMessage, "hi")
        XCTAssertEqual(report?.activityEvents.count, 0)
    }
}
