import Foundation

/// MQTT remote-client backend config (`~/.config/seahelm/config.json`, `mqtt` key).
/// Mirrors `WeComBotConfig`'s optional-with-resolved-default style so older
/// configs decode unchanged. Drives `MqttChannel` (CocoaMQTT).
///
/// v1 target is EMQX Cloud over TLS (see `docs/remote-clients-design.md` §11).
/// The Mac publisher connects outbound; clients connect to the same broker.
struct MqttConfig: Codable, Equatable {
    /// Broker host, e.g. `a81fb6d3.ala.cn-hangzhou.emqxsl.cn`.
    let host: String
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
    var username: String?
    var password: String?
    /// Optional CA path for pinning. Nil = rely on system trust (EMQX Cloud uses
    /// DigiCert Global Root G2, already trusted by macOS).
    var caCertPath: String?
    /// Topic namespace `seahelm/{mac_id}/…` and multi-tenant ACL boundary.
    /// Nil = `MqttChannel` derives a stable, non-PII id.
    var macId: String?
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

    enum CodingKeys: String, CodingKey {
        case host
        case port
        case tls
        case websocket
        case wsPath = "ws_path"
        case username
        case password
        case caCertPath = "ca_cert_path"
        case macId = "mac_id"
        case clientId = "client_id"
        case enabled
        case allowRemoteWrite = "allow_remote_write"
        case publishMessages = "publish_messages"
        case maxReconnectInterval = "max_reconnect_interval"
    }
}
