import XCTest
@testable import seahelm

final class HostGatewayAuthTests: XCTestCase {
    private let root = Data((0..<32).map { UInt8($0) })

    func testTokenMatchesMqttAuthPassword() {
        let b64 = PairingCrypto.base64url(root)
        let token = HostGatewayAuth.expectedToken(rootSecretBase64url: b64)
        XCTAssertEqual(token, PairingCrypto(rootSecret: root).authPassword)
    }

    func testVerifyAcceptsMatchingMacAndToken() {
        let b64 = PairingCrypto.base64url(root)
        let token = PairingCrypto(rootSecret: root).authPassword
        XCTAssertTrue(HostGatewayAuth.verify(
            macId: "live", token: token, expectedMacId: "live", rootSecretBase64url: b64))
    }

    func testVerifyRejectsWrongToken() {
        let b64 = PairingCrypto.base64url(root)
        XCTAssertFalse(HostGatewayAuth.verify(
            macId: "live", token: "nope", expectedMacId: "live", rootSecretBase64url: b64))
    }

    func testVerifyRejectsWrongMac() {
        let b64 = PairingCrypto.base64url(root)
        let token = PairingCrypto(rootSecret: root).authPassword
        XCTAssertFalse(HostGatewayAuth.verify(
            macId: "other", token: token, expectedMacId: "live", rootSecretBase64url: b64))
    }
}
