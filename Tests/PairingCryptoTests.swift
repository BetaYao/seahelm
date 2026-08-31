import XCTest
@testable import seahelm

/// Locks the derivation the Host Gateway authenticates on.
///
/// The vector below is not decoration. Every Mac stores one root secret and
/// hands clients the token derived from it; changing salt, info or algorithm
/// would silently invalidate every pairing already out there, and the symptom
/// would be "my phone stopped connecting" rather than a failing build.
///
/// It originally cross-checked `e2ee.js`, which is gone with the MQTT client.
/// The value is unchanged — that is the point.
final class PairingCryptoTests: XCTestCase {
    /// root_secret = 32 bytes 0x00…0x1f
    private let root = Data((0..<32).map { UInt8($0) })

    func testAuthPasswordKAT() {
        XCTAssertEqual(PairingCrypto(rootSecret: root).authPassword,
                       "1f30db8b0e2f696aa5575f7eef0a05eb08b443df09bbad725e21f915b6abc26b")
    }

    func testAuthPasswordIsDeterministic() {
        XCTAssertEqual(PairingCrypto(rootSecret: root).authPassword,
                       PairingCrypto(rootSecret: root).authPassword)
    }

    func testDifferentSecretsDeriveDifferentTokens() {
        let other = Data((0..<32).map { UInt8($0 &+ 1) })
        XCTAssertNotEqual(PairingCrypto(rootSecret: root).authPassword,
                          PairingCrypto(rootSecret: other).authPassword)
    }

    /// The secret round-trips through the form it is stored in — a padding or
    /// alphabet slip here would lose an existing pairing just as surely.
    func testBase64urlRoundTrip() {
        XCTAssertEqual(PairingCrypto.rootSecret(fromBase64url: PairingCrypto.base64url(root)), root)
    }

    func testBase64urlIsURLSafeAndUnpadded() {
        // 0xfb 0xff picks the two alphabet positions that differ from standard base64.
        let s = PairingCrypto.base64url(Data([0xfb, 0xff, 0xfe]))
        XCTAssertFalse(s.contains("+") || s.contains("/") || s.contains("="), s)
        XCTAssertEqual(PairingCrypto.rootSecret(fromBase64url: s), Data([0xfb, 0xff, 0xfe]))
    }

    func testNewRootSecretIsThirtyTwoFreshBytes() {
        let a = PairingCrypto.newRootSecret(), b = PairingCrypto.newRootSecret()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
    }
}
