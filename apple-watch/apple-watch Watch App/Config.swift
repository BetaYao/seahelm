import Foundation

/// Gateway + identity config. Watch talks HTTPS to `gatewayBaseURL` (watchOS
/// blocks MQTT WebSockets on device). Mac / web still use MQTT against EMQX;
/// the gateway bridges retained + events over `/api/v1/sync` + `/api/v1/publish`.
struct WatchConfig: Codable, Equatable {
    /// Edge stack origin, e.g. https://gw.seahelm.dev (no trailing slash).
    var gatewayBaseURL: String = "https://gw.seahelm.dev"
    /// Must match `WATCH_API_KEY` on the gateway. Prefer Info.plist
    /// `SEAHELM_GATEWAY_API_KEY`, else persisted value.
    var gatewayAPIKey: String = ""
    var macId: String = "live"          // must match the Mac's mqtt.mac_id
    /// Pairing root secret (base64url). When set, payloads are E2EE sealed.
    var rootSecret: String? = nil
    var capability: Capability = .control

    // Legacy MQTT fields kept for decode compat with older UserDefaults blobs.
    var host: String = ""
    var port: UInt16 = 443
    var wsPath: String = ""
    var tls: Bool = true
    var username: String? = nil
    var password: String? = nil

    var isPaired: Bool { (rootSecret ?? "").isEmpty == false }

    /// Topic namespace root, e.g. `seahelm/live`.
    var base: String { "seahelm/\(macId)" }

    static let clientId: String = "seahelm-watch-" + String(UInt32.random(in: 0..<UInt32.max), radix: 16)

    static var current = WatchConfig()

    /// Merge Info.plist API key when the stored config has none.
    static func resolved(_ base: WatchConfig = WatchConfig()) -> WatchConfig {
        var c = base
        if c.gatewayAPIKey.isEmpty,
           let k = Bundle.main.object(forInfoDictionaryKey: "SEAHELM_GATEWAY_API_KEY") as? String,
           !k.isEmpty {
            c.gatewayAPIKey = k
        }
        if c.gatewayBaseURL.isEmpty || c.gatewayBaseURL.contains("gw.ucar.cc") {
            c.gatewayBaseURL = "https://gw.seahelm.dev"
        }
        return c
    }

    /// Build from `seahelm://pair?b=..&m=..&k=..` — keeps gateway URL/key, applies mac + secret.
    static func from(pairLink: String, base: WatchConfig = WatchConfig()) -> WatchConfig? {
        guard let p = WatchCrypto.parsePairURI(pairLink.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        var c = resolved(base)
        if !p.mac.isEmpty { c.macId = p.mac }
        c.rootSecret = p.key
        return c
    }
}

enum Capability: String, Codable, CaseIterable {
    case read, interactive, control
    var canPick: Bool { self != .read }
    var canType: Bool { self == .control }
}
