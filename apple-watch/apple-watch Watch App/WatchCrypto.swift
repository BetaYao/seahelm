import Foundation
import CryptoKit

/// E2EE for the watch — the same contract as the Mac's `MqttCrypto.swift` and
/// `e2ee.js`. Derives broker creds + an AES-256-GCM key from a paired root
/// secret; seals/opens per-topic (topic = AAD). See docs/remote-clients-design §7.5.
struct WatchCrypto {
    let encKey: SymmetricKey
    let authPassword: String            // broker password (hex of info="auth" key)

    private static let salt = Data("seahelm-pair-v1".utf8)
    private static let version: UInt8 = 0x01

    init(rootSecret: Data) {
        let ikm = SymmetricKey(data: rootSecret)
        let auth = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Self.salt,
                                          info: Data("auth".utf8), outputByteCount: 32)
        self.encKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Self.salt,
                                             info: Data("e2ee".utf8), outputByteCount: 32)
        self.authPassword = auth.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    }

    /// nil root secret → plaintext mode.
    init?(rootSecretBase64url s: String?) {
        guard let s, let bytes = Self.rootSecret(fromBase64url: s) else { return nil }
        self.init(rootSecret: bytes)
    }

    func seal(_ plaintext: String, topic: String) -> String {
        if plaintext.isEmpty { return "" }
        guard let box = try? AES.GCM.seal(Data(plaintext.utf8), using: encKey,
                                          authenticating: Data(topic.utf8)),
              let combined = box.combined else { return "" }
        var env = Data([Self.version]); env.append(combined)
        return env.base64EncodedString()
    }

    func open(_ payloadB64: String, topic: String) -> String? {
        if payloadB64.isEmpty { return "" }
        guard let env = Data(base64Encoded: payloadB64), env.count > 13,
              env[env.startIndex] == Self.version,
              let box = try? AES.GCM.SealedBox(combined: env.dropFirst()),
              let pt = try? AES.GCM.open(box, using: encKey, authenticating: Data(topic.utf8))
        else { return nil }
        return String(data: pt, encoding: .utf8)
    }

    // MARK: - Short-code handshake (§7.5.4 weak channel)

    /// Ephemeral transport key derived from an 8-digit pairing code + a per-claim
    /// nonce. Weak by design (8 digits ~27 bit) — safe only with the code's
    /// single-use + short TTL + broker rate-limiting.
    static func codeKey(_ code: String, nonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                               salt: Data("seahelm-paircode-v1".utf8),
                               info: nonce, outputByteCount: 32)
    }
    /// Seal/open with an explicit key (same envelope: 0x01|nonce|ct+tag, AAD=topic).
    static func seal(_ plaintext: String, topic: String, key: SymmetricKey) -> String {
        guard !plaintext.isEmpty,
              let box = try? AES.GCM.seal(Data(plaintext.utf8), using: key, authenticating: Data(topic.utf8)),
              let combined = box.combined else { return "" }
        var env = Data([version]); env.append(combined); return env.base64EncodedString()
    }
    static func open(_ b64: String, topic: String, key: SymmetricKey) -> String? {
        guard let env = Data(base64Encoded: b64), env.count > 13, env[env.startIndex] == version,
              let box = try? AES.GCM.SealedBox(combined: env.dropFirst()),
              let pt = try? AES.GCM.open(box, using: key, authenticating: Data(topic.utf8)) else { return nil }
        return String(data: pt, encoding: .utf8)
    }

    static func rootSecret(fromBase64url s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomNonce(_ n: Int = 16) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }

    /// Parse `seahelm://pair?b=..&m=..&k=..` → (broker, mac, rootSecretB64url).
    static func parsePairURI(_ s: String) -> (broker: String, mac: String, key: String)? {
        guard let r = s.range(of: "seahelm://pair?") else { return nil }
        let q = String(s[r.upperBound...])
        var b = "", m = "", k = ""
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let val = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            switch kv[0] { case "b": b = val; case "m": m = val; case "k": k = val; default: break }
        }
        return k.isEmpty ? nil : (b, m, k)
    }
}
