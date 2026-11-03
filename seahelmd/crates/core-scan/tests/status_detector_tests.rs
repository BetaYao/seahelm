//! Port of Tests/StatusDetectorTests.swift (StatusDetectorTests,
//! DebouncedStatusTrackerTests, AgentStatusTests).
//!
//! Not ported: the five `testShellPhase_*` cases (the OSC 133 tier is not fed
//! in production and is left out) and `AgentDefTests` (the legacy AgentDef
//! rules; production only used them for a last-message string nobody read).
//! The `testTextPattern_*` cases ran against the legacy AgentDef rules; they
//! run here against the bundled manifests, which production uses.

use seahelm_core_scan::detect::{detect, ProcessStatus};
use seahelm_core_scan::ManifestStore;
use seahelm_core_types::AgentStatus;

fn lines(l: &[&str]) -> String {
    l.join("\n")
}

fn status(manifest: &str, content: &str) -> AgentStatus {
    let store = ManifestStore::bundled();
    detect(ProcessStatus::Running, content, store.get(manifest), "", "").state
}

#[test]
fn process_exited_overrides_everything() {
    let store = ManifestStore::bundled();
    let d = detect(ProcessStatus::Exited, "to interrupt", store.get("claude"), "", "");
    assert_eq!(d.state, AgentStatus::Exited);
}

#[test]
fn process_error_overrides_everything() {
    let d = detect(ProcessStatus::Error, "", None, "", "");
    assert_eq!(d.state, AgentStatus::Error);
}

#[test]
fn text_pattern_claude_running() {
    assert_eq!(status("claude", "Press Escape to interrupt"), AgentStatus::Running);
}

#[test]
fn text_pattern_claude_waiting() {
    assert_eq!(status("claude", "Do you want to proceed?"), AgentStatus::Waiting);
}

#[test]
fn text_pattern_claude_error() {
    assert_eq!(status("claude", "ERROR: something went wrong"), AgentStatus::Error);
}

#[test]
fn text_pattern_claude_default_idle() {
    assert_eq!(status("claude", "some random output"), AgentStatus::Idle);
}

#[test]
fn text_pattern_claude_task_progress_thinking_is_running() {
    let content = lines(&[
        "superpowers:code-reviewer(Code quality review Task 1)",
        "|_ Done (18 tool uses * 61.8k tokens * 1m 15s)",
        "",
        "* Task 2: Add insert_session_from_supabase to SessionManager... (thinking)",
        "  - Task 2: Add insert_session_from_supabase to SessionManager",
        "  - Task 3: Wire fetch+insert into apply_start_runtime",
    ]);
    assert_eq!(status("claude", &content), AgentStatus::Running);
}

#[test]
fn text_pattern_claude_task_transition_is_running() {
    assert_eq!(status("claude", "Task 1 approved. Moving to Task 2."), AgentStatus::Running);
}

#[test]
fn text_pattern_codex_approval_prompt_is_waiting() {
    let content = lines(&[
        "Would you like to run the following command?",
        "",
        "Reason: Allow activating the current Seahelm Tauri smoke window by pid?",
        "",
        "$ osascript -e 'tell application \"System Events\" to set frontmost of first process whose unix id is 51869 to true'",
        "",
        "1. Yes, proceed (y)",
        "2. Yes, and don't ask again for commands that start with ...",
        "3. No, and tell Codex what to do differently (esc)",
    ]);
    assert_eq!(status("codex", &content), AgentStatus::Waiting);
}

#[test]
fn text_pattern_codex_task_progress_thinking_is_running() {
    let content = lines(&[
        "Agent(Implement Task 2: insert_session_from_supabase)",
        "|_ Done (27 tool uses * 65.0k tokens * 3m 5s)",
        "",
        "* Task 2: Add insert_session_from_supabase to SessionManager... (thinking)",
        "  - Task 2: Add insert_session_from_supabase to SessionManager",
        "  - Task 3: Wire fetch+insert into apply_start_runtime",
    ]);
    assert_eq!(status("codex", &content), AgentStatus::Running);
}

#[test]
fn text_pattern_codex_task_transition_is_running() {
    assert_eq!(status("codex", "Task 1 approved. Moving to Task 2."), AgentStatus::Running);
}

#[test]
fn no_shell_info_no_agent_returns_unknown() {
    assert_eq!(detect(ProcessStatus::Running, "", None, "", "").state, AgentStatus::Unknown);
}

mod debounced_status_tracker_tests {
    use seahelm_core_scan::debounce::DebouncedStatusTracker;
    use seahelm_core_types::AgentStatus::{self, *};

    /// The Swift `update(status:)` with its default arguments.
    fn plain(t: &mut DebouncedStatusTracker, s: AgentStatus) -> bool {
        t.update(s, true, false)
    }

    #[test]
    fn initial_status_is_unknown() {
        assert_eq!(DebouncedStatusTracker::new().current_status(), Unknown);
    }

    #[test]
    fn update_changes_status() {
        let mut t = DebouncedStatusTracker::new();
        assert!(plain(&mut t, Running));
        assert_eq!(t.current_status(), Running);
    }

    #[test]
    fn update_same_status_no_change() {
        let mut t = DebouncedStatusTracker::new();
        plain(&mut t, Running);
        assert!(!plain(&mut t, Running));
    }

    #[test]
    fn update_unknown_preserves_current() {
        let mut t = DebouncedStatusTracker::new();
        plain(&mut t, Running);
        assert!(!plain(&mut t, Unknown));
        assert_eq!(t.current_status(), Running);
    }

    #[test]
    fn force_status() {
        let mut t = DebouncedStatusTracker::new();
        t.force_status(Error);
        assert_eq!(t.current_status(), Error);
    }

    #[test]
    fn reset() {
        let mut t = DebouncedStatusTracker::new();
        plain(&mut t, Running);
        t.reset();
        assert_eq!(t.current_status(), Unknown);
    }

    #[test]
    fn pending_idle_hold_held_until_confirmed() {
        let mut t = DebouncedStatusTracker::new();
        t.pending_idle_confirmations = 2;
        plain(&mut t, Running);
        assert!(!t.update(Idle, false, false));
        assert_eq!(t.current_status(), Running);
        assert!(t.update(Idle, false, false));
        assert_eq!(t.current_status(), Idle);
    }

    #[test]
    fn visible_idle_bypasses_hold() {
        let mut t = DebouncedStatusTracker::new();
        t.pending_idle_confirmations = 3;
        plain(&mut t, Running);
        assert!(t.update(Idle, true, false));
        assert_eq!(t.current_status(), Idle);
    }

    /// A defaulted idle is absence of evidence: it must not end a turn on one
    /// frame the way a matched idle rule would.
    #[test]
    fn defaulted_idle_holds_far_longer_than_a_matched_one() {
        let mut t = DebouncedStatusTracker::new();
        t.defaulted_idle_confirmations = 3;
        plain(&mut t, Running);
        assert!(!t.update(Idle, true, true));
        assert!(!t.update(Idle, true, true));
        assert_eq!(t.current_status(), Running, "a thinking pause is not a finished turn");
        assert!(t.update(Idle, true, true));
        assert_eq!(t.current_status(), Idle, "sustained silence still commits eventually");
    }

    #[test]
    fn defaulted_idle_counter_resets_when_working_reappears() {
        let mut t = DebouncedStatusTracker::new();
        t.defaulted_idle_confirmations = 2;
        plain(&mut t, Running);
        assert!(!t.update(Idle, true, true));
        assert!(!t.update(Running, false, false));
        assert!(!t.update(Idle, true, true));
        assert_eq!(t.current_status(), Running);
    }

    /// Entering idle from anything but running is a classification, not the
    /// end of a turn.
    #[test]
    fn defaulted_idle_from_unknown_commits_immediately() {
        let mut t = DebouncedStatusTracker::new();
        assert!(t.update(Idle, true, true));
        assert_eq!(t.current_status(), Idle);
    }

    #[test]
    fn pending_idle_reset_by_running_reobservation() {
        let mut t = DebouncedStatusTracker::new();
        t.pending_idle_confirmations = 2;
        plain(&mut t, Running);
        assert!(!t.update(Idle, false, false));
        assert!(!t.update(Running, false, false));
        assert!(!t.update(Idle, false, false));
        assert_eq!(t.current_status(), Running);
    }
}

mod agent_status_tests {
    use seahelm_core_types::AgentStatus::{self, *};

    #[test]
    fn priority_order() {
        assert!(Waiting.priority() > Error.priority());
        assert!(Error.priority() > Exited.priority());
        assert!(Exited.priority() > Running.priority());
        assert!(Running.priority() > Idle.priority());
        assert!(Idle.priority() > Unknown.priority());
    }

    #[test]
    fn waiting_wins_the_rollup_over_error() {
        assert_eq!(AgentStatus::highest_priority([Error, Waiting, Running]), Waiting);
    }

    #[test]
    fn highest_priority() {
        assert_eq!(AgentStatus::highest_priority([Idle, Running, Unknown]), Running);
    }

    #[test]
    fn highest_priority_empty() {
        assert_eq!(AgentStatus::highest_priority([]), Unknown);
    }

    #[test]
    fn is_urgent() {
        assert!(Error.is_urgent());
        assert!(Waiting.is_urgent());
        assert!(!Running.is_urgent());
        assert!(!Idle.is_urgent());
    }

    #[test]
    fn is_active() {
        assert!(Running.is_active());
        assert!(Waiting.is_active());
        assert!(!Idle.is_active());
        assert!(!Error.is_active());
    }
}
