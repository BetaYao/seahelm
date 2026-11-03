//! Hook events in the core's one event language (`HookDecoder.swift`).
//!
//! The kinds carry no status: the registry derives the hook status from
//! them. Three events decode to nothing: `subagent_stop` (a subagent
//! finishing must not drive the main pane), `cwd_changed` (routing only) and
//! `assistant_response` (observed for its prose, see [`crate::sink`]).

use seahelm_core_types::{EventKind, QuestionFlags, QuestionSpec, Timestamp};
use serde_json::Value;

use crate::activity;
use crate::event::{WebhookEvent, WebhookEventType as T};

pub fn decode(ev: &WebhookEvent, now: Timestamp) -> Option<EventKind> {
    let text = |key: &str| ev.data_str(key).map(str::to_string);
    Some(match ev.event {
        T::SessionStart => EventKind::SessionStarted { label: "Session started".into() },
        T::WorktreeCreate => EventKind::SessionStarted { label: "Creating worktree".into() },
        T::SubagentStart => EventKind::SessionStarted { label: "Subagent started".into() },
        // Claude's UserPromptSubmit carries the text in `prompt`; other
        // sources use `message`.
        T::UserPrompt => EventKind::UserPrompt {
            text: text("message").or_else(|| text("prompt")).unwrap_or_else(|| "Processing prompt".into()),
        },
        T::ToolUseStart | T::ToolUseEnd | T::ToolUseFailed => {
            // AskUserQuestion blocks the agent on a choice: a question card,
            // not a tool-use line.
            if ev.event == T::ToolUseStart && ev.data_str("tool_name") == Some("AskUserQuestion") {
                if let Some(mut qs) = questions(ev, now) {
                    let first = qs.remove(0);
                    return Some(EventKind::Question {
                        prompt: first.prompt,
                        options: first.options,
                        followups: qs,
                        flags: first.flags,
                    });
                }
            }
            EventKind::ToolUse { activity: activity::extract(ev, now) }
        }
        T::Prompt => EventKind::AwaitingInput { text: text("message").unwrap_or_else(|| "Waiting for input".into()) },
        T::AgentStop => EventKind::AgentStopped { success: true },
        T::StopFailure => EventKind::AgentStopped { success: false },
        T::Notification => EventKind::Notification {
            level: text("level").unwrap_or_else(|| "info".into()),
            text: text("message").or_else(|| text("title")).unwrap_or_default(),
        },
        T::Error => EventKind::Notification {
            level: "error".into(),
            text: text("message").unwrap_or_else(|| "Error".into()),
        },
        T::Suggest => EventKind::Suggest { options: string_list(ev.data.get("options")).unwrap_or_default() },
        T::SubagentStop | T::CwdChanged | T::AssistantResponse => return None,
    })
}

/// The one-line message an event shows beside a pane (`HookDecoder.message`).
pub fn message(ev: &WebhookEvent) -> Option<String> {
    let text = |key: &str| ev.data_str(key).map(str::to_string);
    match ev.event {
        T::ToolUseStart => text("tool_name").map(|t| format!("Using {t}")),
        T::ToolUseEnd => text("tool_name").map(|t| format!("Done: {t}")),
        T::AgentStop => text("stop_reason").map(|r| format!("Stopped: {r}")),
        T::Error => text("message"),
        T::Prompt => Some(text("message").unwrap_or_else(|| "Waiting for input".into())),
        T::Notification => text("message").or_else(|| text("title")),
        T::SessionStart => Some("Session started".into()),
        T::WorktreeCreate => Some("Creating worktree".into()),
        T::UserPrompt => Some("Processing prompt".into()),
        T::ToolUseFailed => Some(text("tool_name").map(|t| format!("Failed: {t}")).unwrap_or_else(|| "Tool failed".into())),
        T::StopFailure => Some(text("error").unwrap_or_else(|| "API error".into())),
        T::SubagentStart => Some("Subagent started".into()),
        T::SubagentStop | T::CwdChanged | T::Suggest | T::AssistantResponse => None,
    }
}

/// Every question of an AskUserQuestion call, or None when nothing parses
/// (the event then degrades to an ordinary tool-use line). The TUI answers
/// one question at a time, so several are tagged "(i/N)" and the card steps
/// through them; only the last of several lands on the review page.
pub fn questions(ev: &WebhookEvent, now: Timestamp) -> Option<Vec<QuestionSpec>> {
    let input = ev.data.get("tool_input")?.as_object()?;
    let raw = input.get("questions")?.as_array()?;
    // Swift read these as `[[String: Any]]`: a non-object spoils the list.
    if !raw.iter().all(Value::is_object) {
        return None;
    }
    let ask_id = ev.data_str("tool_use_id").map(str::to_string).unwrap_or_else(|| synthetic_ask_id(ev, now));
    let parsed: Vec<QuestionSpec> = raw
        .iter()
        .filter_map(|q| {
            let prompt = q.get("question")?.as_str().filter(|p| !p.is_empty())?;
            let options = q.get("options")?.as_array()?;
            if !options.iter().all(Value::is_object) {
                return None;
            }
            let labels: Vec<String> = options
                .iter()
                .filter_map(|o| o.get("label").and_then(Value::as_str))
                .filter(|l| !l.is_empty())
                .map(str::to_string)
                .collect();
            if labels.is_empty() {
                return None;
            }
            let multi = q.get("multiSelect").and_then(Value::as_bool).unwrap_or(false);
            Some(QuestionSpec {
                prompt: prompt.into(),
                options: labels,
                flags: QuestionFlags { multi_select: multi, review_after: multi, ask_id: ask_id.clone(), ..Default::default() },
            })
        })
        .collect();
    match parsed.len() {
        0 => None,
        1 => Some(parsed),
        n => Some(
            parsed
                .into_iter()
                .enumerate()
                .map(|(i, mut q)| {
                    q.flags.review_after = i == n - 1;
                    q.prompt = format!("{} ({}/{})", q.prompt, i + 1, n);
                    q
                })
                .collect(),
        ),
    }
}

/// A stand-in for a missing `tool_use_id`: the Swift minted a random UUID.
/// Here it is derived from the call itself, so it is stable for one call
/// and distinct between calls, with no randomness to inject.
fn synthetic_ask_id(ev: &WebhookEvent, now: Timestamp) -> String {
    use md5::{Digest, Md5};
    let input = ev.data.get("tool_input").map(Value::to_string).unwrap_or_default();
    let digest = Md5::digest(format!("{}\0{}\0{now}\0{input}", ev.session_id, ev.pane_id.as_deref().unwrap_or("")));
    let h: String = digest.iter().map(|b| format!("{b:02X}")).collect();
    format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..])
}

/// A JSON array of strings, as Swift's `as? [String]` read it: one
/// non-string and it is not a list of strings at all.
pub(crate) fn string_list(v: Option<&Value>) -> Option<Vec<String>> {
    v?.as_array()?.iter().map(|s| s.as_str().map(str::to_string)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn make(event: T, data: Value) -> WebhookEvent {
        WebhookEvent::new("claude-code", "test-session", event, "/tmp/test-worktree", data.as_object().cloned().unwrap_or_default())
    }

    fn kind(event: T, data: Value) -> Option<EventKind> {
        decode(&make(event, data), 0.0)
    }

    #[test]
    fn test_agent_stop_maps_to_agent_stopped() {
        assert_eq!(kind(T::AgentStop, json!({"stop_reason": "end_turn"})), Some(EventKind::AgentStopped { success: true }));
    }

    #[test]
    fn test_stop_failure_maps_to_agent_stopped_failure() {
        assert_eq!(kind(T::StopFailure, json!({})), Some(EventKind::AgentStopped { success: false }));
    }

    #[test]
    fn test_tool_use_start_maps_to_tool_use() {
        let Some(EventKind::ToolUse { activity }) = kind(T::ToolUseStart, json!({"tool_name": "Bash"})) else {
            panic!("wrong kind")
        };
        assert_eq!(activity.tool, "Bash");
    }

    #[test]
    fn test_ask_user_question_maps_to_question() {
        let k = kind(
            T::ToolUseStart,
            json!({"tool_name": "AskUserQuestion", "tool_input": {"questions": [{
                "question": "Where should daily check-in happen?",
                "options": [{"label": "Gate face scan"}, {"label": "Front desk kiosk"}]}]}}),
        );
        let Some(EventKind::Question { prompt, options, .. }) = k else { panic!("wrong kind") };
        assert_eq!(prompt, "Where should daily check-in happen?");
        assert_eq!(options, vec!["Gate face scan", "Front desk kiosk"]);
    }

    #[test]
    fn test_ask_user_question_multi_question_tags_count() {
        let k = kind(
            T::ToolUseStart,
            json!({"tool_name": "AskUserQuestion", "tool_input": {"questions": [
                {"question": "Q1?", "options": [{"label": "A"}, {"label": "B"}]},
                {"question": "Q2?", "options": [{"label": "C"}]}]}}),
        );
        let Some(EventKind::Question { prompt, .. }) = k else { panic!("wrong kind") };
        assert_eq!(prompt, "Q1? (1/2)");
    }

    #[test]
    fn test_ask_user_question_flags_multi_select_and_review_page() {
        fn shape(f: &QuestionFlags) -> (bool, bool) {
            (f.multi_select, f.review_after)
        }
        let flags = |questions: Value| {
            let Some(EventKind::Question { followups, flags, .. }) =
                kind(T::ToolUseStart, json!({"tool_name": "AskUserQuestion", "tool_input": {"questions": questions}}))
            else {
                return None;
            };
            Some((shape(&flags), followups.iter().map(|q| shape(&q.flags)).collect::<Vec<_>>()))
        };
        let single = flags(json!([{"question": "Q?", "options": [{"label": "A"}, {"label": "B"}]}])).unwrap();
        assert_eq!(single.0, (false, false));
        let multi = flags(json!([{"question": "Q?", "multiSelect": true, "options": [{"label": "A"}, {"label": "B"}]}])).unwrap();
        assert_eq!(multi.0, (true, true));
        let two = flags(json!([
            {"question": "Q1?", "multiSelect": true, "options": [{"label": "A"}, {"label": "B"}]},
            {"question": "Q2?", "options": [{"label": "C"}, {"label": "D"}]}]))
        .unwrap();
        assert_eq!(two.0, (true, false));
        assert_eq!(two.1, vec![(false, true)]);
    }

    #[test]
    fn test_questions_of_one_ask_share_its_tool_use_id() {
        let k = kind(
            T::ToolUseStart,
            json!({"tool_name": "AskUserQuestion", "tool_use_id": "toolu_1", "tool_input": {"questions": [
                {"question": "Q1?", "options": [{"label": "A"}, {"label": "B"}]},
                {"question": "Q2?", "options": [{"label": "C"}, {"label": "D"}]}]}}),
        );
        let Some(EventKind::Question { followups, flags, .. }) = k else { panic!("wrong kind") };
        assert_eq!(flags.ask_id, "toolu_1");
        assert_eq!(followups.iter().map(|q| q.flags.ask_id.as_str()).collect::<Vec<_>>(), vec!["toolu_1"]);
    }

    #[test]
    fn test_ask_user_question_with_bad_payload_degrades_to_tool_use() {
        assert!(matches!(kind(T::ToolUseStart, json!({"tool_name": "AskUserQuestion"})), Some(EventKind::ToolUse { .. })));
    }

    #[test]
    fn test_prompt_maps_to_awaiting_input() {
        assert_eq!(kind(T::Prompt, json!({"message": "Continue?"})), Some(EventKind::AwaitingInput { text: "Continue?".into() }));
    }

    #[test]
    fn test_error_maps_to_notification_error() {
        assert_eq!(
            kind(T::Error, json!({"message": "Something went wrong"})),
            Some(EventKind::Notification { level: "error".into(), text: "Something went wrong".into() })
        );
    }

    #[test]
    fn test_session_start_maps_to_session_started() {
        assert_eq!(kind(T::SessionStart, json!({})), Some(EventKind::SessionStarted { label: "Session started".into() }));
    }

    #[test]
    fn test_tool_use_end_produces_tool_use_activity() {
        let Some(EventKind::ToolUse { activity }) = kind(T::ToolUseEnd, json!({"tool_name": "Read"})) else {
            panic!("wrong kind")
        };
        assert_eq!(activity.tool, "Read");
    }

    #[test]
    fn test_cwd_changed_produces_nil() {
        assert_eq!(kind(T::CwdChanged, json!({})), None);
        assert_eq!(kind(T::SubagentStop, json!({})), None);
        assert_eq!(kind(T::AssistantResponse, json!({"text": "x"})), None);
    }

    #[test]
    fn synthetic_ask_ids_are_stable_per_call() {
        let e = make(T::ToolUseStart, json!({"tool_name": "AskUserQuestion", "tool_input": {"questions": [
            {"question": "Q?", "options": [{"label": "A"}]}]}}));
        let a = questions(&e, 5.0).unwrap();
        let b = questions(&e, 5.0).unwrap();
        assert_eq!(a[0].flags.ask_id, b[0].flags.ask_id);
        assert_eq!(a[0].flags.ask_id.len(), 36);
    }
}
