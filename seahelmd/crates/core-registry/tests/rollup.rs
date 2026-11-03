//! Port of Tests/PaneInfoDisplayStatusTests.swift, Tests/PaneStatusTests.swift
//! and Tests/WorktreeStatusAggregatorTests.swift. The Swift aggregator
//! reported through a delegate; `Aggregator::update` returns the same two
//! things (the pane edge and the changed rollup).

mod common;

use common::*;
use seahelm_core_registry::rollup::{
    grouping_status, Aggregator, PaneStatus, PaneUpdate, WorktreeStatus,
};
use seahelm_core_registry::Registry;
use seahelm_core_types::{AgentStatus, AgentStatus::*, AgentType};

// MARK: PaneInfoDisplayStatusTests

fn pane_with(status: AgentStatus, busy: bool) -> seahelm_core_registry::PaneInfo {
    let mut r = Registry::new();
    register(&mut r, "t1", "/wt");
    let mut p = r.pane("t1").unwrap().clone();
    p.agent_type = AgentType::ClaudeCode;
    p.status = status;
    p.background_busy = busy;
    p
}

#[test]
fn idle_with_background_work_still_draws_as_busy() {
    assert_eq!(
        pane_with(Idle, true).display_status(),
        Running,
        "a worktree watching CI is not done"
    );
}

#[test]
fn the_status_axis_itself_stays_honest() {
    assert_eq!(pane_with(Idle, true).status, Idle);
}

#[test]
fn idle_without_background_work_draws_as_idle() {
    assert_eq!(pane_with(Idle, false).display_status(), Idle);
}

#[test]
fn urgent_states_are_untouched() {
    assert_eq!(pane_with(Waiting, true).display_status(), Waiting);
    assert_eq!(pane_with(Error, true).display_status(), Error);
    assert_eq!(pane_with(Exited, true).display_status(), Exited);
}

fn ps(
    index: usize,
    id: &str,
    status: AgentStatus,
    message: &str,
    changed_at: f64,
    agent: AgentType,
) -> PaneStatus {
    PaneStatus {
        pane_index: index,
        pane: id.into(),
        status,
        last_message: message.into(),
        last_user_prompt: String::new(),
        last_updated: changed_at,
        status_changed_at: changed_at,
        agent_type: agent,
        background_busy: false,
    }
}

fn worktree(panes: Vec<PaneStatus>) -> WorktreeStatus {
    WorktreeStatus {
        worktree_path: "/repo/main".into(),
        panes,
        most_recent_pane_index: 1,
        most_recent_message: String::new(),
        most_recent_user_prompt: String::new(),
    }
}

#[test]
fn pane_status_mirrors_the_same_rule() {
    let mut p = ps(1, "t1", Idle, "", T0, AgentType::Unknown);
    p.background_busy = true;
    assert_eq!(p.display_status(), Running);
    assert_eq!(p.status, Idle);
}

#[test]
fn worktree_rollup_uses_display_status() {
    let mut p = ps(1, "t1", Idle, "", T0, AgentType::Unknown);
    p.background_busy = true;
    assert_eq!(worktree(vec![p]).rolled_up_status(), Running);
}

// MARK: PaneStatusTests

#[test]
fn statuses_follow_leaf_order() {
    let ws = worktree(vec![
        ps(1, "t1", Running, "", T0, AgentType::Unknown),
        ps(2, "t2", Idle, "", T0, AgentType::Unknown),
    ]);
    assert_eq!(ws.statuses(), vec![Running, Idle]);
}

#[test]
fn representative_is_the_most_recently_changed_pane() {
    let ws = worktree(vec![
        ps(1, "old", Waiting, "", T0, AgentType::Unknown),
        ps(2, "new", Running, "", T0 + 60.0, AgentType::Unknown),
    ]);
    assert_eq!(ws.representative().unwrap().pane_index, 2);
    assert_eq!(ws.rolled_up_status(), Running);
}

/// Recency, not priority: a shell that changed later outranks a waiting agent.
#[test]
fn a_busy_shell_can_now_outrank_a_waiting_agent() {
    let ws = worktree(vec![
        ps(1, "agent", Waiting, "", T0, AgentType::ClaudeCode),
        ps(2, "shell", Running, "", T0 + 1.0, AgentType::Npm),
    ]);
    assert_eq!(ws.rolled_up_status(), Running);
    assert_eq!(
        ws.grouping_status(),
        Waiting,
        "the grouping rule still ranks by priority"
    );
}

#[test]
fn status_and_message_come_from_the_same_pane() {
    let ws = worktree(vec![
        ps(1, "a", Idle, "idle msg", T0, AgentType::Unknown),
        ps(2, "b", Error, "boom", T0 + 5.0, AgentType::Unknown),
    ]);
    let rep = ws.representative().unwrap();
    assert_eq!(rep.status, Error);
    assert_eq!(rep.last_message, "boom");
}

#[test]
fn message_only_updates_do_not_steal_the_badge() {
    let mut chatty = ps(1, "chatty", Running, "line 900", T0, AgentType::Unknown);
    chatty.last_updated = T0 + 300.0;
    let ws = worktree(vec![
        chatty,
        ps(2, "b", Waiting, "", T0 + 10.0, AgentType::Unknown),
    ]);
    assert_eq!(ws.rolled_up_status(), Waiting);
    assert_eq!(ws.representative().unwrap().pane_index, 2);
}

#[test]
fn empty_worktree_has_unknown_status() {
    assert_eq!(worktree(vec![]).rolled_up_status(), Unknown);
}

#[test]
fn has_urgent_sees_a_pane_the_rollup_did_not_pick() {
    let ws = worktree(vec![
        ps(1, "t1", Error, "failed", T0, AgentType::Unknown),
        ps(2, "t2", Running, "", T0 + 60.0, AgentType::Unknown),
    ]);
    assert_eq!(ws.rolled_up_status(), Running);
    assert!(ws.has_urgent());
}

#[test]
fn not_urgent_when_no_pane_is() {
    assert!(!worktree(vec![ps(1, "t1", Running, "", T0, AgentType::Unknown)]).has_urgent());
}

#[test]
fn single_pane_worktree() {
    let ws = worktree(vec![ps(
        1,
        "t1",
        Running,
        "working",
        T0,
        AgentType::Unknown,
    )]);
    assert_eq!(ws.statuses().len(), 1);
    assert_eq!(ws.rolled_up_status(), Running);
    assert!(!ws.has_urgent());
}

/// Equal change times go to the earlier leaf, as Swift's `max(by:)` does.
#[test]
fn ties_go_to_the_earlier_leaf() {
    let ws = worktree(vec![
        ps(1, "a", Idle, "", T0, AgentType::Unknown),
        ps(2, "b", Running, "", T0, AgentType::Unknown),
    ]);
    assert_eq!(ws.representative().unwrap().pane_index, 1);
}

// MARK: WorktreeStatusAggregatorTests

fn update(status: AgentStatus, message: &str) -> PaneUpdate {
    PaneUpdate {
        status,
        last_message: message.into(),
        last_user_prompt: String::new(),
        agent_type: AgentType::Unknown,
        background_busy: false,
    }
}

#[test]
fn single_pane_update() {
    let mut a = Aggregator::new();
    a.register_pane("t1", "/repo/main", 0);
    let u = a.update("t1", update(Running, "building..."), T0);
    let ws = u.worktree.unwrap();
    assert_eq!(ws.panes.len(), 1);
    assert_eq!(ws.panes[0].status, Running);
    assert_eq!(ws.panes[0].pane_index, 1);
    assert_eq!(ws.most_recent_message, "building...");
}

#[test]
fn multi_pane_update() {
    let mut a = Aggregator::new();
    a.register_pane("t1", "/repo/main", 0);
    a.register_pane("t2", "/repo/main", 1);
    a.update("t1", update(Running, "building"), T0);
    let ws = a
        .update("t2", update(Idle, "done"), T0 + 1.0)
        .worktree
        .unwrap();
    assert_eq!(ws.panes.len(), 2);
    assert_eq!(ws.statuses(), vec![Running, Idle]);
    assert_eq!(ws.rolled_up_status(), Idle);
    assert_eq!(ws.most_recent_message, "done");
    assert_eq!(ws.most_recent_pane_index, 2);
}

#[test]
fn status_change_fires_pane_callback() {
    let mut a = Aggregator::new();
    a.register_pane("t1", "/repo/main", 0);
    assert!(
        a.update("t1", update(Running, ""), T0)
            .pane_change
            .is_none(),
        "a first sighting is no edge"
    );
    let c = a
        .update("t1", update(Waiting, "need input"), T0 + 1.0)
        .pane_change
        .unwrap();
    assert_eq!(c.pane_index, 1);
    assert_eq!(c.old_status, Running);
    assert_eq!(c.new_status, Waiting);
}

#[test]
fn no_change_does_not_fire_callbacks() {
    let mut a = Aggregator::new();
    a.register_pane("t1", "/repo/main", 0);
    a.update("t1", update(Running, "building"), T0);
    let u = a.update("t1", update(Running, "building"), T0 + 1.0);
    assert!(u.worktree.is_none());
    assert!(u.pane_change.is_none());
}

#[test]
fn reindex_on_pane_removal() {
    let mut a = Aggregator::new();
    for (i, id) in ["t1", "t2", "t3"].iter().enumerate() {
        a.register_pane(id, "/repo/main", i);
    }
    a.update("t1", update(Running, "a"), T0);
    a.update("t2", update(Idle, "b"), T0 + 1.0);
    a.update("t3", update(Waiting, "c"), T0 + 2.0);
    a.unregister_pane("t2", "/repo/main");
    a.update_leaf_order("/repo/main", vec!["t1".into(), "t3".into()]);
    let ws = a.status("/repo/main").unwrap();
    assert_eq!(ws.panes.len(), 2);
    assert_eq!(ws.panes[0].pane_index, 1);
    assert_eq!(ws.panes[1].pane_index, 2);
}

/// The bug the port fixes: the Swift rebuild dropped `backgroundBusy`, so a
/// pane idle at its prompt with a monitor running rolled up as idle.
#[test]
fn rebuild_keeps_background_busy() {
    let mut a = Aggregator::new();
    a.register_pane("t1", "/repo/main", 0);
    a.register_pane("t2", "/repo/main", 1);
    let mut u = update(Idle, "watching CI");
    u.background_busy = true;
    a.update("t1", u, T0 + 5.0);
    a.update("t2", update(Idle, "x"), T0); // rebuilds without touching t1's recency
    let ws = a.status("/repo/main").unwrap();
    assert!(ws.panes[0].background_busy);
    assert_eq!(ws.rolled_up_status(), Running);
    assert_eq!(ws.grouping_status(), Running);
    // A background change alone is a visible change.
    let mut quiet = update(Idle, "watching CI");
    quiet.background_busy = false;
    assert!(a.update("t1", quiet, T0 + 6.0).worktree.is_some());
}

#[test]
fn last_activity_ignores_the_first_sighting_when_seeded() {
    let mut a = Aggregator::new();
    a.seed_last_activity(
        &[("/repo/main".to_string(), T0 - 100.0)]
            .into_iter()
            .collect(),
    );
    a.register_pane("t1", "/repo/main", 0);
    let u = a.update("t1", update(Running, ""), T0);
    assert!(u.activity.is_none());
    assert_eq!(a.last_activity("/repo/main"), Some(T0 - 100.0));
    let u = a.update("t1", update(Idle, ""), T0 + 1.0);
    assert_eq!(u.activity, Some(("/repo/main".to_string(), T0 + 1.0)));
}

#[test]
fn grouping_status_over_registry_panes() {
    let mut r = Registry::new();
    register(&mut r, "a", "/wt");
    register(&mut r, "b", "/wt");
    scan(&mut r, "a", Running, AgentType::Unknown, T0);
    scan(&mut r, "b", Waiting, AgentType::Unknown, T0);
    assert_eq!(grouping_status(r.panes_in_worktree("/wt")), Waiting);
    let o = scan(&mut r, "b", Idle, AgentType::Unknown, T0 + 1.0).unwrap();
    let mut a = Aggregator::new();
    a.register_pane("b", "/wt", 0);
    assert!(a
        .update("b", PaneUpdate::from_pane(&o.info), T0)
        .worktree
        .is_some());
}
