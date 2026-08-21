import Foundation

/// Pairing identity + legacy MQTT broker fields (`~/.config/seahelm/config.json`,
/// `mqtt` key). Host Gateway reads `root_secret` / `mac_id` from here; broker
/// connection fields are kept for config compatibility only (no publisher).
struct MqttConfig: Codable, Equatable {
    /// Legacy broker host. Unused by Host Gateway.
    var host: String
    /// Legacy broker port.
    var port: UInt16?
    /// Legacy TLS flag.
    var tls: Bool?
    /// Legacy WebSocket flag.
    var websocket: Bool?
    /// Legacy WebSocket path.
    var wsPath: String?
    /// Legacy broker username/password (unused when `rootSecret` is set).
    var username: String?
    var password: String?
    /// Pairing root secret (base64url, 32 bytes). Set once via the pairing window;
    /// drives Host Gateway auth (HKDF info="auth"). See `MqttCrypto`.
    var rootSecret: String?
    /// Optional CA path (legacy).
    var caCertPath: String?
    /// Stable Mac instance id used in pair links and Host Gateway auth.
    /// Nil = derived via `deriveMacId()`.
    var macId: String?
    /// Legacy public client broker URL for pair links when Host Gateway is off.
    var clientBroker: String?
    /// Legacy MQTT client id.
    var clientId: String?
    /// Legacy MQTT enable flag. Ignored — there is no MQTT publisher.
    var enabled: Bool?
    /// Legacy remote-write gate.
    var allowRemoteWrite: Bool?
    /// Legacy message-publish gate.
    var publishMessages: Bool?
    /// Legacy reconnect backoff cap.
    var maxReconnectInterval: TimeInterval?

    // MARK: Resolved defaults
    var resolvedTLS: Bool { tls ?? true }
    var resolvedWebsocket: Bool { websocket ?? false }
    var resolvedWsPath: String { wsPath ?? "/mqtt" }
    var resolvedEnabled: Bool { enabled ?? false }
    var resolvedAllowRemoteWrite: Bool { allowRemoteWrite ?? false }
    var resolvedMaxReconnectInterval: TimeInterval { maxReconnectInterval ?? 30.0 }
    /// Port by transport when unset: ws+tls 8084, ws 8083, tcp+tls 8883, tcp 1883.
    var resolvedPort: UInt16 {
        if let port { return port }
        switch (resolvedWebsocket, resolvedTLS) {
        case (true, true):   return 8084
        case (true, false):  return 8083
        case (false, true):  return 8883
        case (false, false): return 1883
        }
    }

    /// Fallback pair `b=` when Host Gateway is disabled: prefers `clientBroker`.
    var resolvedClientBrokerURL: String {
        if let clientBroker, !clientBroker.isEmpty { return clientBroker }
        let scheme = resolvedTLS ? "wss" : "ws"
        let port = resolvedPort
        let omitPort = (resolvedTLS && port == 443) || (!resolvedTLS && port == 80)
        let authority = omitPort ? host : "\(host):\(port)"
        return "\(scheme)://\(authority)\(resolvedWsPath)"
    }

    /// Stable, non-PII Mac id from the local hostname (djb2-ish).
    static func deriveMacId() -> String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        var h: UInt64 = 5381
        for b in name.utf8 { h = (h &* 33) ^ UInt64(b) }
        return "m" + String(h & 0xFFFFFFFF, radix: 16)
    }

    enum CodingKeys: String, CodingKey {
        case host
        case port
        case tls
        case websocket
        case wsPath = "ws_path"
        case username
        case password
        case rootSecret = "root_secret"
        case caCertPath = "ca_cert_path"
        case macId = "mac_id"
        case clientBroker = "client_broker"
        case clientId = "client_id"
        case enabled
        case allowRemoteWrite = "allow_remote_write"
        case publishMessages = "publish_messages"
        case maxReconnectInterval = "max_reconnect_interval"
    }
}
