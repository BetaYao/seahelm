import Foundation

struct HostGatewayConfig: Codable, Equatable {
    var enabled: Bool?
    var port: UInt16?
    /// Public WSS URL embedded in pair `b=`. Empty → localhost derived URL.
    var publicURL: String?

    init(enabled: Bool? = nil, port: UInt16? = nil, publicURL: String? = nil) {
        self.enabled = enabled
        self.port = port
        self.publicURL = publicURL
    }

    var resolvedEnabled: Bool { enabled ?? false }
    var resolvedPort: UInt16 { port ?? 2783 }
    var resolvedPublicURL: String {
        if let publicURL, !publicURL.isEmpty { return publicURL }
        return "ws://127.0.0.1:\(resolvedPort)/ws"
    }

    enum CodingKeys: String, CodingKey {
        case enabled, port
        case publicURL = "public_url"
    }
}
