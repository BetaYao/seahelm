import Foundation

/// MQTT remote-client backend config (`~/.config/seahelm/config.json`, `mqtt` key).
/// Mirrors `WeComBotConfig`'s optional-with-resolved-default style so older
/// configs decode unchanged. Drives `MqttChannel` (CocoaMQTT).
///
/// v1 target is EMQX Cloud over TLS (see `docs/remote-clients-design.md` §11).
/// The Mac publisher connects outbound; clients connect to the same broker.
struct MqttConfig: Codable, Equatable {
    /// Broker host, e.g. `a81fb6d3.ala.cn-hangzhou.emqxsl.cn` or `127.0.0.1`.
    var host: String
    /// Broker port. Defaults by transport (see `resolvedPort`).
    var port: UInt16?
    /// TLS/SSL. Default true (EMQX Cloud requires it).
    var tls: Bool?
    /// Connect over WebSocket instead of raw TCP. Mac publisher uses TCP (false);
    /// browser/Watch clients use WS. Default false.
    var websocket: Bool?
    /// WebSocket path when `websocket` is true. Default `/mqtt`.
    var wsPath: String?
    /// Auth (EMQX built-in DB / external). Anonymous is refused on EMQX Cloud.
    /// When `rootSecret` is set (paired), `MqttChannel` overrides `username` with
    /// `macId` and `password` with the HKDF-derived hex — these become the manual
    /// fallback for an un-paired/plaintext broker.
    var username: String?
    var password: String?
    /// Pairing root secret (base64url, 32 bytes). Set once via the pairing window;
    /// drives both broker auth (HKDF info="auth") and payload E2EE (info="e2ee").
    /// Nil = un-paired (plaintext, manual username/password). See `MqttCrypto`.
    var rootSecret: String?
    /// Optional CA path for pinning. Nil = rely on system trust (EMQX Cloud uses
    /// DigiCert Global Root G2, already trusted by macOS).
    var caCertPath: String?
    /// Topic namespace `seahelm/{mac_id}/…` and multi-tenant ACL boundary.
    /// Nil = `MqttChannel` derives a stable, non-PII id.
    var macId: String?
    /// Optional public WS(S) URL for remote clients (Watch / Web) embedded in
    /// `seahelm://pair?b=…`. When set, pair links use this instead of deriving
    /// from `host`/`port` — so the Mac can publish over LAN TCP (`127.0.0.1:1883`)
    /// while clients dial the edge (`wss://gw.seahelm.dev/mqtt`).
    var clientBroker: String?
    /// MQTT client id. Nil = derived from `macId`.
    var clientId: String?
    /// Master enable. Default false (feature off until configured).
    var enabled: Bool?
    /// Gate for inbound Control-tier commands (`pane.send_text` etc.). When false,
    /// `MqttChannel` refuses writes with `capability_denied` regardless of broker
    /// ACL. Default false — remote write is opt-in.
    var allowRemoteWrite: Bool?
    /// Publish `message`/`last_message` bodies. When false, terminal content is
    /// withheld from the (public) broker; only status/counts flow. Default true.
    var publishMessages: Bool?
    /// Reconnect backoff cap (seconds). Default 30.
    var maxReconnectInterval: TimeInterval?

    // MARK: Resolved defaults
    var resolvedTLS: Bool { tls ?? true }
    var resolvedWebsocket: Bool { websocket ?? false }
    var resolvedWsPath: String { wsPath ?? "/mqtt" }
    var resolvedEnabled: Bool { enabled ?? false }
    var resolvedAllowRemoteWrite: Bool { allowRemoteWrite ?? false }
    var resolvedPublishMessages: Bool { publishMessages ?? true }
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

    /// WS(S) URL for pair QR / long link. Prefers `clientBroker`; else builds from
    /// host + resolved port (omitting :443 / :80).
    var resolvedClientBrokerURL: String {
        if let clientBroker, !clientBroker.isEmpty { return clientBroker }
        let scheme = resolvedTLS ? "wss" : "ws"
        let port = resolvedPort
        let omitPort = (resolvedTLS && port == 443) || (!resolvedTLS && port == 80)
        let authority = omitPort ? host : "\(host):\(port)"
        return "\(scheme)://\(authority)\(resolvedWsPath)"
    }

    /// Retarget leftover EMQX Cloud hosts to local EMQX + public edge WSS for
    /// pair links. Idempotent; preserves root_secret / mac_id / allow_remote_write.
    static func normalizeForEdgeStack(_ mqtt: inout MqttConfig?) {
        guard var m = mqtt else { return }
        let host = m.host.lowercased()
        let isCloud = host.contains("emqxsl") || host.contains("emqx.io")
        let isLoopback = host == "127.0.0.1" || host == "localhost"
        if isCloud {
            m.host = "127.0.0.1"
            m.port = 1883
            m.tls = false
            m.websocket = false
            m.wsPath = "/mqtt"
            m.enabled = true
        }
        if (m.clientBroker ?? "").isEmpty, isCloud || isLoopback {
            m.clientBroker = "wss://gw.seahelm.dev/mqtt"
        }
        mqtt = m
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
