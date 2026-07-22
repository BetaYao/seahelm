import Foundation

/// Pure decision for the Stop hook reverse-trigger.
/// Returns a JSON body to force the agent to emit suggestions, or nil to let it stop.
/// The block reason tells the agent to run the installed `seahelm-suggest` script.
enum StopHookResponder {
    /// The agent declares next-step options by ending its reply with a line that
    /// begins with this token, e.g. `::seahelm-suggest:: build | test | ship`.
    ///
    /// This replaces the old "run `seahelm-suggest` via Bash" instruction. That
    /// made the agent's FINAL action a tool call, so its real answer prose sat
    /// immediately before a trailing tool_use — exactly the position Claude Code's
    /// TUI drops as "text between tool calls", swallowing the answer. Options now
    /// ride the Stop hook's own `last_assistant_message` round-trip (parsed by
    /// `parseSuggestions`), so the turn ends on plain text and nothing is lost.
    static let sentinel = "::seahelm-suggest::"

    /// Instruction handed to the agent when it stops without having declared
    /// options inline. Asks for one final PLAIN-TEXT line — no tool/shell call —
    /// so no trailing tool_use follows the answer.
    static var reason: String {
        "Before ending this turn, add one final line to your reply, formatted exactly as: "
            + "`\(sentinel) first option | second option` — put 2-5 short imperative next-step "
            + "options for the user there, separated by ` | `. seahelm turns that line into "
            + "clickable buttons for the user. Write it as plain text on its own line as the LAST "
            + "thing in your message; do NOT run any tool or shell command to do this."
    }

    /// Extract the declared options from a `last_assistant_message`. Returns nil
    /// when the sentinel line is absent (so the caller knows to prompt for it);
    /// otherwise a trimmed, non-empty list capped at 5. Tolerant of surrounding
    /// backticks / code fences the agent may wrap the line in.
    static func parseSuggestions(from message: String) -> [String]? {
        for raw in message.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let r = raw.range(of: sentinel) else { continue }
            let opts = raw[r.upperBound...]
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t`")) }
                .filter { !$0.isEmpty }
            return opts.isEmpty ? nil : Array(opts.prefix(5))
        }
        return nil
    }

    /// The assistant prose with the sentinel line removed — used as the summary
    /// above the option buttons so the card shows the answer, not the marker.
    static func stripSentinel(from message: String) -> String {
        message.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(sentinel) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func blockBody(for event: WebhookEvent, suggestOnStop: Bool) -> String? {
        guard suggestOnStop else { return nil }
        // Only the MAIN agent's Stop drives suggestions. SubagentStop (now a distinct
        // event) must never block — the main turn isn't over.
        guard event.event == .agentStop else { return nil }
        let active = event.data?["stop_hook_active"] as? Bool ?? false
        guard !active else { return nil }
        // Don't suggest while background work is still running — the main agent will
        // auto-resume when it finishes, so this Stop is not a real end-of-turn.
        // `background_tasks` is an official Stop-hook payload field (subagents + shell tasks).
        if hasRunningBackgroundTask(event.data) { return nil }
        // Don't interrupt when Claude is asking the user a question — forcing a
        // suggestion call in that state causes the agent to repeat its question.
        if isAskingQuestion(event.data) { return nil }
        // Cursor reports an aborted turn as a Stop with status "aborted" — the user
        // interrupted, so it isn't a real end-of-turn and must not prompt suggestions.
        if (event.data?["status"] as? String) == "aborted" { return nil }
        // The agent already declared its options inline (the common path): the
        // hook parses them from last_assistant_message, so there is nothing to
        // prompt for and no need to block.
        if let msg = event.data?["last_assistant_message"] as? String,
           parseSuggestions(from: msg) != nil { return nil }
        let escaped = reason.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"decision\":\"block\",\"reason\":\"\(escaped)\"}"
    }

    /// True if the last assistant message looks like a question to the user.
    static func isAskingQuestion(_ data: [String: Any]?) -> Bool {
        guard let msg = data?["last_assistant_message"] as? String else { return false }
        let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("?") || trimmed.hasSuffix("？")
    }

    /// True if the Stop payload reports any background task still running.
    static func hasRunningBackgroundTask(_ data: [String: Any]?) -> Bool {
        guard let tasks = data?["background_tasks"] as? [[String: Any]] else { return false }
        return tasks.contains { ($0["status"] as? String) == "running" }
    }
}
