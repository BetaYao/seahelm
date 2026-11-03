//! Port of Tests/AgentRegistryIngestTests.swift and
//! Tests/AgentRegistryTransitionTests.swift.

mod common;

use common::*;
use seahelm_core_registry::Registry;
use seahelm_core_types::{AgentStatus::*, AgentType, EventSource};

#[test]
fn ingest_updates_status() {
    let mut r = Registry::new();
    register(&mut r, "t-ingest-1", "/tmp/ingest-test");
    ingest(
        &mut r,
        "t-ingest-1",
        EventSource::Scan,
        screen_full(Waiting, "need input", AgentType::Unknown, 0.0, vec![]),
        T0,
    );
    assert_eq!(status(&r, "t-ingest-1"), Waiting);
}

#[test]
fn ingest_updates_last_message() {
    let mut r = Registry::new();
    register(&mut r, "t-ingest-2", "/tmp/ingest-test2");
    ingest(
        &mut r,
        "t-ingest-2",
        EventSource::Scan,
        screen_full(Running, "doing stuff", AgentType::Unknown, 0.0, vec![]),
        T0,
    );
    assert_eq!(r.pane("t-ingest-2").unwrap().last_message, "doing stuff");
}

#[test]
fn ingest_for_unknown_terminal_is_noop() {
    let mut r = Registry::new();
    let o = ingest(
        &mut r,
        "t-nonexistent-99",
        EventSource::Scan,
        screen_full(Waiting, "hello", AgentType::Unknown, 0.0, vec![]),
        T0,
    );
    assert!(o.is_none());
    assert!(r.pane("t-nonexistent-99").is_none());
}

#[test]
fn ingest_last_user_prompt() {
    let mut r = Registry::new();
    register(&mut r, "t-ingest-3", "/tmp/ingest-test3");
    hook(&mut r, "t-ingest-3", prompt("user asked something"), T0);
    assert_eq!(
        r.pane("t-ingest-3").unwrap().last_user_prompt,
        "user asked something"
    );
}

#[test]
fn status_change_fires_outcome_observer() {
    let mut r = Registry::new();
    register_full(&mut r, "tt", "/wt/z", "feat-z", "repoz", None);
    let o = ingest(
        &mut r,
        "tt",
        EventSource::Scan,
        screen_full(Waiting, "?", AgentType::Unknown, 0.0, vec![]),
        T0,
    )
    .unwrap();
    assert!(o.status_changed);
    assert_eq!(o.new_status, Waiting);
    assert_eq!(o.info.worktree_path, "/wt/z");
    assert!(!o.is_completion_signal);
}

// Beyond the Swift suite: the rules the Swift pinned only in comments.

/// A scan that changed nothing a client renders is dropped; a hook never is.
#[test]
fn unchanged_scan_frames_are_dropped() {
    let mut r = Registry::new();
    register(&mut r, "p", "/wt");
    assert!(scan(&mut r, "p", Running, AgentType::ClaudeCode, T0).is_some());
    assert!(scan(&mut r, "p", Running, AgentType::ClaudeCode, T0 + 2.0).is_none());
    // round_duration ticking alone is not a visible change.
    let o = ingest(
        &mut r,
        "p",
        EventSource::Scan,
        screen_full(Running, "", AgentType::ClaudeCode, 9.0, vec![]),
        T0 + 4.0,
    );
    assert!(o.is_none());
    assert_eq!(
        r.pane("p").unwrap().round_duration,
        9.0,
        "but it is still recorded"
    );
    assert!(hook(&mut r, "p", tool("Bash", "ls", false, T0 + 5.0), T0 + 5.0).is_some());
}

#[test]
fn hold_seconds_is_the_time_spent_in_the_old_status() {
    let mut r = Registry::new();
    register(&mut r, "p", "/wt");
    let first = scan(&mut r, "p", Running, AgentType::ClaudeCode, T0).unwrap();
    assert_eq!(first.hold_seconds, 0.0);
    let second = scan(&mut r, "p", Waiting, AgentType::ClaudeCode, T0 + 7.0).unwrap();
    assert_eq!(second.hold_seconds, 7.0);
}

/// OSC 7501 decides above everything, and `done` after `working` completes a
/// turn only on a pane without hooks.
#[test]
fn program_status_decides_and_completes_without_hooks() {
    use seahelm_core_types::{EventKind, ProgramState, ProgramStatus};
    let rec = |state| ProgramStatus {
        state,
        kind: None,
        progress: None,
        app: "claude-code".into(),
        title: String::new(),
        msg: String::new(),
    };
    let mut r = Registry::new();
    register(&mut r, "p", "/wt");
    scan(&mut r, "p", Idle, AgentType::ClaudeCode, T0);
    let o = ingest(
        &mut r,
        "p",
        EventSource::Osc7501,
        EventKind::ProgramStatus {
            record: Some(rec(ProgramState::Working)),
        },
        T0 + 1.0,
    )
    .unwrap();
    assert_eq!(o.new_status, Running);
    let o = ingest(
        &mut r,
        "p",
        EventSource::Osc7501,
        EventKind::ProgramStatus {
            record: Some(rec(ProgramState::Done)),
        },
        T0 + 2.0,
    )
    .unwrap();
    assert_eq!(o.new_status, Idle);
    assert!(o.is_completion_signal);

    // With hooks, the Stop is the completion; 7501 must not double it.
    ingest(
        &mut r,
        "p",
        EventSource::Osc7501,
        EventKind::ProgramStatus {
            record: Some(rec(ProgramState::Working)),
        },
        T0 + 3.0,
    );
    hook(&mut r, "p", prompt("go"), T0 + 3.5);
    let o = ingest(
        &mut r,
        "p",
        EventSource::Osc7501,
        EventKind::ProgramStatus {
            record: Some(rec(ProgramState::Done)),
        },
        T0 + 4.0,
    )
    .unwrap();
    assert!(!o.is_completion_signal);

    let x = r.explain("p", authority_of(AgentType::ClaudeCode), T0 + 4.0);
    assert_eq!(x["decided_by"], "osc7501");
    assert_eq!(x["program_status_live"], true);
    assert_eq!(x["program_status"][0]["state"], "done");
    let o = ingest(
        &mut r,
        "p",
        EventSource::Osc7501,
        EventKind::ProgramStatus { record: None },
        T0 + 5.0,
    )
    .unwrap();
    assert_eq!(o.info.program_status, Unknown);
    assert_eq!(
        r.explain("p", authority_of(AgentType::ClaudeCode), T0 + 5.0)["program_status_live"],
        false
    );
}

#[test]
fn explain_reports_the_trailing_edge_window() {
    let mut r = Registry::new();
    register(&mut r, "p", "/wt");
    scan(&mut r, "p", Running, AgentType::ClaudeCode, T0);
    hook(&mut r, "p", stop(true), T0 + 1.0);
    let a = authority_of(AgentType::ClaudeCode);
    let x = r.explain("p", a, T0 + 2.0);
    assert_eq!(x["status"], "Idle");
    assert_eq!(x["decided_by"], "hook");
    assert_eq!(x["hook_idle_fresh"], true);
    assert_eq!(x["authority"], "session_only");
    let x = r.explain("p", a, T0 + 5.0);
    assert_eq!(x["status"], "Running");
    assert_eq!(x["decided_by"], "screen");
    assert_eq!(x["hook_idle_fresh"], false);
    assert!(r.explain("nobody", a, T0).is_null());
}
