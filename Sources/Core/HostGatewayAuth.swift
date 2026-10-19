import Foundation
import CryptoKit

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

    /// What a `?pane=` share link carries: HMAC of the pane's session key under
    /// the root secret. It opens that one pane and nothing else — not the fleet,
    /// and not the pairing token — and dies with the pairing, like the token.
    static func shareToken(paneSessionKey: String, rootSecretBase64url: String) -> String? {
        guard !paneSessionKey.isEmpty,
              let bytes = PairingCrypto.rootSecret(fromBase64url: rootSecretBase64url),
              !bytes.isEmpty else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("seahelm-share-v1:\(paneSessionKey)".utf8), using: SymmetricKey(data: bytes))
        return PairingCrypto.base64url(Data(mac))
    }

    static func verifyShare(paneSessionKey: String, token: String, rootSecretBase64url: String) -> Bool {
        guard !token.isEmpty,
              let expected = shareToken(paneSessionKey: paneSessionKey,
                                        rootSecretBase64url: rootSecretBase64url) else { return false }
        return constantTimeEqual(token, expected)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        guard a.utf8.count == b.utf8.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a.utf8, b.utf8) { diff |= x ^ y }
        return diff == 0
    }
}
