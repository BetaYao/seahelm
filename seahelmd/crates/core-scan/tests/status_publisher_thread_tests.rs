//! Port of Tests/StatusPublisherThreadTests.swift: the per-pane logic, not
//! the threading. Followed by tests of `PaneScanner` itself, which the Swift
//! could not test without a live surface.
//!
//! Not ported: `testConcurrentUpdateAndPollDoesNotCrash` (the scanner has no
//! threads or shared state) and `testAgentDefSelectionUsesExistingCodexType`
//! (`findAgentDef` only fed the unused last-message string).

use seahelm_core_scan::debounce::DebouncedStatusTracker;
use seahelm_core_scan::pane::{idle_observation, on_stride, round_start, should_skip_unchanged_frame};
use seahelm_core_scan::Detection;
use seahelm_core_types::AgentStatus::{self, *};

#[test]
fn backend_capture_runs_every_stride_cycle() {
    assert!(on_stride(0, 0, 3));
    assert!(!on_stride(1, 0, 3));
    assert!(!on_stride(2, 0, 3));
    assert!(on_stride(3, 0, 3));
}

#[test]
fn backend_capture_staggers_by_offset() {
    let a: Vec<u64> = (0..3).filter(|&c| on_stride(c, 0, 3)).collect();
    let b: Vec<u64> = (0..3).filter(|&c| on_stride(c, 1, 3)).collect();
    assert_eq!(a.len(), 1);
    assert_eq!(b.len(), 1);
    assert_ne!(a, b);
}

#[test]
fn backend_capture_handles_negative_offset() {
    let fires = (0..4).filter(|&c| on_stride(c, -7, 4)).count();
    assert_eq!(fires, 1);
}

#[test]
fn unchanged_frame_skips_when_scan_state_is_synchronized() {
    assert!(should_skip_unchanged_frame(true, Some(Idle), Some(Idle), false, Unknown));
}

#[test]
fn unchanged_frame_does_not_skip_stale_published_scan_state() {
    assert!(!should_skip_unchanged_frame(true, Some(Idle), Some(Running), false, Unknown));
}

#[test]
fn periodic_recheck_does_not_skip_synchronized_frame() {
    assert!(!should_skip_unchanged_frame(true, Some(Idle), Some(Idle), true, Unknown));
}

/// Stop reported, scan still holding running: an unchanged frame must be
/// looked at again.
#[test]
fn unchanged_frame_is_rechecked_while_a_stopped_turn_is_held_running() {
    assert!(!should_skip_unchanged_frame(true, Some(Running), Some(Running), false, Idle));
    assert!(should_skip_unchanged_frame(true, Some(Idle), Some(Idle), false, Idle));
    assert!(should_skip_unchanged_frame(true, Some(Running), Some(Running), false, Running), "mid-turn frames still skip as before");
}

#[test]
fn defaulted_idle_is_held_mid_turn_but_commits_once_the_hook_stopped() {
    let blank = Detection { state: Idle, is_defaulted: true, ..Default::default() };
    let mut mid = DebouncedStatusTracker::new();
    mid.update(Running, true, false);
    for _ in 0..5 {
        let (visible, defaulted) = idle_observation(&blank, Running);
        assert!(!mid.update(Idle, visible, defaulted));
    }
    assert_eq!(mid.current_status(), Running, "a thinking gap is not the end of a turn");

    let mut stopped = DebouncedStatusTracker::new();
    stopped.update(Running, true, false);
    let (visible, defaulted) = idle_observation(&blank, Idle);
    assert!(stopped.update(Idle, visible, defaulted));
    assert_eq!(stopped.current_status(), Idle);
}

#[test]
fn round_counts_from_the_later_of_scan_start_and_prompt() {
    let scan = 1000.0;
    assert_eq!(round_start(None, Some(scan)), None, "not running on screen, no round");
    assert_eq!(round_start(Some(scan), None), Some(scan));
    assert_eq!(round_start(Some(scan), Some(1074.0)), Some(1074.0), "a prompt after the scan's start is a new round");
    assert_eq!(round_start(Some(scan), Some(990.0)), Some(scan));
}

mod pane_scanner {
    use super::*;
    use seahelm_core_scan::pane::{PaneScanner, ScanInput, ScanOutput, PROBE_REFRESH_STRIDE, UNCHANGED_FRAME_RECHECK_STRIDE};
    use seahelm_core_scan::process::Probe;
    use seahelm_core_scan::{ManifestStore, Snapshot};
    use seahelm_core_types::{AgentType, EventKind};

    fn snap(generation: u64, viewport: &str) -> Snapshot {
        Snapshot { generation, cols: 80, rows: 24, viewport: viewport.into(), ..Default::default() }
    }

    struct Pane {
        scanner: PaneScanner,
        store: ManifestStore,
        agent: AgentType,
        hook: AgentStatus,
        now: f64,
    }

    impl Pane {
        fn new(agent: AgentType) -> Self {
            Pane { scanner: PaneScanner::new(), store: ManifestStore::bundled(), agent, hook: Unknown, now: 100.0 }
        }

        fn poll(&mut self, s: &Snapshot, probe: Option<&Probe>) -> ScanOutput {
            self.now += 2.0;
            let input = ScanInput { snapshot: s, hook_status: self.hook, hook_turn_started: None, probe, current_agent: self.agent, now: self.now };
            let out = self.scanner.observe(&input, &self.store);
            self.agent = out.agent_type;
            out
        }
    }

    fn observed(out: &ScanOutput) -> AgentStatus {
        match &out.event {
            Some(EventKind::ScreenObserved { status, .. }) => *status,
            other => panic!("no ScreenObserved: {other:?}"),
        }
    }

    const WORKING: &str = "✻ sprouting… (26s · ↓ 762 tokens)\n❯ ";

    #[test]
    fn an_unchanged_generation_is_skipped_until_the_recheck() {
        let mut p = Pane::new(AgentType::ClaudeCode);
        let s = snap(1, WORKING);
        assert_eq!(observed(&p.poll(&s, None)), Running);
        let mut looked = 0;
        for _ in 0..UNCHANGED_FRAME_RECHECK_STRIDE {
            if p.poll(&s, None).event.is_some() {
                looked += 1;
            }
        }
        assert_eq!(looked, 1, "one forced recheck per window, everything else skipped");
        assert_eq!(observed(&p.poll(&snap(2, WORKING), None)), Running, "a new generation is looked at");
    }

    #[test]
    fn invalidate_forces_the_next_frame() {
        let mut p = Pane::new(AgentType::ClaudeCode);
        let s = snap(1, WORKING);
        p.poll(&s, None);
        assert!(p.poll(&s, None).event.is_none());
        p.scanner.invalidate();
        assert!(p.poll(&s, None).event.is_some());
    }

    #[test]
    fn a_stopped_hook_rechecks_a_frame_held_running() {
        let mut p = Pane::new(AgentType::ClaudeCode);
        p.poll(&snap(1, WORKING), None);
        let quiet = snap(2, "done.\n❯ ");
        // The defaulted idle is held while the hook says nothing.
        assert_eq!(observed(&p.poll(&quiet, None)), Running);
        assert!(p.poll(&quiet, None).event.is_none());
        p.hook = Idle;
        assert_eq!(observed(&p.poll(&quiet, None)), Idle, "the hook's Stop lets the same frame commit idle");
    }

    #[test]
    fn an_approval_dialog_is_waiting_and_raises_a_question() {
        let mut p = Pane::new(AgentType::ClaudeCode);
        let screen = "Bash command\n\nDo you want to proceed?\n❯ 1. Yes\n  2. Yes, and don't ask again\n  3. No";
        let out = p.poll(&snap(1, screen), None);
        assert_eq!(observed(&out), Waiting);
        match out.question {
            Some(EventKind::Question { prompt, options, .. }) => {
                assert_eq!(prompt, "Claude Code requires approval");
                assert_eq!(options, ["Yes", "Yes, and don't ask again", "No"]);
            }
            other => panic!("expected a question, got {other:?}"),
        }
    }

    #[test]
    fn the_ask_user_question_dialog_raises_no_second_card() {
        let mut p = Pane::new(AgentType::ClaudeCode);
        let screen = "Pick fruits\n❯ 1. [ ] Apple\n  2. [ ] Banana\n  3. Chat about this";
        let out = p.poll(&snap(1, screen), None);
        assert_eq!(observed(&out), Waiting);
        assert!(out.question.is_none());
    }

    #[test]
    fn a_shell_pane_with_a_numbered_list_is_not_waiting() {
        let mut p = Pane::new(AgentType::Unknown);
        let out = p.poll(&snap(1, "$ ls\n❯ 1. a\n  2. b"), None);
        assert!(out.question.is_none());
        assert_ne!(observed(&out), Waiting);
    }

    #[test]
    fn a_fresh_probe_without_the_agent_takes_it_away_and_is_cached() {
        let mut p = Pane::new(AgentType::Unknown);
        let with_claude = Probe { agent: Some(AgentType::ClaudeCode), saw_session: true, foreground_command_line: Some("claude".into()), memory_bytes: 1 };
        let out = p.poll(&snap(1, "$ "), Some(&with_claude));
        assert_eq!(out.agent_type, AgentType::ClaudeCode);
        assert_eq!(out.command_line.as_deref(), Some("claude"));
        assert!(!p.scanner.needs_probe());

        // Inside the stride a new probe is ignored and the cache answers.
        let gone = Probe { agent: None, saw_session: true, foreground_command_line: None, memory_bytes: 1 };
        for g in 2..=PROBE_REFRESH_STRIDE {
            assert_eq!(p.poll(&snap(g, "claude was here\n$ "), Some(&gone)).agent_type, AgentType::ClaudeCode);
        }
        assert!(p.scanner.needs_probe());
        let out = p.poll(&snap(10, "claude was here\n$ "), Some(&gone));
        assert_eq!(out.agent_type, AgentType::ShellCommand, "scrollback naming the agent does not bring it back");
        assert_eq!(out.command_line, None);
    }

    #[test]
    fn a_shell_job_is_named_from_its_command_line() {
        let mut p = Pane::new(AgentType::Unknown);
        let brew = Probe { agent: None, saw_session: true, foreground_command_line: Some("brew update".into()), memory_bytes: 0 };
        let out = p.poll(&snap(1, "==> Updating Homebrew..."), Some(&brew));
        assert_eq!(out.agent_type, AgentType::Brew);
        assert_eq!(out.command_line.as_deref(), Some("brew update"));
    }

    #[test]
    fn the_round_counts_from_the_scan_seeing_it_start() {
        let mut p = Pane::new(AgentType::ClaudeCode);
        p.poll(&snap(1, WORKING), None); // now = 102, running from here
        let out = p.poll(&snap(2, &format!("{WORKING} ")), None); // now = 104
        match out.event {
            Some(EventKind::ScreenObserved { round_duration, .. }) => assert_eq!(round_duration, 2.0),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_held_or_empty_session_is_not_scanned() {
        let mut p = Pane::new(AgentType::ClaudeCode);
        let held = Snapshot { started: Some(false), ..snap(1, WORKING) };
        assert!(p.poll(&held, None).event.is_none());
        assert!(p.poll(&snap(1, ""), None).event.is_none());
        assert!(p.poll(&snap(1, WORKING), None).event.is_some(), "the skipped frames were not recorded");
    }

    #[test]
    fn a_spinner_title_alone_reads_running() {
        let mut p = Pane::new(AgentType::Codex);
        let s = Snapshot { title: "\u{2810} thinking".into(), ..snap(1, "› ") };
        assert_eq!(observed(&p.poll(&s, None)), Running);
    }
}
