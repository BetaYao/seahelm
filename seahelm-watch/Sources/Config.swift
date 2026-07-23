import Foundation

/// Broker + identity config. DEV default targets the Mac's local devbroker/nanoMQ
/// over plain WebSocket on the LAN. On the watch *simulator* the Mac is reachable
/// as `localhost`; on a real watch set `host` to the Mac's LAN IP (or, later, the
/// emqx cloud host with `tls = true` and `port = 8084`).
///
/// Mirrors the Mac publisher's `MqttConfig` so the two sides agree on `macId`
/// (topic namespace `seahelm/{macId}/…`) — see `docs/remote-clients-design.md` §15.
struct WatchConfig: Codable, Equatable {
    var host: String = "localhost"      // real device: Mac LAN IP, e.g. "192.168.1.20"
    var port: UInt16 = 8083             // devbroker WS; emqx cloud wss = 8084
    var wsPath: String = "/mqtt"
    var tls: Bool = false               // true for wss:// (emqx cloud)
    var macId: String = "live"          // must match the Mac's mqtt.mac_id
    var username: String? = nil
    var password: String? = nil
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
