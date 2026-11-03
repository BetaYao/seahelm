//! Port of Tests/AgentRegistryWebhookPathTests.swift: the hook path is
//! status-neutral for poll-owned fields, and a Stop still completes.
//!
//! The Swift set status through the dead `updateStatus`; here a scan does.
//! The two "does not broadcast to an external channel" tests become what is
//! left of them in a crate with no channels: the event yields its outcome
//! and nothing else. `testTranscriptProseReachesTheTimelineOnce` is about
//! `MessageStreamHub`, which is not part of the registry.

mod common;

use common::*;
use seahelm_core_registry::{HookInput, HookResult, Registry};
use seahelm_core_types::{
    AgentStatus::*, AgentType, EventKind, EventSource, TaskItem, TaskItemStatus,
};

const TID: &str = "webhook-path-test-tid";
const WT: &str = "/tmp/webhook-path-test-repo";

fn setup() -> Registry {
    let mut r = Registry::new();
    register_full(&mut r, TID, WT, "feat-test", "WebhookTestProject", None);
    r
}

/// What `makeEvent` built, after the hooks crate's decoder.
fn webhook(r: &mut Registry, kind: Option<EventKind>, now: f64) -> HookResult {
    let input = HookInput {
        pane_hint: None,
        cwd: WT.into(),
        source: "claude-code".into(),
        kind,
        last_assistant_message: None,
    };
    r.ingest_hook(input, &|_| false, &authority_of, now)
}

fn poll(r: &mut Registry, round: f64, tasks: Vec<TaskItem>) {
    ingest(
        r,
        TID,
        EventSource::Scan,
        screen_full(Running, "doing stuff", AgentType::Unknown, round, tasks),
        T0,
    );
}

fn task(id: &str, subject: &str, status: TaskItemStatus) -> TaskItem {
    TaskItem {
        id: id.into(),
        subject: subject.into(),
        status,
    }
}

#[test]
fn tool_use_event_does_not_reset_tasks_or_round_duration() {
    let mut r = setup();
    poll(
        &mut r,
        42.0,
        vec![task("t1", "task-A", TaskItemStatus::Pending)],
    );
    webhook(&mut r, Some(tool("Bash", "", false, T0 + 1.0)), T0 + 1.0);
    let info = r.pane(TID).unwrap();
    assert_eq!(info.round_duration, 42.0);
    assert_eq!(info.tasks.len(), 1);
    assert_eq!(info.tasks[0].subject, "task-A");
}

#[test]
fn prompt_event_does_not_reset_tasks_or_round_duration() {
    let mut r = setup();
    poll(
        &mut r,
        99.5,
        vec![
            task("t2", "task-B", TaskItemStatus::Pending),
            task("t3", "task-C", TaskItemStatus::Completed),
        ],
    );
    webhook(
        &mut r,
        Some(EventKind::AwaitingInput {
            text: String::new(),
        }),
        T0 + 1.0,
    );
    let info = r.pane(TID).unwrap();
    assert_eq!(info.round_duration, 99.5);
    assert_eq!(info.tasks.len(), 2);
}

#[test]
fn tool_use_event_does_not_broadcast_to_external_channel() {
    let mut r = setup();
    poll(&mut r, 0.0, vec![]);
    let before = r.events().current_seq();
    let res = webhook(&mut r, Some(tool("Bash", "", false, T0 + 1.0)), T0 + 1.0);
    let o = res.outcome.expect("one outcome");
    assert_eq!(o.new_status, Running);
    let published = r.events().events_after(before);
    assert_eq!(
        published.len(),
        1,
        "exactly the pane event, no fan-out of its own"
    );
    assert_eq!(published[0]["type"], "pane.updated");
}

#[test]
fn status_change_does_not_fan_out_to_chat_from_agent_registry() {
    let mut r = setup();
    poll(&mut r, 0.0, vec![]);
    let o = webhook(
        &mut r,
        Some(EventKind::AwaitingInput {
            text: String::new(),
        }),
        T0 + 1.0,
    )
    .outcome
    .unwrap();
    assert_eq!(o.new_status, Waiting);
    assert_eq!(r.events().events_after(o.seq - 1).len(), 1);
}

#[test]
fn agent_stop_fires_completion_transition() {
    let mut r = setup();
    poll(&mut r, 5.0, vec![]);
    let o = webhook(&mut r, Some(stop(true)), T0 + 1.0).outcome.unwrap();
    assert!(o.is_completion_signal);
    assert_eq!(o.info.id, TID);
}

#[test]
fn agent_stop_uses_polled_status_as_old_status() {
    let mut r = setup();
    poll(&mut r, 5.0, vec![]);
    let o = webhook(&mut r, Some(stop(true)), T0 + 1.0).outcome.unwrap();
    assert_eq!(
        o.old_status, Running,
        "old status is what the poll set, not a freshly written Idle"
    );
}

// Beyond the Swift suite: the rest of `handleWebhookEvent`.

/// The hook's source types the pane, and a Stop's final prose is on the
/// completion event.
#[test]
fn hook_types_the_pane_and_carries_the_final_message() {
    let mut r = setup();
    let input = HookInput {
        pane_hint: None,
        cwd: format!("{WT}/src"),
        source: "claude-code".into(),
        kind: Some(stop(true)),
        last_assistant_message: Some("  修好了。 ".into()),
    };
    let res = r.ingest_hook(input, &|_| false, &authority_of, T0);
    assert_eq!(res.pane.as_deref(), Some(TID));
    let o = res.outcome.unwrap();
    assert_eq!(o.info.agent_type, AgentType::ClaudeCode);
    assert_eq!(o.info.last_assistant_message, "修好了。");
    assert_eq!(o.info.last_assistant_message_at, Some(T0));
    let ev = o.to_event();
    assert_eq!(ev["is_completion"], true);
    assert_eq!(ev["final_message"], "修好了。");
}

/// A hint that resolves to nothing falls back to the worktree's first pane,
/// and says so.
#[test]
fn unresolved_hint_falls_back_visibly() {
    let mut r = setup();
    let input = HookInput {
        pane_hint: Some("ghost".into()),
        cwd: WT.into(),
        source: "codex".into(),
        kind: None,
        last_assistant_message: None,
    };
    let res = r.ingest_hook(input, &|_| false, &authority_of, T0);
    assert_eq!(res.pane.as_deref(), Some(TID));
    assert!(res.fell_back_from_hint);
    assert!(
        res.outcome.is_none(),
        "a kind-less event only resolves and types"
    );
    assert_eq!(r.pane(TID).unwrap().agent_type, AgentType::Codex);
}

#[test]
fn note_assistant_message_does_not_touch_status() {
    let mut r = setup();
    poll(&mut r, 0.0, vec![]);
    assert_eq!(
        r.note_assistant_message(None, WT, "  summary  ", T0 + 1.0)
            .as_deref(),
        Some(TID)
    );
    let p = r.pane(TID).unwrap();
    assert_eq!(p.last_assistant_message, "summary");
    assert_eq!(p.last_message, "summary");
    assert_eq!(p.status, Running);
    assert_eq!(r.note_assistant_message(None, WT, "   ", T0), None);
    assert_eq!(r.note_assistant_message(None, "/elsewhere", "x", T0), None);
}
