import Foundation

struct WeComBotConfig: Codable, Equatable {
    let botId: String
    let secret: String
    var name: String?
    var autoConnect: Bool?
    var maxReconnectInterval: TimeInterval?

    var resolvedAutoConnect: Bool { autoConnect ?? true }
    var resolvedMaxReconnectInterval: TimeInterval { maxReconnectInterval ?? 30.0 }
    var resolvedName: String { name ?? "Seahelm Bot" }

    enum CodingKeys: String, CodingKey {
        case botId = "bot_id"
        case secret
        case name
        case autoConnect = "auto_connect"
        case maxReconnectInterval = "max_reconnect_interval"
    }
}
