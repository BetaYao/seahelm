import Foundation

enum HostGatewayAuth {
    static func expectedToken(rootSecretBase64url: String) -> String? {
        guard let bytes = MqttCrypto.rootSecret(fromBase64url: rootSecretBase64url) else { return nil }
        return MqttCrypto(rootSecret: bytes).authPassword
    }

    static func verify(macId: String, token: String,
                       expectedMacId: String, rootSecretBase64url: String) -> Bool {
        guard macId == expectedMacId,
              let expected = expectedToken(rootSecretBase64url: rootSecretBase64url),
              !token.isEmpty else { return false }
        // Constant-time-ish compare for equal-length hex strings
        guard token.utf8.count == expected.utf8.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(token.utf8, expected.utf8) { diff |= a ^ b }
        return diff == 0
    }
}
