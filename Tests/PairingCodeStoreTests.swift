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

    /// A code you choose: grouped however you like to read it, 8 to 16 digits.
    func testSetAcceptsAChosenCodeOfEightToSixteenDigits() {
        var store = PairingCodeStore(code: "11111111")
        XCTAssertEqual(store.set("2026 0917 1430"), "202609171430")
        XCTAssertTrue(store.verify("202609171430"))
        XCTAssertTrue(store.verify("2026-0917-1430"))
        XCTAssertFalse(store.verify("11111111"), "the old code stops working")
        XCTAssertFalse(store.verify("20260917"), "a prefix is not the code")
        XCTAssertEqual(store.set("12345678"), "12345678")
        XCTAssertEqual(store.set("1234567812345678"), "1234567812345678")
    }

    /// Refused outright rather than quietly trimmed into a code the user did not type.
    func testSetRefusesWhatIsNotACodeAndKeepsTheCurrentOne() {
        var store = PairingCodeStore(code: "48291736")
        for bad in ["1234567", "12345678123456789", "1234abcd", "１２３４５６７８", "", "1234_5678"] {
            XCTAssertNil(store.set(bad), bad)
        }
        XCTAssertEqual(store.code, "48291736")
        XCTAssertTrue(store.verify("48291736"))
    }

    func testAChosenCodeSurvivesEnsure() {
        var store = PairingCodeStore(code: "202609171430")
        XCTAssertEqual(store.ensureCode(), "202609171430", "a longer code is valid, not replaced")
    }

    func testCodesAreShownInFours() {
        XCTAssertEqual(PairingCodeStore.grouped("48291736"), "4829 1736")
        XCTAssertEqual(PairingCodeStore.grouped("2026091714"), "2026 0917 14")
    }

    func testLiveCodeReportsASetButNotARefusal() {
        let live = LivePairingCode(store: PairingCodeStore(code: "48291736"))
        var changes: [String?] = []
        live.onChange = { changes.append($0.code) }
        XCTAssertNil(live.set("12"))
        XCTAssertEqual(live.set("9999 8888 7777"), "999988887777")
        XCTAssertEqual(changes, ["999988887777"])
        XCTAssertTrue(live.verify("999988887777"))
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
