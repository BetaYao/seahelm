import Foundation

enum HostGatewayAuth {
    static func expectedToken(rootSecretBase64url: String) -> String? {
        guard let bytes = PairingCrypto.rootSecret(fromBase64url: rootSecretBase64url) else { return nil }
        return PairingCrypto(rootSecret: bytes).authPassword
    }

    static func verify(macId: String, token: String,
                       expectedMacId: String, rootSecretBase64url: String) -> Bool {
        guard macId == expectedMacId,
              let expected = expectedToken(rootSecretBase64url: rootSecretBase64url),
              !token.isEmpty else { return false }
        return constantTimeEqual(token, expected)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        guard a.utf8.count == b.utf8.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a.utf8, b.utf8) { diff |= x ^ y }
        return diff == 0
    }
}
