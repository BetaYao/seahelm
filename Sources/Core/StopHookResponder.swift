import Foundation

/// Pure decision for the Stop hook reverse-trigger.
/// Returns a JSON body to force the agent to emit suggestions, or nil to let it stop.
/// The block reason tells the agent to run the installed `seahelm-suggest` script.
enum StopHookResponder {
    /// Names the script by absolute path, and says "run … via Bash".
    ///
    /// Both halves were bugs on a fresh install. The bare name only resolved on
    /// machines whose shell profile had added `~/.local/bin` — the installers put
    /// the CLIs there, but nothing puts it on PATH, so every agent on a clean
    /// machine was told to call a command it could not find. The hook itself never
    /// had this problem because it is registered by absolute path
    /// (`ClaudeHooksSetup`, `CodexHooksSetup`); only the instruction it hands the
    /// agent was left to guess.
    ///
    /// "call `x`" also reads to an agent as the name of a *tool*: they search their
    /// toolset, find nothing, and report the tool missing rather than reaching for
    /// a shell. Naming Bash outright removes the ambiguity.
    static var reason: String {
        "Before ending this turn, run `\(SeahelmSuggestInstaller.scriptPath()) 'option one' 'option two'` "
            + "via Bash, with 2-5 short imperative next-step options for the user. "
            + "It is a shell script, not a tool. "
            + "Do NOT print them as text — the user sees them as clickable buttons."
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
