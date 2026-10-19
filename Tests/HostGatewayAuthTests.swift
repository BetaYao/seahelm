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

    func testShareTokenOpensOnlyThePaneItWasMintedFor() throws {
        let b64 = PairingCrypto.base64url(root)
        let token = try XCTUnwrap(HostGatewayAuth.shareToken(paneSessionKey: "k1", rootSecretBase64url: b64))
        XCTAssertTrue(HostGatewayAuth.verifyShare(paneSessionKey: "k1", token: token, rootSecretBase64url: b64))
        XCTAssertFalse(HostGatewayAuth.verifyShare(paneSessionKey: "k2", token: token, rootSecretBase64url: b64))
        XCTAssertFalse(HostGatewayAuth.verifyShare(paneSessionKey: "k1", token: "", rootSecretBase64url: b64))
    }

    /// A share link must not double as the pairing token, or forwarding it
    /// would hand over the fleet.
    func testShareTokenIsNotThePairingToken() {
        let b64 = PairingCrypto.base64url(root)
        let share = HostGatewayAuth.shareToken(paneSessionKey: "k1", rootSecretBase64url: b64)
        XCTAssertNotEqual(share, HostGatewayAuth.expectedToken(rootSecretBase64url: b64))
        XCTAssertFalse(HostGatewayAuth.verify(
            macId: "live", token: share ?? "", expectedMacId: "live", rootSecretBase64url: b64))
    }

    func testNoRootSecretMintsNoShareToken() {
        XCTAssertNil(HostGatewayAuth.shareToken(paneSessionKey: "k1", rootSecretBase64url: ""))
    }
}
