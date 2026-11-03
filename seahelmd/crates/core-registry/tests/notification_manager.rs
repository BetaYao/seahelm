//! Port of the decision parts of Tests/NotificationManagerTests.swift. The
//! formatting tests (titles, bodies, subtitles) are not ported: formatting
//! is the delivering client's job, and the core emits decisions.
//! Also covers `TabCoordinator`'s completion decision (`completion_step`).

mod common;

use common::*;
use seahelm_core_registry::notify::*;
use seahelm_core_registry::Registry;
use seahelm_core_types::{
    AgentStatus::*, AgentType, EventKind, EventSource, ProgramState, ProgramStatus,
};

fn request(
    pane: &str,
    old: seahelm_core_types::AgentStatus,
    new: seahelm_core_types::AgentStatus,
) -> NotifyRequest {
    NotifyRequest {
        worktree_path: "/wt".into(),
        pane: pane.into(),
        pane_index: 1,
        pane_count: 1,
        old_status: old,
        new_status: new,
        last_message: String::new(),
        last_user_prompt: String::new(),
        last_assistant_message: String::new(),
        last_assistant_message_at: None,
        last_user_prompt_at: None,
        is_target_visible: false,
        source: Source::Scan,
        agent_reported_end: false,
    }
}

#[test]
fn should_notify_only_fires_on_running_to_terminal_edge() {
    let m = NotificationPolicy::new();
    assert!(m.should_notify("k1", Running, Idle, Source::Scan, "", T0));
    assert!(m.should_notify("k1", Running, Waiting, Source::Scan, "", T0));
    assert!(m.should_notify("k1", Running, Error, Source::Scan, "", T0));
    assert!(!m.should_notify("k1", Idle, Waiting, Source::Scan, "", T0));
    assert!(!m.should_notify("k1", Running, Running, Source::Scan, "", T0));
}

#[test]
fn should_deliver_pending_holds_only_when_status_unchanged() {
    assert!(should_deliver_pending(Idle, Some(Idle)));
    assert!(!should_deliver_pending(Idle, Some(Running)));
    assert!(!should_deliver_pending(Idle, Some(Waiting)));
    assert!(!should_deliver_pending(Idle, None));
}

#[test]
fn banner_fires_when_app_is_in_background_even_with_a_card_on_screen() {
    assert!(!should_suppress_banner(false, true, true));
}

#[test]
fn banner_suppressed_when_island_card_is_expanded_frontmost() {
    assert!(should_suppress_banner(true, false, true));
}

#[test]
fn banner_suppressed_when_looking_at_the_pane() {
    assert!(should_suppress_banner(true, true, false));
}

#[test]
fn banner_fires_for_another_worktree_with_no_card_shown() {
    assert!(!should_suppress_banner(true, false, false));
}

fn gate(source: Source, last: Option<Source>, elapsed: f64, turn: &str, last_turn: &str) -> bool {
    let previous = last.map(|s| Delivery {
        at: T0 - elapsed,
        source: s,
        turn: last_turn.into(),
    });
    should_notify(Running, Idle, source, turn, previous.as_ref(), 30.0, T0)
}

fn gate_ab(source: Source, last: Option<Source>, elapsed: f64) -> bool {
    gate(source, last, elapsed, "turn-a", "turn-b")
}

#[test]
fn cooldown_suppresses_a_second_scan_banner() {
    assert!(!gate_ab(Source::Scan, Some(Source::Scan), 5.0));
}

#[test]
fn agent_reported_completion_overrides_a_warm_scan_banner() {
    assert!(gate_ab(Source::Agent, Some(Source::Scan), 5.0));
}

#[test]
fn second_agent_reported_completion_is_still_suppressed() {
    assert!(!gate_ab(Source::Agent, Some(Source::Agent), 5.0));
}

#[test]
fn scan_banner_never_overrides_an_agent_reported_one() {
    assert!(!gate_ab(Source::Scan, Some(Source::Agent), 5.0));
}

#[test]
fn past_the_cooldown_either_source_fires() {
    assert!(gate_ab(Source::Scan, Some(Source::Agent), 31.0));
    assert!(gate_ab(Source::Agent, Some(Source::Agent), 31.0));
}

#[test]
fn first_ever_edge_fires() {
    assert!(gate_ab(Source::Scan, None, 0.0));
}

#[test]
fn the_same_turn_is_never_announced_twice() {
    assert!(!gate(
        Source::Scan,
        Some(Source::Agent),
        300.0,
        "same",
        "same"
    ));
}

#[test]
fn a_new_turn_past_the_cooldown_still_fires() {
    assert!(gate(
        Source::Scan,
        Some(Source::Agent),
        300.0,
        "second answer",
        "first answer"
    ));
}

#[test]
fn the_override_does_not_resurrect_an_already_announced_turn() {
    assert!(!gate(
        Source::Agent,
        Some(Source::Scan),
        5.0,
        "same",
        "same"
    ));
}

#[test]
fn an_unidentified_turn_never_matches() {
    assert!(gate(Source::Scan, Some(Source::Agent), 300.0, "", ""));
}

#[test]
fn fingerprint_prefers_the_agents_own_prose() {
    let f = turn_fingerprint(Idle, "shipped it", "npm test", "ship");
    assert!(f.contains("shipped it"));
    assert!(
        !f.contains("npm test"),
        "the scanned command line is the weaker signal"
    );
}

#[test]
fn same_pose_to_a_different_prompt_is_a_different_turn() {
    let a = turn_fingerprint(Idle, "Done.", "", "fix the test");
    let b = turn_fingerprint(Idle, "Done.", "", "now ship it");
    assert_ne!(a, b);
}

#[test]
fn empty_payload_yields_no_fingerprint() {
    assert_eq!(turn_fingerprint(Idle, "  ", "", "x"), "");
}

fn answers(prose: &str, assistant: Option<f64>, prompt: Option<f64>) -> bool {
    answers_current_prompt(prose, assistant.map(|a| T0 + a), prompt.map(|p| T0 + p))
}

const PROSE: &str = "Hi! Ready when you are.";

#[test]
fn prose_written_after_the_prompt_is_the_answer_to_it() {
    assert!(answers(PROSE, Some(3.0), Some(0.0)));
}

#[test]
fn prose_older_than_the_prompt_is_not_announced() {
    assert!(!answers(PROSE, Some(3.0), Some(30.0)));
}

#[test]
fn a_pane_with_no_prose_is_never_held() {
    assert!(answers("", None, Some(30.0)));
    assert!(answers("   ", Some(3.0), Some(30.0)));
}

#[test]
fn missing_timestamps_do_not_block() {
    assert!(answers(PROSE, None, Some(30.0)));
    assert!(answers(PROSE, Some(3.0), None));
}

#[test]
fn agent_reported_end_skips_the_stability_gate() {
    assert!(uses_stability_gate(1.0, "t", false));
    assert!(!uses_stability_gate(1.0, "t", true));
    assert!(!uses_stability_gate(1.0, "", false));
    assert!(!uses_stability_gate(0.0, "t", false));
}

// Beyond the Swift suite: the stateful policy without the Timer.

#[test]
fn a_scan_edge_is_held_then_delivered_if_it_holds() {
    let mut p = NotificationPolicy::new();
    let d = p.notify(request("t", Running, Idle), T0);
    assert_eq!(
        d,
        Decision::Hold {
            key: "tid:t".into(),
            until: T0 + 1.0
        }
    );
    assert_eq!(p.next_deadline(), Some(T0 + 1.0));
    assert!(p.due(T0 + 0.5).is_empty());
    let out = p.due(T0 + 1.0);
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].key, "tid:t");
    // The cooldown was consumed by the delivery.
    assert_eq!(
        p.notify(request("t", Running, Idle), T0 + 5.0),
        Decision::Drop,
        "inside the cooldown"
    );
}

/// A flicker: the agent went back to running before the gate ended.
#[test]
fn a_held_edge_is_dropped_when_the_agent_moves_on() {
    let mut p = NotificationPolicy::new();
    p.notify(request("t", Running, Idle), T0);
    assert_eq!(
        p.notify(request("t", Idle, Running), T0 + 0.5),
        Decision::Drop
    );
    assert!(p.due(T0 + 2.0).is_empty());
    // Not delivered, so the cooldown is not burned.
    assert!(p.should_notify("tid:t", Running, Idle, Source::Scan, "", T0 + 3.0));
}

#[test]
fn an_agent_reported_end_is_delivered_at_once() {
    let mut p = NotificationPolicy::new();
    let mut req = request("t", Running, Idle);
    req.agent_reported_end = true;
    req.source = Source::Agent;
    req.last_assistant_message = "done".into();
    match p.notify(req, T0) {
        Decision::Deliver(n) => {
            assert_eq!(n.key, "tid:t");
            assert_eq!(n.turn, "Idle||done");
        }
        other => panic!("{other:?}"),
    }
    // Same turn again, even past the cooldown: never twice.
    let mut again = request("t", Running, Idle);
    again.last_assistant_message = "done".into();
    assert_eq!(p.notify(again, T0 + 100.0), Decision::Drop);
}

#[test]
fn a_worktree_level_notice_is_never_gated() {
    let mut p = NotificationPolicy::new();
    assert!(
        matches!(p.notify(request("", Running, Error), T0), Decision::Deliver(n) if n.key == "wt:/wt")
    );
}

#[test]
fn prose_older_than_the_prompt_drops_the_notice() {
    let mut p = NotificationPolicy::new();
    let mut req = request("t", Running, Idle);
    req.last_assistant_message = PROSE.into();
    req.last_assistant_message_at = Some(T0);
    req.last_user_prompt_at = Some(T0 + 10.0);
    assert_eq!(p.notify(req, T0 + 11.0), Decision::Drop);
}

// TabCoordinator's completion decision.

fn pane_after(
    r: &mut Registry,
    kinds: Vec<(EventSource, EventKind)>,
) -> seahelm_core_registry::PaneInfo {
    register(r, "p", "/wt");
    for (i, (s, k)) in kinds.into_iter().enumerate() {
        ingest(r, "p", s, k, T0 + i as f64);
    }
    r.pane("p").unwrap().clone()
}

fn input<'a>(
    pane: Option<&'a seahelm_core_registry::PaneInfo>,
    old: seahelm_core_types::AgentStatus,
    new: seahelm_core_types::AgentStatus,
) -> CompletionInput<'a> {
    CompletionInput {
        pane,
        old_status: old,
        new_status: new,
        agent_reported_end: false,
        attempts_left: PROSE_ATTEMPTS,
        worktree_on_screen: false,
        has_pending_card: false,
        completion_signals: 0,
    }
}

/// The screen reads idle while the hooks still have the turn open: wait for
/// the agent's own Stop, which carries the answer.
#[test]
fn an_idle_the_hooks_dispute_is_held() {
    let mut r = Registry::new();
    let p = pane_after(
        &mut r,
        vec![(EventSource::Hook("claude-code".into()), prompt("go"))],
    );
    assert!(should_wait_for_completion(Idle, p.hook_status));
    let step = completion_step(&input(Some(&p), Running, Idle));
    assert_eq!(
        step,
        CompletionStep::Retry {
            after: PROSE_RETRY_INTERVAL,
            attempts_left: PROSE_ATTEMPTS - 1,
            signals_seen: 0
        }
    );
    // Out of attempts: go ahead with what there is.
    let mut last = input(Some(&p), Running, Idle);
    last.attempts_left = 0;
    assert_eq!(
        completion_step(&last),
        CompletionStep::Proceed {
            mark_unseen: true,
            source: Source::Scan
        }
    );
    // Retrying is pointless once the pane works again or the agent said it finished.
    assert!(retry_proceeds(Some(Idle), 0, 0));
    assert!(!retry_proceeds(Some(Running), 0, 0));
    assert!(!retry_proceeds(Some(Idle), 0, 1));
    assert!(retry_proceeds(None, 2, 2));
}

#[test]
fn a_pane_without_hooks_is_never_held() {
    let mut r = Registry::new();
    let p = pane_after(
        &mut r,
        vec![(EventSource::Scan, screen(Running, AgentType::Unknown))],
    );
    assert_eq!(
        completion_step(&input(Some(&p), Running, Idle)),
        CompletionStep::Proceed {
            mark_unseen: true,
            source: Source::Scan
        }
    );
}

/// 7501 `idle` is at rest (just launched, interrupted), not finished.
#[test]
fn an_at_rest_program_idle_is_not_a_completion() {
    let rec = ProgramStatus {
        state: ProgramState::Idle,
        kind: None,
        progress: None,
        app: "claude-code".into(),
        title: String::new(),
        msg: String::new(),
    };
    let mut r = Registry::new();
    let p = pane_after(
        &mut r,
        vec![(
            EventSource::Osc7501,
            EventKind::ProgramStatus { record: Some(rec) },
        )],
    );
    assert!(program_says_at_rest(Idle, p.program_state));
    assert_eq!(
        completion_step(&input(Some(&p), Running, Idle)),
        CompletionStep::Ignore
    );
}

/// The agent's own Stop: proceeds as agent-reported, marked unseen only
/// when nobody is looking.
#[test]
fn an_agent_completion_proceeds_and_marks_unseen_off_screen() {
    let mut r = Registry::new();
    let p = pane_after(
        &mut r,
        vec![
            (EventSource::Scan, screen(Running, AgentType::ClaudeCode)),
            (EventSource::Hook("claude-code".into()), stop(true)),
        ],
    );
    let mut i = input(Some(&p), Running, Idle);
    i.agent_reported_end = true;
    assert_eq!(
        completion_step(&i),
        CompletionStep::Proceed {
            mark_unseen: true,
            source: Source::Agent
        }
    );
    i.worktree_on_screen = true;
    assert_eq!(
        completion_step(&i),
        CompletionStep::Proceed {
            mark_unseen: false,
            source: Source::Agent
        }
    );
    let req = NotifyRequest::for_pane(&p, Running, Idle, &p.last_message, 1, 1, false, true);
    assert_eq!(req.source, Source::Agent);
    assert!(matches!(
        NotificationPolicy::new().notify(req, T0),
        Decision::Deliver(_)
    ));
}

#[test]
fn a_waiting_edge_with_a_card_up_is_not_announced() {
    let mut r = Registry::new();
    let p = pane_after(
        &mut r,
        vec![(EventSource::Scan, screen(Running, AgentType::ClaudeCode))],
    );
    let mut i = input(Some(&p), Running, Waiting);
    i.has_pending_card = true;
    assert_eq!(completion_step(&i), CompletionStep::Ignore);
    i.has_pending_card = false;
    assert_eq!(
        completion_step(&i),
        CompletionStep::Proceed {
            mark_unseen: false,
            source: Source::Scan
        }
    );
}

#[test]
fn completion_signals_count_completions() {
    let mut r = Registry::new();
    register(&mut r, "p", "/wt");
    let mut signals = CompletionSignals::new();
    let o = hook(&mut r, "p", prompt("go"), T0).unwrap();
    assert!(!signals.note(&o));
    let o = hook(&mut r, "p", stop(true), T0 + 1.0).unwrap();
    assert!(signals.note(&o));
    assert_eq!(signals.count("p"), 1);
    assert_eq!(signals.count("other"), 0);
}
