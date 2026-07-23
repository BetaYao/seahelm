import Foundation
import CryptoKit

/// E2EE + pairing crypto for the MQTT remote-client channel. The wire contract is
/// shared verbatim with the web/ESP32/Watch clients — see
/// `clients/seahelm-web/e2ee.js` (the executable reference) and
/// `docs/remote-clients-design.md` §7.5.
///
/// Contract (v1):
///   pair URI : seahelm://pair?b=<broker_url>&m=<mac_id>&k=<base64url 32B root_secret>
///   HKDF-SHA256(ikm=root_secret, salt="seahelm-pair-v1"):
///     info="auth" → 32B → broker password = lowercase hex   (username = mac_id)
///     info="e2ee" → 32B → AES-256-GCM key
///   envelope : 0x01 | nonce(12) | ciphertext||tag(16)   base64 → MQTT payload
///              AAD = utf8(topic)   (binds ciphertext to its topic)
///   empty payload ("") is never encrypted — it is the retained-delete idiom.
struct MqttCrypto {
    /// AES-256-GCM key derived from the pairing root secret (info="e2ee").
    let encKey: SymmetricKey
    /// Broker password (lowercase hex of the auth key, info="auth").
    let authPassword: String

    private static let salt = Data("seahelm-pair-v1".utf8)
    private static let version: UInt8 = 0x01

    /// Derive both keys from the 32-byte root secret.
    init(rootSecret: Data) {
        let ikm = SymmetricKey(data: rootSecret)
        let auth = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Self.salt,
                                          info: Data("auth".utf8), outputByteCount: 32)
        self.encKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Self.salt,
                                             info: Data("e2ee".utf8), outputByteCount: 32)
        self.authPassword = auth.withUnsafeBytes { raw in
            raw.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Seal a plaintext string for `topic` → base64 envelope. Empty passes through
    /// (retained-delete idiom, never encrypted).
    func seal(_ plaintext: String, topic: String) -> String {
        if plaintext.isEmpty { return "" }
        guard let box = try? AES.GCM.seal(Data(plaintext.utf8), using: encKey,
                                          authenticating: Data(topic.utf8)),
              let combined = box.combined else { return "" }
        // box.combined = nonce(12) || ciphertext || tag(16); prepend the version byte.
        var env = Data([Self.version]); env.append(combined)
        return env.base64EncodedString()
    }

    /// Open a base64 envelope received on `topic`. Empty passes through.
    func open(_ payloadB64: String, topic: String) -> String? {
        if payloadB64.isEmpty { return "" }
        guard let env = Data(base64Encoded: payloadB64), env.count > 13,
              env[env.startIndex] == Self.version,
              let box = try? AES.GCM.SealedBox(combined: env.dropFirst()),
              let pt = try? AES.GCM.open(box, using: encKey,
                                         authenticating: Data(topic.utf8)) else { return nil }
        return String(data: pt, encoding: .utf8)
    }

    // MARK: - Pairing

    /// A fresh 32-byte root secret (call once per Mac; persist in config).
    static func newRootSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// Build the `seahelm://pair?...` URI the desktop renders as QR / long link.
    static func pairURI(broker: String, macId: String, rootSecret: Data) -> String {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "+/=&?")
        let b = broker.addingPercentEncoding(withAllowedCharacters: cs) ?? broker
        return "seahelm://pair?b=\(b)&m=\(macId)&k=\(base64url(rootSecret))"
    }

    /// URL-safe base64 without padding (matches the JS `unb64url` inverse).
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Short-code handshake (§7.5.4 weak channel)

    /// Ephemeral transport key from an 8-digit pairing code + per-claim nonce.
    /// Weak by design — safe only with single-use + short TTL + rate-limiting.
    static func codeKey(_ code: String, nonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                               salt: Data("seahelm-paircode-v1".utf8),
                               info: nonce, outputByteCount: 32)
    }
    static func seal(_ plaintext: String, topic: String, key: SymmetricKey) -> String {
        guard !plaintext.isEmpty,
              let box = try? AES.GCM.seal(Data(plaintext.utf8), using: key, authenticating: Data(topic.utf8)),
              let combined = box.combined else { return "" }
        var env = Data([Self.version]); env.append(combined); return env.base64EncodedString()
    }
    static func open(_ b64: String, topic: String, key: SymmetricKey) -> String? {
        guard let env = Data(base64Encoded: b64), env.count > 13, env[env.startIndex] == Self.version,
              let box = try? AES.GCM.SealedBox(combined: env.dropFirst()),
              let pt = try? AES.GCM.open(box, using: key, authenticating: Data(topic.utf8)) else { return nil }
        return String(data: pt, encoding: .utf8)
    }

    static func rootSecret(fromBase64url s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
