//! Port of Tests/AgentRegistryBackgroundBusyTests.swift and
//! Tests/AgentRegistryActivityEventTests.swift. Which webhook marks a
//! worktree busy (SubagentStart, a Stop's `background_tasks`) is the hooks
//! crate's `sink::background_busy`; the registry keeps the per-worktree flag.

mod common;

use common::*;
use seahelm_core_registry::pane::{append_to_ring_buffer, upsert_latest};
use seahelm_core_registry::Registry;

const WT: &str = "/wt-bg";

fn setup() -> Registry {
    let mut r = Registry::new();
    register(&mut r, "tbg", WT);
    r
}

#[test]
fn subagent_start_marks_busy() {
    let mut r = setup();
    assert!(!r.is_background_busy(WT));
    r.set_background_busy(WT, true); // SubagentStart
    assert!(r.is_background_busy(WT));
}

#[test]
fn stop_with_running_background_task_stays_busy() {
    let mut r = setup();
    r.set_background_busy(WT, true); // Stop with a running background task
    assert!(r.is_background_busy(WT));
}

#[test]
fn stop_with_no_running_background_clears_busy() {
    let mut r = setup();
    r.set_background_busy(WT, true);
    assert!(r.is_background_busy(WT));
    r.set_background_busy(WT, false); // SubagentStop, all tasks completed
    assert!(!r.is_background_busy(WT));
}

#[test]
fn cwd_inside_worktree_resolves() {
    let mut r = setup();
    r.set_background_busy(&format!("{WT}/sub/dir"), true);
    assert!(r.is_background_busy(&format!("{WT}/sub/dir")));
    assert!(r.is_background_busy(WT));
    r.set_background_busy("/unknown", true);
    assert!(!r.is_background_busy("/unknown"));
}

#[test]
fn append_activity_event_adds_to_front() {
    let mut events = Vec::new();
    append_to_ring_buffer(&mut events, activity("Read", "a.swift", false, T0), 20);
    append_to_ring_buffer(&mut events, activity("Edit", "b.swift", false, T0), 20);
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].tool, "Edit");
    assert_eq!(events[1].tool, "Read");
}

#[test]
fn ring_buffer_caps_at_max_size() {
    let mut events = Vec::new();
    for i in 0..25 {
        append_to_ring_buffer(
            &mut events,
            activity("Read", &format!("file{i}.swift"), false, T0),
            20,
        );
    }
    assert_eq!(events.len(), 20);
    assert_eq!(events[0].detail, "file24.swift");
}

#[test]
fn clear_activity_events_empties_buffer() {
    let mut r = setup();
    hook(&mut r, "tbg", tool("Read", "a.swift", false, T0), T0);
    assert_eq!(r.pane("tbg").unwrap().activity_events.len(), 1);
    hook(&mut r, "tbg", stop(true), T0 + 1.0); // a Stop clears the log
    assert!(r.pane("tbg").unwrap().activity_events.is_empty());
}

#[test]
fn upsert_latest_activity_event_replaces_matching_newest_event() {
    let mut r = setup();
    hook(&mut r, "tbg", tool("Bash", "swift test", false, T0), T0);
    hook(
        &mut r,
        "tbg",
        tool("Bash", "swift test", true, T0 + 1.0),
        T0 + 1.0,
    );
    let events = &r.pane("tbg").unwrap().activity_events;
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].tool, "Bash");
    assert!(events[0].is_error);

    let mut buf = Vec::new();
    upsert_latest(&mut buf, activity("A", "x", false, T0), 20);
    upsert_latest(&mut buf, activity("B", "x", false, T0), 20);
    assert_eq!(buf.len(), 2);
}

/// The log holds at most 20 tool calls through the hook path too.
#[test]
fn hook_activity_log_is_capped() {
    let mut r = setup();
    for i in 0..30 {
        hook(
            &mut r,
            "tbg",
            tool("Read", &format!("f{i}"), false, T0),
            T0 + i as f64,
        );
    }
    let events = &r.pane("tbg").unwrap().activity_events;
    assert_eq!(events.len(), 20);
    assert_eq!(events[0].detail, "f29");
}
