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
        guard event.event == .agentStop else { return nil }
        let active = event.data?["stop_hook_active"] as? Bool ?? false
        guard !active else { return nil }
        let escaped = reason.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"decision\":\"block\",\"reason\":\"\(escaped)\"}"
    }
}
