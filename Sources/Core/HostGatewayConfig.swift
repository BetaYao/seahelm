import Foundation

struct HostGatewayConfig: Codable, Equatable {
    var enabled: Bool?
    var port: UInt16?
    /// Public WSS URL embedded in pair `b=`. Empty → localhost derived URL.
    var publicURL: String?
    /// Directory served at `/`. Empty → the bundled `seahelm-web`; set it to a
    /// working copy to iterate on the web client without rebuilding the app.
    var webRoot: String?

    init(enabled: Bool? = nil,
         port: UInt16? = nil,
         publicURL: String? = nil,
         webRoot: String? = nil) {
        self.enabled = enabled
        self.port = port
        self.publicURL = publicURL
        self.webRoot = webRoot
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

    enum CodingKeys: String, CodingKey {
        case enabled, port
        case publicURL = "public_url"
        case webRoot = "web_root"
    }
}
