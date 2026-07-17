import Foundation

struct WeChatConfig: Codable, Equatable {
    var botToken: String
    var accountId: String?
    var baseUrl: String?
    var autoConnect: Bool?

    /// Long-poll cursor and context tokens live in `WeChatSessionStore`, not here —
    /// they churn per message and would be clobbered by whole-config saves.

    var resolvedAutoConnect: Bool { autoConnect ?? true }
    var resolvedBaseUrl: String { baseUrl ?? "https://ilinkai.weixin.qq.com" }

    enum CodingKeys: String, CodingKey {
        case botToken = "bot_token"
        case accountId = "account_id"
        case baseUrl = "base_url"
        case autoConnect = "auto_connect"
    }
}
