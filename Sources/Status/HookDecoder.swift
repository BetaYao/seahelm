import Foundation

/// 被动通道的信号员:webhook 事件 → NormalizedEvent。
/// 映射表见 spec「14 种 webhook 事件 → Kind 对齐表」。
struct HookDecoder: SignalDecoder {
    let terminalID: String
    let event: WebhookEvent

    func decode() -> NormalizedEvent? {
        guard let kind = Self.kind(for: event) else { return nil }
        return NormalizedEvent(terminalID: terminalID, source: .hook(event.source), kind: kind)
    }

    /// Pure mapping. Returns nil for events that produce no station event (cwd_changed).
    static func kind(for event: WebhookEvent) -> NormalizedEventKind? {
        switch event.event {
        case .sessionStart:
            return .sessionStarted(label: "Session started")
        case .worktreeCreate:
            return .sessionStarted(label: "Creating worktree")
        case .subagentStart:
            return .sessionStarted(label: "Subagent started")
        case .userPrompt:
            return .userPrompt(event.data?["message"] as? String ?? "Processing prompt")
        case .toolUseStart, .toolUseEnd, .toolUseFailed:
            return .toolUse(ActivityEventExtractor.extract(from: event))
        case .prompt:
            return .awaitingInput(event.data?["message"] as? String ?? "Waiting for input")
        case .agentStop:
            return .agentStopped(success: true)
        case .stopFailure:
            return .agentStopped(success: false)
        case .notification:
            let level = event.data?["level"] as? String ?? "info"
            let text = event.data?["message"] as? String ?? event.data?["title"] as? String ?? ""
            return .notification(level: level, text: text)
        case .error:
            return .notification(level: "error", text: event.data?["message"] as? String ?? "Error")
        case .suggest:
            let options = (event.data?["options"] as? [String]) ?? []
            return .suggest(options: options)
        case .cwdChanged:
            return nil
        }
    }
}
