import XCTest
@testable import seahelm

final class PairingCodeStoreTests: XCTestCase {
    func testGenerateIsEightDigits() {
        for _ in 0..<20 {
            let code = PairingCodeStore.generate()
            XCTAssertEqual(code.count, 8)
            XCTAssertTrue(code.allSatisfy(\.isNumber))
        }
    }

    func testNormalizeStripsSpaces() {
        XCTAssertEqual(PairingCodeStore.normalize("4829 1736"), "48291736")
    }

    func testVerifyAcceptsGroupedInput() {
        var store = PairingCodeStore(code: "48291736")
        XCTAssertTrue(store.verify("4829 1736"))
        XCTAssertFalse(store.verify("00000000"))
    }

    func testRefreshInvalidatesOld() {
        var store = PairingCodeStore(code: "11111111")
        let next = store.refresh()
        XCTAssertNotEqual(next, "11111111")
        XCTAssertFalse(store.verify("11111111"))
        XCTAssertTrue(store.verify(next))
    }

    func testEnsureCodeFillsMissing() {
        var store = PairingCodeStore(code: nil)
        let code = store.ensureCode()
        XCTAssertEqual(code.count, 8)
        XCTAssertEqual(store.code, code)
    }

    func testConfigRoundTripsPairCode() throws {
        var hg = HostGatewayConfig(enabled: true, port: 2783, pairCode: "12345678")
        let data = try JSONEncoder().encode(hg)
        let decoded = try JSONDecoder().decode(HostGatewayConfig.self, from: data)
        XCTAssertEqual(decoded.pairCode, "12345678")
        // edited must keep pair code when UI does not touch it
        let kept = HostGatewayConfig.edited(
            enabled: true, portText: "2783", publicURLText: "", from: hg)
        XCTAssertEqual(kept.pairCode, "12345678")
    }
}
