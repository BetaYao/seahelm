import Foundation

struct HostGatewayConfig: Codable, Equatable {
    var enabled: Bool?
    var port: UInt16?
    /// Public WSS URL embedded in pair `b=`. Empty → localhost derived URL.
    var publicURL: String?
    /// Directory served at `/`. Empty → the bundled `seahelm-web`; set it to a
    /// working copy to iterate on the web client without rebuilding the app.
    var webRoot: String?
    /// The code a remote client enters to pair with this host (see `PairingCodeStore`).
    /// Written only through `Config.persistPairCode`.
    var pairCode: String?
    /// The public hostname a Telegram Mini App opens this gateway on (e.g.
    /// `tg.seahelm.dev`). That host is reached without Cloudflare Access in
    /// front, so on it the pairing code is refused outright: only a signed
    /// Telegram launch from an allowed user, or a token already issued, gets
    /// in. Nil: no such host, nothing changes.
    var telegramHost: String?

    init(enabled: Bool? = nil,
         port: UInt16? = nil,
         publicURL: String? = nil,
         webRoot: String? = nil,
         pairCode: String? = nil,
         telegramHost: String? = nil) {
        self.enabled = enabled
        self.port = port
        self.publicURL = publicURL
        self.webRoot = webRoot
        self.pairCode = pairCode
        self.telegramHost = telegramHost
    }

    var resolvedEnabled: Bool { enabled ?? false }
    var resolvedPort: UInt16 { port ?? 2783 }
    var resolvedPublicURL: String {
        if let publicURL, !publicURL.isEmpty { return publicURL }
        return "ws://127.0.0.1:\(resolvedPort)/ws"
    }

    /// Page URL matching `resolvedPublicURL`, since both leave the same origin.
    var resolvedPageURL: String {
        guard var components = URLComponents(string: resolvedPublicURL) else {
            return "http://127.0.0.1:\(resolvedPort)/"
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = "/"
        return components.string ?? "http://127.0.0.1:\(resolvedPort)/"
    }

    /// Rebuild from the Settings fields. Text that is not a usable port keeps
    /// whatever was stored — 0 included, since it is the ephemeral-port wildcard
    /// and would publish a pair link pointing at a port nothing predictable is on.
    static func edited(enabled: Bool,
                       portText: String,
                       publicURLText: String,
                       from existing: HostGatewayConfig?) -> HostGatewayConfig {
        let typedPort = UInt16(portText.trimmingCharacters(in: .whitespaces))
        let url = publicURLText.trimmingCharacters(in: .whitespaces)
        return HostGatewayConfig(
            enabled: enabled,
            port: typedPort.flatMap { $0 > 0 ? $0 : nil } ?? existing?.port,
            // Empty means "derive from the port", which is what the field's
            // placeholder already shows; storing "" would resolve the same but
            // read as a deliberate blank in the JSON.
            publicURL: url.isEmpty ? nil : url,
            // No field carries the dev-only web root, so pass it through rather
            // than erase a working copy set by hand in config.json.
            webRoot: existing?.webRoot,
            pairCode: existing?.pairCode,
            telegramHost: existing?.telegramHost)
    }

    enum CodingKeys: String, CodingKey {
        case enabled, port
        case publicURL = "public_url"
        case webRoot = "web_root"
        case pairCode = "pair_code"
        case telegramHost = "telegram_host"
    }
}
