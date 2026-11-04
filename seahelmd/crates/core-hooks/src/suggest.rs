//! The inline suggestion marker an agent ends its reply with
//! (`StopHookResponder.swift`).
//!
//! Stop is an observation hook: it reports the final response and never
//! blocks the agent into another one. Options used to be reported by having
//! the agent run `seahelm-suggest` as its last action, which made its real
//! answer "text between tool calls" — exactly what Claude Code's TUI drops.
//! Now they ride the reply itself, on a line starting with [`SENTINEL`], so
//! the turn ends on plain text and nothing is lost.

use serde_json::Value;

use crate::Map;

/// e.g. `::seahelm-suggest:: build | test | ship`.
pub const SENTINEL: &str = "::seahelm-suggest::";

/// At most this many options make it onto a card.
const MAX_OPTIONS: usize = 5;

/// The declared options in `message`, or None when no line carries the
/// sentinel (or it lists nothing). Tolerant of the backticks or code fences
/// an agent may wrap the line in.
pub fn parse_suggestions(message: &str) -> Option<Vec<String>> {
    let line = message.split('\n').find(|l| l.contains(SENTINEL))?;
    let after = &line[line.find(SENTINEL)? + SENTINEL.len()..];
    let options: Vec<String> = after
        .split('|')
        .map(|o| o.trim_matches([' ', '\t', '`']).to_string())
        .filter(|o| !o.is_empty())
        .take(MAX_OPTIONS)
        .collect();
    (!options.is_empty()).then_some(options)
}

/// The prose with the sentinel line removed: the summary shown above the
/// option buttons, so the card shows the answer and not the marker.
pub fn strip_sentinel(message: &str) -> String {
    message.split('\n').filter(|l| !l.contains(SENTINEL)).collect::<Vec<_>>().join("\n").trim().to_string()
}

/// What an agent is told so it ends its replies with the marker: handed to
/// it as added context at every session start (and after a `/clear` or a
/// compaction, which are session starts too), so no repository's
/// `CLAUDE.md` has to carry it.
pub const GUIDANCE: &str = "You are running in a seahelm pane. When you finish a turn and can anticipate the \
user's likely next steps, end your reply with one final plain-text line formatted exactly as:\n\n    \
::seahelm-suggest:: first option | second option\n\nGive 2-5 short imperative phrases separated by ` | `. \
seahelm turns that line into buttons the user can tap. Make it the LAST line of your message; do not run a \
tool or shell command to produce it.";

/// What a SessionStart hook prints so `source`'s agent reads [`GUIDANCE`]:
/// each agent's own shape for added context. None for agents that take no
/// context from a hook (they are told some other way, or not at all).
pub fn session_start_output(source: &str) -> Option<String> {
    let v = match source {
        "claude-code" | "codex" => serde_json::json!({
            "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": GUIDANCE}
        }),
        "cursor" => serde_json::json!({"additional_context": GUIDANCE}),
        _ => return None,
    };
    Some(v.to_string())
}

/// Whether a Stop payload reports a background task still running. While
/// one is, the agent will resume on its own, so the turn has not really
/// ended.
pub fn has_running_background_task(data: &Map) -> bool {
    data.get("background_tasks")
        .and_then(Value::as_array)
        .filter(|tasks| tasks.iter().all(Value::is_object))
        .is_some_and(|tasks| tasks.iter().any(|t| t.get("status").and_then(Value::as_str) == Some("running")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn session_start_output_per_agent() {
        let claude: Value = serde_json::from_str(&session_start_output("claude-code").unwrap()).unwrap();
        assert_eq!(claude["hookSpecificOutput"]["hookEventName"], "SessionStart");
        assert!(claude["hookSpecificOutput"]["additionalContext"].as_str().unwrap().contains(SENTINEL));
        let cursor: Value = serde_json::from_str(&session_start_output("cursor").unwrap()).unwrap();
        assert!(cursor["additional_context"].as_str().unwrap().contains(SENTINEL));
        assert!(session_start_output("codex").is_some());
        assert_eq!(session_start_output("opencode"), None);
        assert_eq!(session_start_output(""), None);
        // The example line in the guidance parses as the real thing would.
        assert_eq!(parse_suggestions(GUIDANCE), Some(vec!["first option".into(), "second option".into()]));
    }

    #[test]
    fn test_parse_suggestions() {
        let msg = format!("Done.\nHere are next steps:\n{SENTINEL} build | run tests | ship it");
        assert_eq!(parse_suggestions(&msg), Some(vec!["build".into(), "run tests".into(), "ship it".into()]));
    }

    #[test]
    fn test_parse_suggestions_tolerant_of_backticks() {
        assert_eq!(parse_suggestions(&format!("`{SENTINEL} alpha | beta`")), Some(vec!["alpha".into(), "beta".into()]));
    }

    #[test]
    fn test_parse_suggestions_caps_at_five() {
        assert_eq!(parse_suggestions(&format!("{SENTINEL} a | b | c | d | e | f | g")).map(|o| o.len()), Some(5));
    }

    #[test]
    fn test_parse_suggestions_absent_returns_nil() {
        assert_eq!(parse_suggestions("Just a normal answer with no options."), None);
    }

    #[test]
    fn test_strip_sentinel_removes_marker_line() {
        assert_eq!(strip_sentinel(&format!("The answer is 42.\n{SENTINEL} a | b")), "The answer is 42.");
    }

    #[test]
    fn test_running_background_task_is_detected() {
        let data = json!({"background_tasks": [{"id": "b1", "type": "shell", "status": "running"}]});
        assert!(has_running_background_task(data.as_object().unwrap()));
    }

    #[test]
    fn test_completed_background_task_is_not_running() {
        let data = json!({"background_tasks": [{"id": "b1", "type": "shell", "status": "completed"}]});
        assert!(!has_running_background_task(data.as_object().unwrap()));
    }
}
