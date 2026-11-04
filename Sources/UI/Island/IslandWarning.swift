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
    static func current(coreUnreachableSince: Date?, controlChannel: ControlSocketState?, now: Date = Date()) -> IslandWarning? {
        core(unreachableSince: coreUnreachableSince, now: now) ?? controlChannelWarning(controlChannel)
    }

    /// seahelm-core is not answering: statuses, cards, suggestions and First
    /// Mate are frozen at what it last said (docs/app-reads-core.md).
    static func core(unreachableSince: Date?, now: Date = Date()) -> IslandWarning? {
        guard let since = unreachableSince, now.timeIntervalSince(since) >= coreGrace else { return nil }
        return IslandWarning(
            badge: "CORE",
            message: "seahelm-core is not answering. Statuses, cards, suggestions and First Mate show what it last said; "
                + "seahelm keeps restarting and reconnecting to it.")
    }

    /// Only the states the app cannot resolve by itself: `ControlSocketServer`
    /// silently reclaims a vanished or stale socket path on its own, and
    /// telling the user to restart for something already being fixed would
    /// train them to ignore this.
    static func controlChannelWarning(_ state: ControlSocketState?) -> IslandWarning? {
        switch state {
        case .none, .listening?:
            return nil  // never started (e.g. the screenshot instance stands down), or fine
        case .standby?:
            return IslandWarning(
                badge: "CTRL",
                message: "Another Seahelm instance owns the control channel. The seahelm CLI is inactive in this window — quit the other instance to take it back.")
        case .stopped?:
            return IslandWarning(
                badge: "CTRL",
                message: "The control channel could not start. The seahelm CLI is unavailable — restarting Seahelm usually clears it.")
        }
    }
}
