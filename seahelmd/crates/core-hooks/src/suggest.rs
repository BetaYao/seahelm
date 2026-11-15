//! The inline suggestion marker an agent ends its reply with (once the
//! app's `StopHookResponder.swift`).
//!
//! Stop is an observation hook: it reports the final response and never
//! blocks the agent into another one. Options used to be reported by having
//! the agent run `seahelm-suggest` as its last action, which made its real
//! answer "text between tool calls" — exactly what Claude Code's TUI drops.
//! Now they ride the reply itself, on its last line, starting with
//! [`SENTINEL`], so the turn ends on plain text and nothing is lost.

use serde_json::Value;

use crate::Map;

/// e.g. `::seahelm-suggest:: build | test | ship`.
pub const SENTINEL: &str = "::seahelm-suggest::";

/// At most this many options make it onto a card.
const MAX_OPTIONS: usize = 5;

/// The declared options in `message`, or None when it does not end on a
/// marker line (or that line lists nothing). Tolerant of the backticks or
/// code fences an agent may wrap the line in.
pub fn parse_suggestions(message: &str) -> Option<Vec<String>> {
    let lines: Vec<&str> = message.split('\n').collect();
    let line = lines[marker_line(&lines)?];
    let after = &line.trim_start_matches(MARKER_PAD)[SENTINEL.len()..];
    let options: Vec<String> = after
        .split('|')
        .map(|o| o.trim_matches(MARKER_PAD).to_string())
        .filter(|o| !o.is_empty())
        .take(MAX_OPTIONS)
        .collect();
    (!options.is_empty()).then_some(options)
}

/// The prose with the marker line removed: the summary shown above the
/// option buttons, so the card shows the answer and not the marker. Only
/// the real marker line goes — prose that merely mentions the marker stays.
pub fn strip_sentinel(message: &str) -> String {
    let mut lines: Vec<&str> = message.split('\n').collect();
    if let Some(i) = marker_line(&lines) {
        lines.remove(i);
    }
    lines.join("\n").trim().to_string()
}

/// What may sit around the marker on its line: indentation, the backticks of
/// inline code, a stray carriage return.
const MARKER_PAD: [char; 4] = [' ', '\t', '`', '\r'];

/// The marker line: the reply's last line with any text, past closing code
/// fences, when it starts with [`SENTINEL`]. Searching from the top for any
/// line containing it made a reply that *quoted* the marker in its prose turn
/// that sentence into buttons, ignore the real line at the end, and lose the
/// quoting sentence from the card's summary.
fn marker_line(lines: &[&str]) -> Option<usize> {
    let i = lines.iter().rposition(|l| !l.trim_matches(MARKER_PAD).is_empty())?;
    lines[i].trim_start_matches(MARKER_PAD).starts_with(SENTINEL).then_some(i)
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
        let example = GUIDANCE.lines().find(|l| l.contains(SENTINEL)).unwrap();
        assert_eq!(parse_suggestions(example), Some(vec!["first option".into(), "second option".into()]));
        // The guidance itself only quotes the marker, mid-text: no buttons.
        assert_eq!(parse_suggestions(GUIDANCE), None);
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
    fn test_marker_quoted_in_prose_is_not_the_marker() {
        let msg = format!(
            "That row of buttons ({SENTINEL}), shot for real.\n\
             The last line ({SENTINEL} one | two). Stop hands it on.\n\
             {SENTINEL} fix it | ship it"
        );
        assert_eq!(parse_suggestions(&msg), Some(vec!["fix it".into(), "ship it".into()]));
        assert_eq!(
            strip_sentinel(&msg),
            format!("That row of buttons ({SENTINEL}), shot for real.\nThe last line ({SENTINEL} one | two). Stop hands it on.")
        );
    }

    #[test]
    fn test_marker_must_be_the_last_line() {
        let msg = format!("{SENTINEL} a | b\nand then more prose.");
        assert_eq!(parse_suggestions(&msg), None);
        assert_eq!(strip_sentinel(&msg), msg);
    }

    #[test]
    fn test_marker_line_past_fence_and_blank_lines() {
        let msg = format!("Done.\n```\n  {SENTINEL} a | b\n```\n\n");
        assert_eq!(parse_suggestions(&msg), Some(vec!["a".into(), "b".into()]));
        assert_eq!(strip_sentinel(&msg), "Done.\n```\n```");
    }

    #[test]
    fn test_marker_mid_line_at_the_end_is_not_the_marker() {
        assert_eq!(parse_suggestions(&format!("Use the {SENTINEL} a | b line")), None);
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

/// Add a trusted project snapshot while preserving each agent's hook shape.
pub fn append_context(output: &str, memory: &str) -> String {
    if memory.is_empty() { return output.into(); }
    let Ok(mut v) = serde_json::from_str::<Value>(output) else { return output.into() };
    let key = if v.get("hookSpecificOutput").is_some() { "/hookSpecificOutput/additionalContext" } else { "/additional_context" };
    if let Some(context) = v.pointer_mut(key) {
        *context = Value::String(format!("{}\n\n[seahelm project memory]\n{}", context.as_str().unwrap_or_default(), memory));
    }
    v.to_string()
}

#[cfg(test)]
mod memory_tests {
    use super::*;
    #[test] fn trusted_memory_reaches_all_supported_hook_shapes() {
        for source in ["claude-code", "codex", "cursor"] {
            let original = session_start_output(source).unwrap();
            let output = append_context(&original, "goal: ship phase 7");
            let v: Value = serde_json::from_str(&output).unwrap();
            let text = v.pointer("/hookSpecificOutput/additionalContext").or_else(|| v.get("additional_context")).unwrap().as_str().unwrap();
            assert!(text.contains(GUIDANCE)); assert!(text.contains("goal: ship phase 7"));
            assert_eq!(append_context(&original, ""), original);
        }
    }
}
