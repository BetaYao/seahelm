import Foundation

/// Where a normalized event came from.
enum EventSource {
    case scan
    case hook(String)   // raw webhook source string, e.g. "claude-code" / "codex"
    case mcp            // future
    case shell          // future
    case osc7501        // program status the program itself reported (ProgramStatus.swift)
}

/// The single input language. Event-native cases (hook/mcp/shell) carry no status —
/// reduce derives hookStatus. Screen-native (.screenObserved) carries the observed scan status.
/// One AskUserQuestion question: its prompt plus the option labels.
struct QuestionSpec: Equatable {
    let prompt: String
    let options: [String]
    var flags = QuestionFlags()
}

/// How a question is answered in Claude's AskUserQuestion dialog, which is all
/// arrow keys and Return (a digit arrives as pasted text and is ignored):
/// - single-select: Return picks the row under the cursor and moves on;
/// - multi-select: Return *toggles* that row, and → leaves the question;
/// - an ask of several questions, or one multi-select question, ends on a
///   "Review your answers" page whose first row (Submit) needs one more Return.
struct QuestionFlags: Equatable {
    var multiSelect = false
    /// Answering this question lands on the review page rather than submitting.
    var reviewAfter = false
    /// Multi-select rows toggled on so far (0-based), for the buttons' ticks.
    var checked: Set<Int> = []
    /// Row the dialog's cursor was last moved to (0-based) — where arrows count
    /// from when the screen can't be read.
    var cursor = 0
    /// One AskUserQuestion call (its `tool_use_id`), shared by its questions.
    /// Asking the same question again is a new call, so its card is a new
    /// Telegram message rather than a duplicate of the last one.
    var askId = ""
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
    case question(prompt: String, options: [String], followups: [QuestionSpec],
                  flags: QuestionFlags = QuestionFlags())
    case screenObserved(status: AgentStatus,
                        message: String,
                        activity: [ActivityEvent],
                        commandLine: String?,
                        agentType: AgentType,
                        roundDuration: TimeInterval,
                        tasks: [TaskItem],
                        backgroundBusy: Bool = false)
    // The pane's live OSC 7501 root record changed; nil = 7501 has nothing live
    // to say any more (cleared, or the program returned to the shell).
    case programStatus(ProgramStatusRecord?)
}

struct NormalizedEvent {
    let terminalID: String
    let source: EventSource
    let kind: NormalizedEventKind
}
