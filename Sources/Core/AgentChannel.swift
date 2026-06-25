import Foundation

/// Communication channel between AgentHead and a sub-agent.
/// Each agent gets one channel based on its type and capabilities.
protocol AgentChannel: AnyObject {
    /// The type of channel (for diagnostics and logging)
    var channelType: AgentChannelType { get }

    /// Send a text command to the agent's terminal
    func sendCommand(_ command: String)

    /// Read recent output from the agent
    func readOutput(lines: Int) -> String?

    /// Whether this channel supports receiving structured events (hooks, ACP)
    var supportsStructuredEvents: Bool { get }
}

enum AgentChannelType: String {
    case zmx        // Default: read/write via zmx commands
    case tmux       // Fallback: read/write via tmux commands
    case hooks      // Claude Code hooks: structured events via webhook + backend input channel
}

extension AgentChannel {
    var supportsStructuredEvents: Bool { false }
}
