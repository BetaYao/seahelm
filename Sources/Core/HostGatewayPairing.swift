import Foundation

enum HostGatewayPairing {
    /// Pair-link `b=` endpoint: Host Gateway public WSS when enabled, else MQTT client broker.
    static func clientEntryURL(hostGateway: HostGatewayConfig?, mqtt: MqttConfig?) -> String {
        if hostGateway?.resolvedEnabled == true {
            return hostGateway!.resolvedPublicURL
        }
        if let mqtt {
            return mqtt.resolvedClientBrokerURL
        }
        var defaultMqtt: MqttConfig? = MqttConfig(host: "127.0.0.1")
        MqttConfig.normalizeForEdgeStack(&defaultMqtt)
        return defaultMqtt!.resolvedClientBrokerURL
    }
}
