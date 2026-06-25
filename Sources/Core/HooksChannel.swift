import Foundation

/// Communication channel for Claude Code via Hooks.
/// Receives structured events through the existing WebhookServer,
/// sends commands via backend channel (zmx by default).
class HooksChannel: AgentChannel {
    let channelType: AgentChannelType = .hooks
    let supportsStructuredEvents = true

    private let transport: AgentChannel
    private let lock = NSLock()

    /// Accumulated hook events for this agent session
    private(set) var events: [HookEvent] = []

    init(sessionName: String, backend: String = "zmx") {
        if backend == "tmux" {
            self.transport = TmuxChannel(sessionName: sessionName)
        } else {
            self.transport = ZmxChannel(sessionName: sessionName)
        }
    }

    // MARK: - AgentChannel

    /// Send command via backend channel (hooks don't provide an input channel)
    func sendCommand(_ command: String) {
        transport.sendCommand(command)
    }

    /// Read output via backend channel (hooks provide events, not raw output)
    func readOutput(lines: Int) -> String? {
        transport.readOutput(lines: lines)
    }

    // MARK: - Hook Events

    /// Called by AgentHead when a WebhookEvent arrives for this agent
    func handleWebhookEvent(_ event: WebhookEvent) {
        let hookEvent = HookEvent(
            timestamp: Date(),
            type: event.event,
            toolName: event.data?["tool_name"] as? String,
            message: extractMessage(from: event),
            rawData: event.data
        )

        lock.lock()
        events.append(hookEvent)
        // Keep last 200 events to prevent unbounded growth
        if events.count > 200 {
            events.removeFirst(events.count - 200)
        }
        lock.unlock()
    }

    /// Get the most recent event
    var lastEvent: HookEvent? {
        lock.lock()
        defer { lock.unlock() }
        return events.last
    }

    /// Get events since a given date
    func eventsSince(_ date: Date) -> [HookEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0.timestamp >= date }
    }

    /// Clear event history
    func clearEvents() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private func extractMessage(from event: WebhookEvent) -> String? {
        switch event.event {
        case .toolUseStart:
            if let tool = event.data?["tool_name"] as? String {
                return "Using \(tool)"
            }
        case .toolUseEnd:
            if let tool = event.data?["tool_name"] as? String {
                return "Done: \(tool)"
            }
        case .agentStop:
            if let reason = event.data?["stop_reason"] as? String {
                return "Stopped: \(reason)"
            }
        case .error:
            return event.data?["message"] as? String
        case .prompt:
            return event.data?["message"] as? String ?? "Waiting for input"
        case .notification:
            return event.data?["message"] as? String ?? event.data?["title"] as? String
        case .sessionStart:
            return "Session started"
        case .worktreeCreate:
            return "Creating worktree"
        case .userPrompt:
            return "Processing prompt"
        case .toolUseFailed:
            if let tool = event.data?["tool_name"] as? String {
                return "Failed: \(tool)"
            }
            return "Tool failed"
        case .stopFailure:
            return event.data?["error"] as? String ?? "API error"
        case .subagentStart:
            return "Subagent started"
        case .cwdChanged:
            return nil
        case .suggest:
            return nil
        }
        return nil
    }
}

/// A structured event received through hooks
struct HookEvent {
    let timestamp: Date
    let type: WebhookEventType
    let toolName: String?
    let message: String?
    let rawData: [String: Any]?
}
