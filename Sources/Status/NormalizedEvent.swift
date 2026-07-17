import Foundation

/// Where a normalized event came from.
enum EventSource {
    case scan
    case hook(String)   // raw webhook source string, e.g. "claude-code" / "codex"
    case mcp            // future
    case shell          // future
}

/// The single input language. Event-native cases (hook/mcp/shell) carry no status —
/// reduce derives hookStatus. Screen-native (.screenObserved) carries the observed scan status.
/// One AskUserQuestion question: its prompt plus the option labels.
struct QuestionSpec: Equatable {
    let prompt: String
    let options: [String]
}

enum NormalizedEventKind {
    case sessionStarted(label: String)        // session_start / worktree_create / subagent_start
    case userPrompt(String)                   // user_prompt — user submitted
    case toolUse(ActivityEvent)               // tool_use_start/end/failed
    case awaitingInput(String)                // prompt — agent waiting for input
    case agentStopped(success: Bool)          // agent_stop(true) / stop_failure(false)
    case notification(level: String, text: String)  // notification / error(level:"error")
    case taskUpdate([TaskItem])               // future (MCP / derived)
    case suggest(options: [String])           // agent-authored candidate orders
    // AskUserQuestion tool — agent blocked on a choice. A multi-question call
    // carries the remaining questions in `followups` (prompts pre-tagged "(i/N)")
    // so the card can advance as each one is answered.
    case question(prompt: String, options: [String], followups: [QuestionSpec])
    case screenObserved(status: SailorStatus,
                        message: String,
                        activity: [ActivityEvent],
                        commandLine: String?,
                        agentType: SailorType,
                        roundDuration: TimeInterval,
                        tasks: [TaskItem])
}

struct NormalizedEvent {
    let terminalID: String
    let source: EventSource
    let kind: NormalizedEventKind
}
