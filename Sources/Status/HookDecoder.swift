import Foundation

/// 被动通道的信号员:Claude Code 钩子事件 → StatusReport。
/// 无瞭望员——水手主动喊报告(webhook 推送),本类型只负责解码。
struct HookDecoder: SignalDecoder {
    let event: WebhookEvent

    func decode() -> StatusReport? {
        let status = event.event.agentStatus(data: event.data)
        let message = mappedMessage ?? ""
        let events = activityEvents
        return StatusReport(status: status, lastMessage: message, activityEvents: events)
    }

    // MARK: - Private helpers (mirrored from HooksChannel.extractMessage)

    private var mappedMessage: String? {
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

    private var activityEvents: [ActivityEvent] {
        switch event.event {
        case .toolUseStart, .toolUseEnd, .toolUseFailed:
            return [ActivityEventExtractor.extract(from: event)]
        default:
            return []
        }
    }
}
