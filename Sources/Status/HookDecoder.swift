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
            // Claude Code's UserPromptSubmit payload carries the text in `prompt`;
            // other sources use `message`. Fall back to a placeholder only if neither.
            return .userPrompt(event.data?["message"] as? String
                ?? event.data?["prompt"] as? String ?? "Processing prompt")
        case .toolUseStart, .toolUseEnd, .toolUseFailed:
            // AskUserQuestion blocks the agent on a choice — surface it as a
            // First Mate question card instead of a generic tool-use activity.
            if event.event == .toolUseStart,
               event.data?["tool_name"] as? String == "AskUserQuestion",
               let qs = questions(from: event), let first = qs.first {
                return .question(prompt: first.prompt, options: first.options,
                                 followups: Array(qs.dropFirst()))
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

    /// Extract every question (text + option labels) from an AskUserQuestion
    /// tool_input payload. Returns nil when nothing parses — the event then
    /// degrades to a normal tool-use activity. The TUI answers one question at a
    /// time, so multi-question prompts are tagged "(i/N)" and the card advances
    /// through them as each is answered.
    static func questions(from event: WebhookEvent) -> [QuestionSpec]? {
        guard let input = event.data?["tool_input"] as? [String: Any],
              let raw = input["questions"] as? [[String: Any]] else { return nil }
        let parsed: [QuestionSpec] = raw.compactMap { q in
            guard let prompt = q["question"] as? String, !prompt.isEmpty,
                  let rawOptions = q["options"] as? [[String: Any]] else { return nil }
            let labels = rawOptions.compactMap { $0["label"] as? String }.filter { !$0.isEmpty }
            guard !labels.isEmpty else { return nil }
            return QuestionSpec(prompt: prompt, options: labels)
        }
        guard !parsed.isEmpty else { return nil }
        guard parsed.count > 1 else { return parsed }
        return parsed.enumerated().map { index, q in
            QuestionSpec(prompt: "\(q.prompt) (\(index + 1)/\(parsed.count))", options: q.options)
        }
    }
}
