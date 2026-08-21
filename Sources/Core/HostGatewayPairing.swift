import Foundation

enum HostGatewayPairing {
    /// Pair-link `b=` endpoint: Host Gateway public WSS when enabled, else the
    /// legacy `mqtt.client_broker` / derived broker URL kept for old configs.
    static func clientEntryURL(hostGateway: HostGatewayConfig?, mqtt: MqttConfig?) -> String {
        if hostGateway?.resolvedEnabled == true {
            return hostGateway!.resolvedPublicURL
        }
        if let mqtt {
            return mqtt.resolvedClientBrokerURL
        }
        return MqttConfig(host: "127.0.0.1").resolvedClientBrokerURL
    }
}
