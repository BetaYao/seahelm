import Foundation

/// Pure decision for the Stop hook reverse-trigger.
/// Returns a JSON body to force the agent to emit suggestions, or nil to let it stop.
/// The block reason tells the agent to call the existing `seahelm-suggest` shell tool.
enum StopHookResponder {
    static let reason = "Before ending this turn, call `seahelm-suggest 'option one' 'option two'` "
        + "with 2-5 short imperative next-step options for the user. "
        + "Do NOT print them as text — the user sees them as clickable buttons."

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
        let escaped = reason.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"decision\":\"block\",\"reason\":\"\(escaped)\"}"
    }

    /// True if the Stop payload reports any background task still running.
    static func hasRunningBackgroundTask(_ data: [String: Any]?) -> Bool {
        guard let tasks = data?["background_tasks"] as? [[String: Any]] else { return false }
        return tasks.contains { ($0["status"] as? String) == "running" }
    }
}
