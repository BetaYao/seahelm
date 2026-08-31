import Foundation
import CryptoKit

/// Pairing crypto for the Host Gateway: one root secret per Mac, and the token
/// derived from it that a paired client presents.
///
/// This was `PairingCrypto`, and carried an AES-GCM envelope so an untrusted broker
/// could relay ciphertext it could not read. The web client no longer speaks
/// MQTT — it reaches the gateway same-origin over TLS — so the envelope, the
/// `e2ee` key it used, and the `seahelm://pair?…` URI that carried the root
/// secret to a client all went with it. What remains is the derivation the
/// gateway's own authentication runs on.
///
/// Contract (v1), unchanged:
///   HKDF-SHA256(ikm=root_secret, salt="seahelm-pair-v1", info="auth") → 32B
///   token = lowercase hex of those bytes
///
/// The root secret never leaves the Mac. A client gets the derived token, which
/// opens this gateway and nothing else and dies when the pairing rotates.
struct PairingCrypto {
    /// The token a paired client presents (lowercase hex, info="auth").
    let authPassword: String

    private static let salt = Data("seahelm-pair-v1".utf8)

    init(rootSecret: Data) {
        let auth = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: rootSecret),
                                          salt: Self.salt,
                                          info: Data("auth".utf8), outputByteCount: 32)
        self.authPassword = auth.withUnsafeBytes { raw in
            raw.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// A fresh 32-byte root secret (once per Mac; persisted in config).
    static func newRootSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// URL-safe base64 without padding — the form the secret is stored in.
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func rootSecret(fromBase64url s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
