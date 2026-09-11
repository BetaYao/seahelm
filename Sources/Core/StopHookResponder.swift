import Foundation

/// Shared parsing for the inline suggestion marker carried by an agent's final
/// Stop-hook message.
///
/// Stop remains an observation hook: it reports the final response, but never
/// blocks the agent to ask for another response. The inline marker is parsed
/// from that response when present.
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

    /// Extract the declared options from a `last_assistant_message`. Returns nil
    /// when the sentinel line is absent; otherwise a trimmed, non-empty list
    /// capped at 5, tolerant of surrounding backticks / code fences the agent
    /// may wrap the line in.
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

    /// True if the Stop payload reports any background task still running.
    /// This remains useful to the status pipeline even though Stop no longer
    /// blocks the agent.
    static func hasRunningBackgroundTask(_ data: [String: Any]?) -> Bool {
        guard let tasks = data?["background_tasks"] as? [[String: Any]] else { return false }
        return tasks.contains { ($0["status"] as? String) == "running" }
    }

    /// The assistant prose with the sentinel line removed — used as the summary
    /// above the option buttons so the card shows the answer, not the marker.
    static func stripSentinel(from message: String) -> String {
        message.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(sentinel) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
