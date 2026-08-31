import Foundation

/// What a Mac needs to be paired with: one root secret, and a stable id.
///
/// This was `PairingIdentity`, and carried a broker host, port, TLS flags, path,
/// credentials, a CA path and reconnect settings — the connection details for a
/// broker the Mac never connected to. It minted them for the web client, which
/// now reaches the Host Gateway same-origin. Every one of those fields is gone;
/// these two are what the gateway's own pairing runs on.
///
/// **The JSON key stays `mqtt`.** It is where every existing install already
/// keeps its `root_secret`, and `Config` decodes with `decodeIfPresent` — renaming
/// it would read as "absent", mint a fresh secret, and silently unpair every
/// device that was working yesterday. A wrong name is cheaper than that.
/// Unknown keys from older configs are simply not decoded.
struct PairingIdentity: Codable, Equatable {
    /// Pairing root secret (base64url, 32 bytes), minted once. Drives Host
    /// Gateway auth via `PairingCrypto` (HKDF info="auth"). Never leaves the Mac.
    var rootSecret: String?
    /// Stable Mac instance id. Nil = derived via `deriveMacId()`.
    var macId: String?

    init(rootSecret: String? = nil, macId: String? = nil) {
        self.rootSecret = rootSecret
        self.macId = macId
    }

    /// Stable, non-PII Mac id from the local hostname (djb2-ish).
    static func deriveMacId() -> String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        var h: UInt64 = 5381
        for b in name.utf8 { h = (h &* 33) ^ UInt64(b) }
        return "m" + String(h & 0xFFFFFFFF, radix: 16)
    }

    enum CodingKeys: String, CodingKey {
        case rootSecret = "root_secret"
        case macId = "mac_id"
    }
}
