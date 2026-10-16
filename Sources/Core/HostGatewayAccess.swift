import Foundation

/// What a gateway session needs to decide who may sign in, beyond the token
/// and pairing code it always knew: which host the request came in on, and
/// the Telegram bot that vouches for a Mini App launch.
struct HostGatewayAccess {
    /// `HostGatewayConfig.telegramHost`.
    var telegramHost: String?
    /// The Host header of this session's upgrade request; read at auth.
    var frontHost: () -> String?
    /// Read at auth, so an allowlist edited in Settings applies at once.
    var telegram: () -> TelegramConfig?

    init(telegramHost: String? = nil,
         frontHost: @escaping () -> String? = { nil },
         telegram: @escaping () -> TelegramConfig? = { nil }) {
        self.telegramHost = telegramHost
        self.frontHost = frontHost
        self.telegram = telegram
    }

    /// The request came in on the Mini App host, which Cloudflare Access does
    /// not cover — so the pairing code is not accepted there.
    var isTelegramOnly: Bool {
        guard let wanted = telegramHost?.trimmingCharacters(in: .whitespaces).lowercased(),
              !wanted.isEmpty, let host = frontHost() else { return false }
        return host == wanted
    }

    /// The allowed Telegram user a Mini App launch was signed for, or nil.
    func telegramUser(initData: String, now: Date = Date()) -> TelegramInitData.User? {
        guard let config = telegram(), let token = config.resolvedBotToken,
              case .success(let user) = TelegramInitData.validate(initData, botToken: token, now: now),
              config.allows(userId: user.id, username: user.username) else { return nil }
        return user
    }
}
