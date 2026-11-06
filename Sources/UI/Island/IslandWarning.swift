import Foundation

/// Something wrong the island has to say out loud, because a quiet island is
/// exactly what a healthy fleet looks like. Closed, it takes the left wing as
/// a badge; opened, a banner above the page.
struct IslandWarning: Equatable {
    /// A few capitals for the closed pill.
    let badge: String
    let message: String

    /// How long the core may stay silent before it is worth saying: covers
    /// the launch (`seahelm-core ensure` takes a moment) and a restart.
    static let coreGrace: TimeInterval = 6

    /// The first that applies: the core outranks the control channel, since
    /// without it nothing the island shows is current.
    static func current(coreUnreachableSince: Date?, controlChannel: ControlSocketState?, now: Date = Date(),
                        isChinese: Bool = false) -> IslandWarning? {
        core(unreachableSince: coreUnreachableSince, now: now, isChinese: isChinese)
            ?? controlChannelWarning(controlChannel, isChinese: isChinese)
    }

    /// seahelm-core is not answering: statuses, cards, suggestions and First
    /// Mate are frozen at what it last said (docs/app-reads-core.md).
    static func core(unreachableSince: Date?, now: Date = Date(), isChinese: Bool = false) -> IslandWarning? {
        guard let since = unreachableSince, now.timeIntervalSince(since) >= coreGrace else { return nil }
        return IslandWarning(
            badge: "CORE",
            message: isChinese
                ? "seahelm-core 暂无响应。状态、卡片、建议和 First Mate 暂时显示上次收到的内容；seahelm 正在持续重启并重新连接。"
                : "seahelm-core is not answering. Statuses, cards, suggestions and First Mate show what it last said; "
                    + "seahelm keeps restarting and reconnecting to it.")
    }

    /// Only the states the app cannot resolve by itself: `ControlSocketServer`
    /// silently reclaims a vanished or stale socket path on its own, and
    /// telling the user to restart for something already being fixed would
    /// train them to ignore this.
    static func controlChannelWarning(_ state: ControlSocketState?, isChinese: Bool = false) -> IslandWarning? {
        switch state {
        case .none, .listening?:
            return nil  // never started (e.g. the screenshot instance stands down), or fine
        case .standby?:
            return IslandWarning(
                badge: "CTRL",
                message: isChinese
                    ? "另一个 Seahelm 实例正在使用控制通道。此窗口中的 seahelm CLI 已停用；退出另一个实例即可接管。"
                    : "Another Seahelm instance owns the control channel. The seahelm CLI is inactive in this window — quit the other instance to take it back.")
        case .stopped?:
            return IslandWarning(
                badge: "CTRL",
                message: isChinese
                    ? "控制通道无法启动，seahelm CLI 暂不可用；重新启动 Seahelm 通常可以解决。"
                    : "The control channel could not start. The seahelm CLI is unavailable — restarting Seahelm usually clears it.")
        }
    }
}
