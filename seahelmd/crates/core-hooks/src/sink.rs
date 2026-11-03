//! The steps the app runs on every inbound hook event before the provider
//! and the registry see it (the event sink in `TabCoordinator.swift`).
//!
//! The core runs them in this order, which is the Swift's:
//!
//! 1. [`background_busy`] on the event, into the registry's per-worktree
//!    background flag;
//! 2. [`drops_suggest`] on the event — a suggestion that arrives while
//!    background work runs is dropped whole (the agent will resume on its
//!    own, so it is not a real end of turn);
//! 3. [`expand`] it, and hand each resulting event to the provider and then
//!    the registry, in order.
//!
//! The gate applies to the inbound event only: the `suggest` events
//! `expand` synthesises from a reply's sentinel line are not gated, as they
//! were not in the Swift.

use serde_json::Value;

use crate::event::{WebhookEvent, WebhookEventType};
use crate::suggest;

/// The source synthetic and CLI-reported suggestions carry.
pub const SUGGEST_SOURCE: &str = "seahelm-suggest";

/// The events to process for `ev`, in order: a synthetic `suggest` event for
/// options declared on a sentinel line (Cursor's `afterAgentResponse` prose,
/// or a Stop's `last_assistant_message`), then the event itself with the
/// sentinel line stripped from that prose, so nothing downstream shows the
/// marker. A Cursor reply's prose is always stripped, sentinel or not — the
/// Swift stashed it as the card summary either way; a Stop's only when it
/// declared options.
pub fn expand(mut ev: WebhookEvent) -> Vec<WebhookEvent> {
    let field = match ev.event {
        WebhookEventType::AssistantResponse => "text",
        WebhookEventType::AgentStop => "last_assistant_message",
        _ => return vec![ev],
    };
    let Some(prose) = ev.data_str(field).map(str::to_string) else { return vec![ev] };
    let options = suggest::parse_suggestions(&prose);
    let mut out = Vec::with_capacity(2);
    if let Some(options) = &options {
        let mut data = crate::Map::new();
        data.insert("options".into(), Value::from(options.clone()));
        out.push(WebhookEvent {
            source: SUGGEST_SOURCE.into(),
            session_id: ev.session_id.clone(),
            event: WebhookEventType::Suggest,
            cwd: ev.cwd.clone(),
            data,
            session_path: None,
            pane_id: ev.pane_id.clone(),
        });
    }
    if ev.event == WebhookEventType::AssistantResponse || options.is_some() {
        ev.data.insert(field.into(), Value::String(suggest::strip_sentinel(&prose)));
    }
    out.push(ev);
    out
}

/// What the event says about background work in its worktree:
/// `SubagentStart` → busy; Stop / SubagentStop → busy exactly when the
/// payload lists a running background task; anything else says nothing.
pub fn background_busy(ev: &WebhookEvent) -> Option<bool> {
    match ev.event {
        WebhookEventType::SubagentStart => Some(true),
        WebhookEventType::AgentStop | WebhookEventType::SubagentStop => {
            Some(suggest::has_running_background_task(&ev.data))
        }
        _ => None,
    }
}

/// Whether a `suggest` event is dropped because its worktree is busy with
/// background work.
pub fn drops_suggest(ev: &WebhookEvent, worktree_busy: bool) -> bool {
    ev.event == WebhookEventType::Suggest && worktree_busy
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ev(event: WebhookEventType, data: Value) -> WebhookEvent {
        let mut e = WebhookEvent::new("cursor", "c1", event, "/wt", data.as_object().unwrap().clone());
        e.pane_id = Some("pane-1".into());
        e
    }

    #[test]
    fn cursor_prose_with_a_sentinel_becomes_a_suggest_event_first() {
        let out = expand(ev(
            WebhookEventType::AssistantResponse,
            json!({"text": "Done.\n::seahelm-suggest:: run tests | open PR"}),
        ));
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].event, WebhookEventType::Suggest);
        assert_eq!(out[0].source, SUGGEST_SOURCE);
        assert_eq!(out[0].pane_id.as_deref(), Some("pane-1"));
        assert_eq!(out[0].data.get("options"), Some(&json!(["run tests", "open PR"])));
        assert_eq!(out[1].event, WebhookEventType::AssistantResponse);
        assert_eq!(out[1].data_str("text"), Some("Done."));
    }

    #[test]
    fn cursor_prose_without_a_sentinel_passes_through() {
        let out = expand(ev(WebhookEventType::AssistantResponse, json!({"text": "  All done.  "})));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].data_str("text"), Some("All done."));
    }

    #[test]
    fn a_stop_with_options_is_preceded_by_its_suggestion() {
        let out = expand(ev(
            WebhookEventType::AgentStop,
            json!({"last_assistant_message": "Fixed.\n`::seahelm-suggest:: ship | test`"}),
        ));
        assert_eq!(out.iter().map(|e| e.event).collect::<Vec<_>>(), vec![WebhookEventType::Suggest, WebhookEventType::AgentStop]);
        assert_eq!(out[1].data_str("last_assistant_message"), Some("Fixed."));
    }

    #[test]
    fn a_plain_stop_is_left_alone() {
        let out = expand(ev(WebhookEventType::AgentStop, json!({"last_assistant_message": " ok "})));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].data_str("last_assistant_message"), Some(" ok "));
        assert_eq!(expand(ev(WebhookEventType::ToolUseEnd, json!({}))).len(), 1);
    }

    #[test]
    fn background_work_is_read_off_subagent_and_stop_events() {
        assert_eq!(background_busy(&ev(WebhookEventType::SubagentStart, json!({}))), Some(true));
        assert_eq!(
            background_busy(&ev(WebhookEventType::AgentStop, json!({"background_tasks": [{"status": "running"}]}))),
            Some(true)
        );
        assert_eq!(background_busy(&ev(WebhookEventType::SubagentStop, json!({}))), Some(false));
        assert_eq!(background_busy(&ev(WebhookEventType::ToolUseEnd, json!({}))), None);
    }

    #[test]
    fn only_suggestions_are_dropped_and_only_when_busy() {
        let s = ev(WebhookEventType::Suggest, json!({"options": ["a"]}));
        assert!(drops_suggest(&s, true));
        assert!(!drops_suggest(&s, false));
        assert!(!drops_suggest(&ev(WebhookEventType::AgentStop, json!({})), true));
    }
}
