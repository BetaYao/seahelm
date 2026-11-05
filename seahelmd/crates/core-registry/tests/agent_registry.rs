//! Port of Tests/AgentRegistryTests.swift, minus `updateStatus` (dead: only
//! tests called it). Tests that used it to set a status now ingest a scan.
//! The index-only `registerTerminalID` was dead too; its tests go through
//! `register` / `unregister`.

mod common;

use common::*;
use seahelm_core_registry::{Registration, Registry};
use seahelm_core_types::{AgentStatus, AgentType};

#[test]
fn register_and_query() {
    let mut r = Registry::new();
    register_full(&mut r, "s1", "/tmp/repo/main", "main", "MyProject", None);
    let panes: Vec<_> = r.panes().collect();
    assert_eq!(panes.len(), 1);
    assert_eq!(panes[0].id, "s1");
    assert_eq!(panes[0].worktree_path, "/tmp/repo/main");
    assert_eq!(panes[0].branch, "main");
    assert_eq!(panes[0].project, "MyProject");
    assert_eq!(panes[0].agent_type, AgentType::Unknown);
    assert_eq!(panes[0].status, AgentStatus::Unknown);
}

#[test]
fn unregister() {
    let mut r = Registry::new();
    register(&mut r, "s1", "/tmp/repo/main");
    r.unregister("s1");
    assert_eq!(r.panes().count(), 0);
    assert!(r.pane("s1").is_none());
    assert!(r.pane_for_worktree("/tmp/repo/main").is_none());
}

#[test]
fn unregister_cleans_up_backends_by_path() {
    let mut r = Registry::new();
    register(&mut r, "seahelm-test-main", "/tmp/test-repo/main");
    r.unregister("seahelm-test-main");
    assert!(r.pane("seahelm-test-main").is_none());
    assert!(r.pane_for_worktree("/tmp/test-repo/main").is_none());
}

#[test]
fn update_detection_from_unknown() {
    let mut r = Registry::new();
    register(&mut r, "s", "/tmp/repo/main");
    r.update_detection("s", AgentType::ClaudeCode, None);
    assert_eq!(r.pane("s").unwrap().agent_type, AgentType::ClaudeCode);
}

#[test]
fn update_detection_ai_agent_cannot_demote_to_shell_task() {
    let mut r = Registry::new();
    register(&mut r, "s", "/tmp/repo/main");
    r.update_detection("s", AgentType::ClaudeCode, None);
    r.update_detection("s", AgentType::Brew, None);
    assert_eq!(r.pane("s").unwrap().agent_type, AgentType::ClaudeCode);
}

#[test]
fn update_detection_ai_agent_can_upgrade_to_another_ai_agent() {
    let mut r = Registry::new();
    register(&mut r, "s", "/tmp/repo/main");
    r.update_detection("s", AgentType::Codex, None);
    r.update_detection("s", AgentType::ClaudeCode, None);
    assert_eq!(r.pane("s").unwrap().agent_type, AgentType::ClaudeCode);
}

#[test]
fn update_detection_shell_task_can_be_replaced() {
    let mut r = Registry::new();
    register(&mut r, "s", "/tmp/repo/main");
    r.update_detection("s", AgentType::Brew, None);
    r.update_detection("s", AgentType::ClaudeCode, None);
    assert_eq!(r.pane("s").unwrap().agent_type, AgentType::ClaudeCode);
}

#[test]
fn update_detection_shell_task_can_be_replaced_by_shell_task() {
    let mut r = Registry::new();
    register(&mut r, "s", "/tmp/repo/main");
    r.update_detection("s", AgentType::Brew, None);
    r.update_detection("s", AgentType::Make, None);
    assert_eq!(r.pane("s").unwrap().agent_type, AgentType::Make);
}

#[test]
fn update_detection_ignores_unknown_type() {
    let mut r = Registry::new();
    register(&mut r, "s", "/tmp/repo/main");
    assert!(!r.update_detection("s", AgentType::Unknown, None));
    assert_eq!(r.pane("s").unwrap().agent_type, AgentType::Unknown);
}

#[test]
fn update_detection_sets_command_line() {
    let mut r = Registry::new();
    register(&mut r, "s", "/tmp/repo/main");
    assert!(r.update_detection("s", AgentType::Brew, Some("brew install ffmpeg".into())));
    let p = r.pane("s").unwrap();
    assert_eq!(p.command_line.as_deref(), Some("brew install ffmpeg"));
    assert_eq!(p.agent_type, AgentType::Brew);
}

#[test]
fn agent_for_worktree() {
    let mut r = Registry::new();
    register(&mut r, "s", "/tmp/repo/main");
    let p = r.pane_for_worktree("/tmp/repo/main").unwrap();
    assert_eq!(p.id, "s");
    assert_eq!(p.worktree_path, "/tmp/repo/main");
}

#[test]
fn agent_for_worktree_returns_nil_for_unknown() {
    assert!(Registry::new().pane_for_worktree("/nonexistent").is_none());
}

/// The "safe to touch this worktree?" guard must see a non-first pane.
#[test]
fn has_running_pane_sees_a_non_first_pane() {
    let mut r = Registry::new();
    register(&mut r, "first", "/tmp/repo/split");
    register(&mut r, "second", "/tmp/repo/split");
    scan(
        &mut r,
        "second",
        AgentStatus::Running,
        AgentType::Unknown,
        T0,
    );
    assert_ne!(
        r.pane_for_worktree("/tmp/repo/split").unwrap().status,
        AgentStatus::Running
    );
    assert!(r.has_running_pane("/tmp/repo/split"));
}

#[test]
fn has_running_pane_is_false_when_every_pane_is_idle() {
    let mut r = Registry::new();
    register(&mut r, "first", "/tmp/repo/quiet");
    register(&mut r, "second", "/tmp/repo/quiet");
    scan(&mut r, "first", AgentStatus::Idle, AgentType::Unknown, T0);
    scan(&mut r, "second", AgentStatus::Idle, AgentType::Unknown, T0);
    assert!(!r.has_running_pane("/tmp/repo/quiet"));
    assert!(!r.has_running_pane("/nonexistent"));
}

#[test]
fn all_agents_preserves_insertion_order() {
    let mut r = Registry::new();
    register(&mut r, "a", "/a");
    register(&mut r, "b", "/b");
    register(&mut r, "c", "/c");
    let ids: Vec<_> = r.panes().map(|p| p.id.as_str()).collect();
    assert_eq!(ids, ["a", "b", "c"]);
}

#[test]
fn reorder_with_worktree_paths() {
    let mut r = Registry::new();
    register(&mut r, "a", "/a");
    register(&mut r, "b", "/b");
    register(&mut r, "c", "/c");
    r.reorder(&["/c".into(), "/a".into(), "/b".into()]);
    let paths: Vec<_> = r.panes().map(|p| p.worktree_path.as_str()).collect();
    assert_eq!(paths, ["/c", "/a", "/b"]);
}

#[test]
fn agents_for_project() {
    let mut r = Registry::new();
    register_full(&mut r, "1", "/repo1/main", "main", "Repo1", None);
    register_full(&mut r, "2", "/repo2/main", "main", "Repo2", None);
    register_full(&mut r, "3", "/repo1/feature", "feature", "Repo1", None);
    let repo1: Vec<_> = r.panes_for_project("Repo1").collect();
    assert_eq!(repo1.len(), 2);
    assert!(repo1.iter().all(|p| p.project == "Repo1"));
}

#[test]
fn total_duration_computed_from_started_at() {
    let mut r = Registry::new();
    register_full(&mut r, "s", "/tmp/repo/main", "main", "P", Some(T0 - 300.0));
    let d = r.pane("s").unwrap().total_duration(T0);
    assert!(d > 299.0 && d < 302.0);
}

#[test]
fn total_duration_zero_when_no_started_at() {
    let mut r = Registry::new();
    register(&mut r, "s", "/tmp/repo/main");
    assert_eq!(r.pane("s").unwrap().total_duration(T0), 0.0);
}

#[test]
fn worktree_index_stores_multiple_terminals() {
    let mut r = Registry::new();
    register(&mut r, "test-t1", "/test/repo/main");
    register(&mut r, "test-t2", "/test/repo/main");
    assert_eq!(
        r.pane_ids_in_worktree("/test/repo/main"),
        ["test-t1", "test-t2"]
    );
}

#[test]
fn unregister_removes_from_worktree_index() {
    let mut r = Registry::new();
    register(&mut r, "test-t1", "/test/repo/main");
    register(&mut r, "test-t2", "/test/repo/main");
    r.unregister("test-t1");
    assert_eq!(r.pane_ids_in_worktree("/test/repo/main"), ["test-t2"]);
}

#[test]
fn unregister_last_terminal_removes_worktree_entry() {
    let mut r = Registry::new();
    register(&mut r, "test-t1", "/test/repo/main");
    r.unregister("test-t1");
    assert!(r.pane_ids_in_worktree("/test/repo/main").is_empty());
}

// Beyond the Swift suite: identity and moves.

/// A pane is found by its session name or by the alias its client
/// registered, and the wire's `pane_id` is the alias.
#[test]
fn aliases_resolve_to_the_session() {
    let mut r = Registry::new();
    r.register(Registration {
        pane: "seahelm-repo-main".into(),
        alias: Some("STATION-UUID".into()),
        worktree_path: "/repo".into(),
        project: "repo".into(),
        branch: "main".into(),
        agent_type: AgentType::Unknown,
        started_at: None,
    });
    assert_eq!(
        r.resolve(Some("STATION-UUID"), "/elsewhere").as_deref(),
        Some("seahelm-repo-main")
    );
    assert_eq!(
        r.resolve(Some("seahelm-repo-main"), "/elsewhere")
            .as_deref(),
        Some("seahelm-repo-main")
    );
    let j = r.pane_json("seahelm-repo-main").unwrap();
    assert_eq!(j["pane_id"], "STATION-UUID");
    assert_eq!(j["pane_session_key"], "seahelm-repo-main");
    assert_eq!(j["agent_type"], "unknown");
    assert_eq!(j["status"], "Unknown");
    assert!(j.get("unseen").is_none());
    r.unregister("seahelm-repo-main");
    assert_eq!(r.resolve(Some("STATION-UUID"), "/elsewhere"), None);
}

/// The registry's own cwd fallback takes the longest prefix: a worktree
/// nested inside another (`<repo>/.claude/worktrees/x`) wins over the repo.
#[test]
fn cwd_fallback_uses_the_longest_prefix() {
    let mut r = Registry::new();
    register(&mut r, "outer", "/repo");
    register(&mut r, "inner", "/repo/.claude/worktrees/x");
    assert_eq!(
        r.resolve(None, "/repo/.claude/worktrees/x/src").as_deref(),
        Some("inner")
    );
    assert_eq!(r.resolve(None, "/repo/src").as_deref(), Some("outer"));
    assert_eq!(
        r.resolve(None, "/repository"),
        None,
        "a prefix only counts on a path boundary"
    );
    assert_eq!(
        r.resolve(Some("unknown-hint"), "/repo").as_deref(),
        Some("outer")
    );
}

/// A live pane that is not registered yet is adopted into its sibling's
/// worktree, so its own events stop landing on the sibling.
#[test]
fn live_unregistered_pane_is_adopted() {
    let mut r = Registry::new();
    register_full(&mut r, "first", "/repo", "feat", "P", None);
    let live = |s: &str| s == "second";
    assert_eq!(
        r.resolve_or_adopt(Some("second"), "/repo/sub", &live)
            .as_deref(),
        Some("second")
    );
    let p = r.pane("second").unwrap();
    assert_eq!(
        (
            p.worktree_path.as_str(),
            p.branch.as_str(),
            p.project.as_str()
        ),
        ("/repo", "feat", "P")
    );
    assert_eq!(r.pane_ids_in_worktree("/repo"), ["first", "second"]);
    // Not live: no adoption, the worktree's first pane gets it.
    assert_eq!(
        r.resolve_or_adopt(Some("ghost"), "/repo", &live).as_deref(),
        Some("first")
    );
    assert!(r.pane("ghost").is_none());
    // Live but no sibling to inherit from: nothing to adopt into.
    assert_eq!(
        r.resolve_or_adopt(Some("second"), "/nowhere", &|_| true)
            .as_deref(),
        Some("second")
    );
    assert_eq!(
        r.resolve_or_adopt(Some("lonely"), "/nowhere", &|_| true),
        None
    );
}

/// A move keeps every timer and field, and is announced.
#[test]
fn rehome_keeps_history() {
    let mut r = Registry::new();
    register(&mut r, "p", "/a");
    hook(&mut r, "p", prompt("go"), T0);
    assert!(r.set_unseen("p", true));
    assert!(r.rehome("p", "/b", "b", "P"));
    assert!(!r.rehome("p", "/b", "b", "P"), "already there");
    assert!(!r.rehome("nobody", "/b", "b", "P"));
    let p = r.pane("p").unwrap();
    assert_eq!(p.worktree_path, "/b");
    assert_eq!(p.last_user_prompt, "go");
    assert!(p.unseen_completion);
    assert_eq!(r.turn_started("p"), Some(T0));
    assert!(r.pane_for_worktree("/a").is_none());
    let last = r.events().events_after(0).pop().unwrap();
    assert_eq!(last["type"], "pane.rehomed");
    assert_eq!(last["worktree_path"], "/b");
    assert_eq!(last["old_worktree_path"], "/a");
}

/// A `git switch` in the worktree a pane already has: the branch follows.
#[test]
fn set_branch_follows_a_switch_in_place() {
    let mut r = Registry::new();
    register(&mut r, "p", "/a");
    hook(&mut r, "p", prompt("go"), T0);
    assert!(r.set_branch("p", "task/next", ""));
    assert!(!r.set_branch("p", "task/next", ""), "unchanged");
    assert!(!r.set_branch("nobody", "x", ""));
    let p = r.pane("p").unwrap();
    assert_eq!(p.branch, "task/next");
    assert_eq!(p.worktree_path, "/a");
    assert_eq!(p.last_user_prompt, "go");
    assert!(r.set_branch("p", "task/next", "Other"), "a new project counts");
    assert_eq!(r.pane("p").unwrap().project, "Other");
}
