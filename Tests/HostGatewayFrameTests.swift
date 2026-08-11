import XCTest
@testable import seahelm

final class HostGatewayFrameTests: XCTestCase {
    func testParseRequest() {
        let inbound = HostGatewayFrame.parse(#"{"id":"1","method":"auth","params":{"mac_id":"live"}}"#)
        guard case let .request(id, method, params) = inbound else { return XCTFail() }
        XCTAssertEqual(id, "1")
        XCTAssertEqual(method, "auth")
        XCTAssertEqual(params["mac_id"] as? String, "live")
    }

    func testEncodeNotify() throws {
        let s = HostGatewayFrame.encode(.notify(method: "vt.data",
            params: ["pane_session_key": "p1", "b64": "YQ=="]))
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "notify")
        XCTAssertEqual(obj["method"] as? String, "vt.data")
    }

    func testEncodeErrorResponse() throws {
        let s = HostGatewayFrame.encode(.response(id: "9", result: nil,
            error: ["code": -32001, "message": "unauthorized"]))
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        XCTAssertEqual(obj["id"] as? String, "9")
        XCTAssertNotNil(obj["error"])
    }
}
