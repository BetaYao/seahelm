import Foundation

struct WeChatConfig: Codable, Equatable {
    let botToken: String
    var accountId: String?
    var baseUrl: String?
    var autoConnect: Bool?
    /// Long-poll cursor for resuming where we left off
    var syncBuf: String?
    /// Cached context tokens per user (needed for replies)
    var contextTokens: [String: String]?

    var resolvedAutoConnect: Bool { autoConnect ?? true }
    var resolvedBaseUrl: String { baseUrl ?? "https://ilinkai.weixin.qq.com" }

    enum CodingKeys: String, CodingKey {
        case botToken = "bot_token"
        case accountId = "account_id"
        case baseUrl = "base_url"
        case autoConnect = "auto_connect"
        case syncBuf = "sync_buf"
        case contextTokens = "context_tokens"
    }

    static func == (lhs: WeChatConfig, rhs: WeChatConfig) -> Bool {
        lhs.botToken == rhs.botToken
            && lhs.accountId == rhs.accountId
            && lhs.baseUrl == rhs.baseUrl
            && lhs.autoConnect == rhs.autoConnect
    }
}
