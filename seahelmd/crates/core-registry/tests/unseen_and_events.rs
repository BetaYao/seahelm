//! Port of the registry parts of Tests/UnseenCompletionTests.swift and of
//! Tests/EventHubTests.swift. Not ported: the grouping tests
//! (`WorktreeGrouping`, a client concern), the gateway test, and the hub's
//! subscriber / filter / envelope tests (`ControlRouter`, the RPC layer;
//! the hub here is polled with `events_after` instead of pushing).

mod common;

use common::*;
use seahelm_core_registry::events::{human_prompt_text, EventHub, RING_CAPACITY};
use seahelm_core_registry::{unseen, Registration, Registry};
use seahelm_core_types::{AgentStatus::*, AgentType, EventKind, EventSource};
use serde_json::json;

#[test]
fn only_a_turn_ending_marks_it() {
    assert!(unseen::marks(Running, Idle));
    assert!(
        !unseen::marks(Waiting, Idle),
        "answering a question is not a finished turn"
    );
    assert!(!unseen::marks(Running, Waiting));
}

#[test]
fn anything_the_agent_does_next_clears_it() {
    for s in [Running, Waiting, Error, Exited] {
        assert!(unseen::clears(s), "{s:?}");
    }
    assert!(!unseen::clears(Idle));
    assert!(
        !unseen::clears(Unknown),
        "a pane the scan lost sight of has not been read"
    );
}

#[test]
fn registry_reports_only_changes() {
    let mut r = Registry::new();
    register(&mut r, "s", "/tmp/unseen-wt");
    assert!(r.set_unseen("s", true));
    assert!(!r.set_unseen("s", true));
    assert!(r.pane("s").unwrap().unseen_completion);
    assert!(r.set_unseen("s", false));
    assert!(!r.set_unseen("nobody", true));
}

#[test]
fn a_moved_pane_keeps_its_unread_finish() {
    let mut r = Registry::new();
    register(&mut r, "t", "/a");
    r.set_unseen("t", true);
    let p = r.pane("t").unwrap();
    assert!(p.rehomed("/b", "b", "P").unseen_completion);
}

#[test]
fn unseen_change_is_published() {
    let mut r = Registry::new();
    r.register(Registration {
        pane: "k1".into(),
        alias: Some("p1".into()),
        worktree_path: "/a".into(),
        project: "P".into(),
        branch: "b".into(),
        agent_type: AgentType::Unknown,
        started_at: None,
    });
    r.set_unseen("k1", true);
    let ev = r.events().events_after(0).pop().unwrap();
    assert_eq!(
        ev,
        json!({"type": "pane.unseen_changed", "seq": 1, "pane_id": "p1",
               "pane_session_key": "k1", "worktree_path": "/a", "unseen": true})
    );
    assert_eq!(r.pane_json("k1").unwrap()["unseen"], true);
}

/// The outcome-side clear, and the two ways a client says it looked.
#[test]
fn seeing_clears_it() {
    let mut r = Registry::new();
    register(&mut r, "a", "/wt");
    register(&mut r, "b", "/wt");
    r.set_unseen("a", true);
    r.set_unseen("b", true);
    assert_eq!(
        r.mark_worktree_seen("/wt"),
        vec!["a".to_string(), "b".to_string()]
    );
    r.set_unseen("a", true);
    assert!(r.mark_pane_seen("a"));
    assert!(!r.mark_pane_seen("a"));
    r.set_unseen("a", true);
    let o = scan(&mut r, "a", Running, AgentType::Unknown, T0).unwrap();
    assert!(r.settle_unseen(&o));
    assert!(!r.pane("a").unwrap().unseen_completion);
}

#[test]
fn events_after_replays_buffered_tail() {
    let mut hub = EventHub::new();
    for i in 1..=5u64 {
        hub.publish(i, json!({"type": "x", "seq": i}));
    }
    let after: Vec<u64> = hub
        .events_after(3)
        .iter()
        .map(|e| e["seq"].as_u64().unwrap())
        .collect();
    assert_eq!(after, vec![4, 5]);
    assert_eq!(hub.current_seq(), 5);
}

#[test]
fn subscriber_receives_published_events() {
    let mut hub = EventHub::new();
    hub.publish(1, json!({"type": "pane.updated", "pane_id": "t1"}));
    let got = hub.events_after(0);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0]["pane_id"], "t1");
    assert!(hub.events_after(1).is_empty());
}

#[test]
fn ring_keeps_the_newest_five_hundred() {
    let mut hub = EventHub::new();
    for i in 1..=(RING_CAPACITY as u64 + 20) {
        hub.publish(i, json!({"seq": i}));
    }
    assert_eq!(hub.len(), RING_CAPACITY);
    assert_eq!(hub.events_after(0)[0]["seq"], 21);
    assert_eq!(hub.current_seq(), RING_CAPACITY as u64 + 20);
}

/// The event shapes, field for field, as `AgentRegistry` published them.
#[test]
fn registry_events_match_the_swift_shapes() {
    let mut r = Registry::new();
    register(&mut r, "s", "/wt");
    let o = hook(
        &mut r,
        "s",
        prompt("<pasted_content id=\"1\">\nfix it\n</pasted_content id=\"1\">"),
        T0,
    )
    .unwrap();
    let mut ev = o.to_event();
    // The whole pane rides along, so one event redraws a row.
    let info = ev.as_object_mut().unwrap().remove("info").unwrap();
    let event = ev.as_object_mut().unwrap().remove("event").unwrap();
    // The event the core decided on, in core-types' serde shape: what a
    // client hands its own consumers.
    assert_eq!(event["source"], json!({"type": "hook", "name": "claude-code"}));
    assert_eq!(event["kind"]["kind"], "user_prompt");
    assert_eq!(info["status"], "Unknown");
    assert_eq!(info["last_user_prompt"], "<pasted_content id=\"1\">\nfix it\n</pasted_content id=\"1\">");
    assert_eq!(info["hook_status"], "Running");
    assert_eq!(info["tasks"], json!([]));
    assert_eq!(info["unseen"], false);
    assert_eq!(
        ev,
        json!({"type": "pane.updated", "seq": 1, "pane_id": "s", "pane_session_key": "s",
               "status": "Unknown", "old_status": "Unknown", "agent_type": "unknown",
               "worktree_path": "/wt", "last_message": "", "user_prompt": "fix it"})
    );
    let o = hook(&mut r, "s", question("which?", &["a", "b"]), T0 + 1.0).unwrap();
    let ev = o.to_event();
    assert_eq!(ev["event"]["kind"]["kind"], "question");
    assert_eq!(ev["event"]["kind"]["flags"]["multi_select"], false);
    assert_eq!(ev["type"], "pane.status_changed");
    assert_eq!(ev["status"], "Waiting");
    assert_eq!(
        ev["question"],
        json!({"prompt": "which?", "options": ["a", "b"]})
    );
    r.note_assistant_message(Some("s"), "/wt", "Here is why.", T0 + 2.0);
    let o = hook(
        &mut r,
        "s",
        EventKind::Suggest {
            options: vec!["ship".into()],
        },
        T0 + 2.0,
    )
    .unwrap();
    assert_eq!(
        o.to_event()["suggest"],
        json!({"options": ["ship"], "message": "Here is why."})
    );
    assert!(o.to_event().get("is_completion").is_none());
    r.unregister("s");
    let all = r.events().events_after(0);
    assert_eq!(all.len(), 4, "every outcome and the close went to the hub");
    assert_eq!(
        all[3],
        json!({"type": "pane.closed", "seq": 4, "pane_id": "s", "pane_session_key": "s", "worktree_path": "/wt"})
    );
    // Dropped scan frames still take a seq, as in the Swift.
    let _ = ingest(
        &mut r,
        "gone",
        EventSource::Scan,
        screen(Idle, AgentType::Unknown),
        T0,
    );
    assert_eq!(r.seq(), 5);
}

#[test]
fn machine_prompts_are_not_shown() {
    assert_eq!(
        human_prompt_text("<task-notification>x</task-notification>"),
        None
    );
    assert_eq!(human_prompt_text("   "), None);
    assert_eq!(
        human_prompt_text("see <task-notification>x</task-notification>").as_deref(),
        Some("see <task-notification>x</task-notification>")
    );
    assert_eq!(
        human_prompt_text("a\n<pasted_content id=\"2\">\n\n\nb\n</pasted_content id=\"2\">")
            .as_deref(),
        Some("a\n\nb")
    );
}
