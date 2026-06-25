import Foundation

/// Communication channel between ShipLog and a sub-agent.
/// Each agent gets one channel based on its type and capabilities.
protocol SailorChannel: AnyObject {
    /// The type of channel (for diagnostics and logging)
    var channelType: SailorChannelType { get }

    /// Send a text command to the agent's terminal
    func sendCommand(_ command: String)

    /// Read recent output from the agent
    func readOutput(lines: Int) -> String?

    /// Whether this channel supports receiving structured events (hooks, ACP)
    var supportsStructuredEvents: Bool { get }
}

enum SailorChannelType: String {
    case zmx        // Default: read/write via zmx commands
    case tmux       // Fallback: read/write via tmux commands
    case hooks      // Claude Code hooks: structured events via webhook + backend input channel
}

extension SailorChannel {
    var supportsStructuredEvents: Bool { false }
}
