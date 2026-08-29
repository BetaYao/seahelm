import XCTest
@testable import seahelm

final class HostGatewayKeyFrameTests: XCTestCase {
    func testRoundTrip() {
        let key = "seahelm-main-p1"
        let utf8 = Data("hello".utf8)
        let frame = try! XCTUnwrap(HostGatewayKeyFrame.encode(paneSessionKey: key, utf8: utf8))
        let decoded = try! XCTUnwrap(HostGatewayKeyFrame.decode(frame))
        XCTAssertEqual(decoded.paneSessionKey, key)
        XCTAssertEqual(decoded.utf8, utf8)
    }

    func testRejectsOversizedKey() {
        let key = String(repeating: "a", count: 300)
        XCTAssertNil(HostGatewayKeyFrame.encode(paneSessionKey: key, utf8: Data()))
    }

    func testRejectsWrongVersion() {
        var frame = try! XCTUnwrap(HostGatewayKeyFrame.encode(paneSessionKey: "k", utf8: Data("x".utf8)))
        frame[0] = 2
        XCTAssertNil(HostGatewayKeyFrame.decode(frame))
    }
}
