import Foundation
import Darwin

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

    /// Page a browser opens to see one pane: this Mac's address, the gateway
    /// port, and `?pane=` so the web client hides the rest of the fleet.
    static func shareURL(host: String, port: UInt16, paneSessionKey: String) -> String {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "pane", value: paneSessionKey)]
        return components.string ?? "http://\(host):\(port)/?pane=\(paneSessionKey)"
    }

    enum CodingKeys: String, CodingKey {
        case enabled, port
        case publicURL = "public_url"
        case webRoot = "web_root"
        case pairCode = "pair_code"
        case telegramHost = "telegram_host"
    }
}

/// What the header's share button copies. `gatewayListening` is false when the
/// link is real but nothing is serving it yet.
struct PaneShareOffer: Equatable {
    var url: String
    var gatewayListening: Bool
}

/// IPv4 another machine on this network can open. `en0` (Wi-Fi) wins; otherwise
/// the first running interface that is not loopback, a tunnel, or a bridge.
enum LANAddress {
    static func ipv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var other: String?
        while let node = cursor {
            cursor = node.pointee.ifa_next
            guard let sa = node.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(node.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString: buffer)
            guard !ip.isEmpty, ip != "0.0.0.0" else { continue }
            let name = String(cString: node.pointee.ifa_name)
            if name == "en0" { return ip }
            if other == nil, !name.hasPrefix("awdl"), !name.hasPrefix("llw"),
               !name.hasPrefix("bridge"), !name.hasPrefix("utun") {
                other = ip
            }
        }
        return other
    }
}
