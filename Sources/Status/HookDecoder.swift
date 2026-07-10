import Foundation

/// Signalman for the passive channel: webhook events → NormalizedEvent.
/// See the spec's "14 webhook events → Kind mapping table".
struct HookDecoder: SignalDecoder {
    let terminalID: String
    let event: WebhookEvent

    func decode() -> NormalizedEvent? {
        guard let kind = Self.kind(for: event) else { return nil }
        return NormalizedEvent(terminalID: terminalID, source: .hook(event.source), kind: kind)
    }

    /// Per-event human-readable message (canonical mapping used by HooksChannel).
    static func message(for event: WebhookEvent) -> String? {
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
        case .subagentStop:
            return nil
        case .cwdChanged:
            return nil
        case .suggest:
            return nil
        }
        return nil
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
            // AskUserQuestion blocks the agent on a choice — surface it as a
            // First Mate question card instead of a generic tool-use activity.
            if event.event == .toolUseStart,
               event.data?["tool_name"] as? String == "AskUserQuestion",
               let q = firstQuestion(from: event) {
                return .question(prompt: q.prompt, options: q.options)
            }
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
        case .subagentStop, .cwdChanged:
            // A subagent finishing must not drive the main station's status.
            return nil
        }
    }

    /// Extract the first question (text + option labels) from an AskUserQuestion
    /// tool_input payload. Returns nil when the payload doesn't parse — the event
    /// then degrades to a normal tool-use activity.
    static func firstQuestion(from event: WebhookEvent) -> (prompt: String, options: [String])? {
        guard let input = event.data?["tool_input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]],
              let first = questions.first,
              let prompt = first["question"] as? String, !prompt.isEmpty,
              let rawOptions = first["options"] as? [[String: Any]] else { return nil }
        let labels = rawOptions.compactMap { $0["label"] as? String }.filter { !$0.isEmpty }
        guard !labels.isEmpty else { return nil }
        // Multi-question flows answer one question at a time in the TUI; the card
        // shows the first, tagged with the total so the user knows more follow.
        let tagged = questions.count > 1 ? "\(prompt) (1/\(questions.count))" : prompt
        return (tagged, labels)
    }
}
