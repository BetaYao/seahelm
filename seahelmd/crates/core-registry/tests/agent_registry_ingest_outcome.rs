//! Port of Tests/AgentRegistryIngestOutcomeTests.swift. Not ported:
//! `testCursorManifestIsNotScreenOnly` and
//! `testObservedStatusIsWaitingOnlyWhileAnApprovalShows` test the manifest
//! store and `StatusPublisher.observedStatus`, which live in the scan crate.

mod common;

use common::*;
use seahelm_core_registry::{arbitrate, Outcome, Registry};
use seahelm_core_types::{
    AgentStatus::*, AgentType, Authority, EventSource, TaskItem, TaskItemStatus,
};

fn setup() -> Registry {
    let mut r = Registry::new();
    register(&mut r, "t1", "/wt");
    r
}

#[test]
fn cursor_hook_running_promotes_over_scan_idle() {
    assert_eq!(
        arbitrate(
            Idle,
            Running,
            authority_of(AgentType::Cursor),
            false,
            Unknown
        ),
        Running
    );
}

/// The trailing edge still belongs to the screen: once the scan has seen a
/// sustained idle past the grace window, a stale hook `Running` is dropped.
#[test]
fn cursor_scan_idle_reclaims_stale_hook_running_after_grace() {
    let mut r = setup();
    r.graces.hook_running = 0.0;
    ingest(
        &mut r,
        "t1",
        EventSource::Hook("cursor".into()),
        prompt("do the thing"),
        T0,
    );
    scan(&mut r, "t1", Running, AgentType::Cursor, T0 + 1.0);
    scan(&mut r, "t1", Idle, AgentType::Cursor, T0 + 2.0);
    assert_eq!(status(&r, "t1"), Idle);
}

#[test]
fn session_only_hook_running_promotes_over_stale_scan_idle() {
    let mut r = setup();
    let mut outcomes: Vec<Outcome> = Vec::new();
    outcomes.extend(hook(&mut r, "t1", prompt("do the thing"), T0));
    outcomes.extend(scan(&mut r, "t1", Idle, AgentType::ClaudeCode, T0 + 0.5));
    assert_eq!(outcomes.len(), 2);
    assert_eq!(outcomes[1].new_status, Running);
}

#[test]
fn stale_hook_running_reclaimed_by_scan_idle_after_grace() {
    let mut r = setup();
    r.graces.hook_running = 0.0;
    hook(&mut r, "t1", prompt("do the thing"), T0);
    scan(&mut r, "t1", Running, AgentType::ClaudeCode, T0 + 1.0);
    scan(&mut r, "t1", Idle, AgentType::ClaudeCode, T0 + 2.0);
    assert_eq!(status(&r, "t1"), Idle);
}

/// A new turn polled before its spinner reached the screen: the frame still
/// shows the last turn's prompt, past the 3 s window. That is not the run
/// ending.
#[test]
fn scan_idle_before_the_run_reaches_the_screen_does_not_end_it() {
    let mut r = setup();
    r.graces.hook_running = 0.0;
    scan(&mut r, "t1", Running, AgentType::ClaudeCode, T0); // the previous turn
    scan(&mut r, "t1", Idle, AgentType::ClaudeCode, T0 + 1.0);
    hook(&mut r, "t1", prompt("next"), T0 + 2.0);
    scan(&mut r, "t1", Idle, AgentType::ClaudeCode, T0 + 6.0);
    assert_eq!(status(&r, "t1"), Running);
    scan(&mut r, "t1", Running, AgentType::ClaudeCode, T0 + 8.0);
    scan(&mut r, "t1", Idle, AgentType::ClaudeCode, T0 + 10.0); // shown the run, and stopped
    assert_eq!(status(&r, "t1"), Idle);
}

/// A turn that died before drawing anything still comes back, just later.
#[test]
fn run_the_screen_never_showed_is_reclaimed_after_the_longer_window() {
    let mut r = setup();
    hook(&mut r, "t1", prompt("do the thing"), T0);
    scan(&mut r, "t1", Idle, AgentType::ClaudeCode, T0 + 14.0);
    assert_eq!(status(&r, "t1"), Running, "inside the 15 s window");
    scan(&mut r, "t1", Idle, AgentType::ClaudeCode, T0 + 15.0);
    assert_eq!(status(&r, "t1"), Idle);
}

#[test]
fn urgent_hook_surfaces_even_when_screen_authoritative() {
    let mut r = setup();
    let first = scan(&mut r, "t1", Idle, AgentType::ClaudeCode, T0);
    let second = hook(
        &mut r,
        "t1",
        seahelm_core_types::EventKind::AwaitingInput {
            text: "approve?".into(),
        },
        T0 + 1.0,
    );
    assert!(first.is_some());
    assert_eq!(second.unwrap().new_status, Waiting);
}

/// AskUserQuestion sets hook `Waiting`; the user answers in the pane and the
/// agent works for minutes. A scan that positively sees it working must
/// reclaim the stale question, or one undelivered hook strands the card.
#[test]
fn stale_hook_waiting_reclaimed_by_scan_running_after_grace() {
    let mut r = setup();
    r.graces.hook_waiting = 0.0;
    hook(&mut r, "t1", question("which repo?", &["a", "b"]), T0);
    let o = scan(&mut r, "t1", Running, AgentType::ClaudeCode, T0 + 0.5).unwrap();
    assert_eq!(o.new_status, Running);
}

/// The pre-question frame can still show the spinner; inside the window it
/// must not clear the question.
#[test]
fn hook_waiting_holds_against_scan_running_within_grace() {
    let mut r = setup();
    hook(&mut r, "t1", question("which repo?", &["a", "b"]), T0);
    let o = scan(&mut r, "t1", Running, AgentType::ClaudeCode, T0 + 1.0).unwrap();
    assert_eq!(o.new_status, Waiting);
}

#[test]
fn hook_waiting_cleared_by_next_tool_use() {
    let mut r = setup();
    scan(&mut r, "t1", Running, AgentType::ClaudeCode, T0);
    hook(&mut r, "t1", question("which repo?", &["a", "b"]), T0 + 1.0);
    let o = hook(
        &mut r,
        "t1",
        tool("Bash", "grep", false, T0 + 2.0),
        T0 + 2.0,
    )
    .unwrap();
    assert_eq!(o.new_status, Running);
}

#[test]
fn screen_observed_carries_round_duration_and_tasks() {
    let mut r = setup();
    let task = TaskItem {
        id: "t-1".into(),
        subject: "Write tests".into(),
        status: TaskItemStatus::InProgress,
    };
    let o = ingest(
        &mut r,
        "t1",
        EventSource::Scan,
        screen_full(Running, "", AgentType::ClaudeCode, 42.5, vec![task]),
        T0,
    )
    .unwrap();
    assert_eq!(o.info.round_duration, 42.5);
    assert_eq!(o.info.tasks.len(), 1);
    assert_eq!(o.info.tasks[0].id, "t-1");
}

#[test]
fn agent_stopped_failure_is_completion_with_error() {
    let mut r = setup();
    let o = hook(&mut r, "t1", stop(false), T0).unwrap();
    assert!(o.is_completion_signal);
    assert_eq!(o.new_status, Error);
}

#[test]
fn fresh_hook_idle_promotes_over_scan_running() {
    assert_eq!(
        arbitrate(Running, Idle, Authority::SessionOnly, true, Unknown),
        Idle
    );
}

#[test]
fn stale_hook_idle_leaves_authority_with_the_screen() {
    assert_eq!(
        arbitrate(Running, Idle, Authority::SessionOnly, false, Unknown),
        Running
    );
}

#[test]
fn fresh_hook_idle_never_outranks_an_urgent_screen() {
    assert_eq!(
        arbitrate(Waiting, Idle, Authority::SessionOnly, true, Unknown),
        Waiting
    );
}

/// The completion this path exists for: a Stop while the scan still reports
/// running must produce a Running → Idle outcome to notify on.
#[test]
fn stop_while_screen_still_running_yields_idle_outcome() {
    let mut r = setup();
    hook(&mut r, "t1", prompt("do the thing"), T0);
    scan(&mut r, "t1", Running, AgentType::ClaudeCode, T0 + 1.0);
    let o = hook(&mut r, "t1", stop(true), T0 + 2.0).unwrap();
    assert_eq!(o.new_status, Idle);
    assert_eq!(
        o.old_status, Running,
        "and it is a running -> idle edge, which is what notifies"
    );
}

/// Once the idle window lapses, the next frame showing work takes the pane
/// back to running.
#[test]
fn screen_reclaims_running_once_the_idle_window_lapses() {
    let mut r = setup();
    scan(&mut r, "t1", Idle, AgentType::ClaudeCode, T0);
    hook(&mut r, "t1", stop(true), T0 + 1.0);
    let o = scan(&mut r, "t1", Running, AgentType::ClaudeCode, T0 + 4.0).unwrap();
    assert_eq!(o.new_status, Running);
}

/// One approval dialog polled the way the scanner polls it: the frame's
/// `ScreenObserved` (reported as waiting while the dialog shows), then the
/// dialog's scan `Question`. The pane must go Waiting once and stay there.
#[test]
fn approval_dialog_polls_do_not_flip_status() {
    let mut r = setup();
    let mut outcomes = Vec::new();
    outcomes.extend(hook(&mut r, "t1", prompt("migrate belayo"), T0));
    let mut now = T0;
    for _heuristic in [Running, Running, Idle, Idle, Idle] {
        now += 2.0;
        // `StatusPublisher.observedStatus(committed:, showsApproval: true)`.
        let observed = Waiting;
        outcomes.extend(scan(&mut r, "t1", observed, AgentType::ClaudeCode, now));
        outcomes.extend(ingest(
            &mut r,
            "t1",
            EventSource::Scan,
            question("Claude Code requires approval", &["1. Yes", "2. No"]),
            now,
        ));
    }
    let edges: Vec<String> = outcomes
        .iter()
        .filter(|o| o.status_changed)
        .map(|o| format!("{}→{}", o.old_status.as_str(), o.new_status.as_str()))
        .collect();
    assert_eq!(
        edges.iter().filter(|e| e.ends_with("→Waiting")).count(),
        1,
        "{edges:?}"
    );
    assert!(
        !edges.iter().any(|e| e.starts_with("Waiting→")),
        "{edges:?}"
    );
}

/// The bits of `DebouncedStatusTracker` and `StatusPublisher.idleObservation`
/// this test drives (both live in the scan crate).
struct Tracker {
    current: seahelm_core_types::AgentStatus,
    pending: u32,
}

impl Tracker {
    fn update(&mut self, s: seahelm_core_types::AgentStatus, visible_idle: bool, defaulted: bool) {
        if s == Unknown {
            return;
        }
        if self.current == Running && s == Idle && (defaulted || !visible_idle) {
            self.pending += 1;
            if self.pending < if defaulted { 6 } else { 2 } {
                return;
            }
        }
        self.pending = 0;
        self.current = s;
    }
}

/// A turn ending, polled the way the scanner polls it. The scan holds a
/// defaulted idle for six frames, longer than the hook's idle window; a pane
/// whose hooks said Stop must not bounce back to Running meanwhile.
#[test]
fn turn_end_does_not_bounce_back_to_running() {
    let mut r = setup();
    r.graces.hook_idle = 0.0; // the window, already lapsed
    let mut tracker = Tracker {
        current: Unknown,
        pending: 0,
    };
    let mut now = T0;
    let mut poll = |r: &mut Registry, state, visible_idle, defaulted| {
        now += 2.0;
        let hook_status = r.hook_status("t1");
        let (visible_idle, defaulted) = if hook_status == Idle {
            (true, false)
        } else {
            (visible_idle, defaulted)
        };
        tracker.update(state, visible_idle, defaulted);
        scan(r, "t1", tracker.current, AgentType::ClaudeCode, now);
        status(r, "t1")
    };
    hook(&mut r, "t1", prompt("ship it"), T0);
    assert_eq!(poll(&mut r, Running, false, false), Running);
    // Mid-turn, a frame with nothing on it is still held.
    assert_eq!(poll(&mut r, Idle, false, true), Running);
    hook(&mut r, "t1", stop(true), T0 + 5.0);
    let after: Vec<_> = (0..8).map(|_| poll(&mut r, Idle, false, true)).collect();
    assert_eq!(after, vec![Idle; 8]);
}

#[test]
fn turn_start_is_the_prompt_and_survives_an_approval() {
    let mut r = setup();
    assert_eq!(r.turn_started("t1"), None);
    hook(&mut r, "t1", prompt("ship it"), T0);
    assert_eq!(r.turn_started("t1"), Some(T0));
    hook(&mut r, "t1", question("Run it?", &["Yes", "No"]), T0 + 1.0);
    hook(&mut r, "t1", tool("Bash", "ls", false, T0 + 2.0), T0 + 2.0);
    assert_eq!(
        r.turn_started("t1"),
        Some(T0),
        "an approval inside the turn does not start a new one"
    );
    hook(&mut r, "t1", stop(true), T0 + 3.0);
    assert_eq!(r.turn_started("t1"), None);
}
