import Foundation

/// Broker + identity config. DEV default targets the Mac's local devbroker/nanoMQ
/// over plain WebSocket on the LAN. On the watch *simulator* the Mac is reachable
/// as `localhost`; on a real watch set `host` to the Mac's LAN IP (or, later, the
/// emqx cloud host with `tls = true` and `port = 8084`).
///
/// Mirrors the Mac publisher's `MqttConfig` so the two sides agree on `macId`
/// (topic namespace `seahelm/{macId}/…`) — see `docs/remote-clients-design.md` §15.
struct WatchConfig: Codable, Equatable {
    // EMQX Cloud (public, reachable from a real watch). Local dev: host "localhost",
    // port 8083, tls false.
    var host: String = "a81fb6d3.ala.cn-hangzhou.emqxsl.cn"
    var port: UInt16 = 8084             // WebSocket over TLS (emqx cloud); dev WS = 8083
    var wsPath: String = "/mqtt"
    var tls: Bool = true                // wss:// (emqx cloud); false for local dev
    var macId: String = "live"          // must match the Mac's mqtt.mac_id
    var username: String? = "seahelm"
    var password: String? = "seahelm"
    /// Pairing root secret (base64url, from a `seahelm://pair` link). When set, the
    /// client derives broker creds + the E2EE key and seals/opens all payloads —
    /// must match the Mac's `mqtt.root_secret`. nil = plaintext/manual (unpaired).
    var rootSecret: String? = nil

    var isPaired: Bool { (rootSecret ?? "").isEmpty == false }

    /// Build a config from a `seahelm://pair?b=..&m=..&k=..` link: broker URL →
    /// host/port/tls/wsPath, mac, and the E2EE root secret. Returns nil if the
    /// link isn't a valid pair URI.
    static func from(pairLink: String, base: WatchConfig = WatchConfig()) -> WatchConfig? {
        guard let p = WatchCrypto.parsePairURI(pairLink.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        var c = base
        if !p.mac.isEmpty { c.macId = p.mac }
        c.rootSecret = p.key
        if let u = URLComponents(string: p.broker) {
            if let h = u.host { c.host = h }
            if let port = u.port { c.port = UInt16(port) }
            c.tls = (u.scheme == "wss")
            if !u.path.isEmpty { c.wsPath = u.path }
        }
        return c
    }
    /// Capability tier this client operates at (mirrors the design's gating).
    /// The broker ACL is the real enforcement; this only shapes the UI.
    var capability: Capability = .control

    /// Topic namespace root, e.g. `seahelm/live`.
    var base: String { "seahelm/\(macId)" }

    /// Stable-ish client id; a random suffix avoids clientId takeover ping-pong
    /// if two watch instances connect. Persisted for the session.
    static let clientId: String = "seahelm-watch-" + String(UInt32.random(in: 0..<UInt32.max), radix: 16)

    static var current = WatchConfig()
}

enum Capability: String, Codable, CaseIterable {
    case read, interactive, control
    var canPick: Bool { self != .read }        // answer questions / pick suggestions
    var canType: Bool { self == .control }     // free-text / dictation
}
