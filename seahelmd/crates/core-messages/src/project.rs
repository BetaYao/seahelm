//! Outcomes into timeline rows (`PaneMessageProjector.swift`). Pure: the
//! hub stamps sequence numbers.

use seahelm_core_hooks::prompt::human_text;
use seahelm_core_registry::Outcome;
use seahelm_core_scan::manifest::MessageConfig;
use seahelm_core_types::{AgentStatus, EventKind, Timestamp};

use crate::event::{Kind, Message};

/// What a pane's last rows were, so repeats fold into them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Coalesce {
    last_tool: Option<String>,
    last_detail: Option<String>,
    last_is_error: Option<bool>,
    pub last_count: u32,
    /// The decision already on the timeline. A TUI approval dialog is
    /// re-ingested as a question on every rescan while it stays on screen,
    /// so only the agent running again, a new prompt or a tool run opens a
    /// new one.
    last_decision: Option<Vec<String>>,
}

/// The rows one outcome adds, and the pane's coalescing state after it.
/// `pane_id` is what clients call the pane (its alias, else its key).
pub fn project(o: &Outcome, pane_id: &str, config: &MessageConfig, coalesce: &Coalesce, now: Timestamp) -> (Vec<Message>, Coalesce) {
    let mut out = Vec::new();
    let mut coal = coalesce.clone();
    let key = o.info.id.as_str();
    let base = |kind| Message::new(pane_id, key, kind, now);

    if o.status_changed {
        if is_turn_edge(o.old_status, o.new_status) {
            let mut e = base(Kind::Status);
            e.status = Some(o.new_status.as_str().into());
            e.old_status = Some(o.old_status.as_str().into());
            out.push(e);
        }
        // While an approval dialog is on screen the scan reports Idle and the
        // dialog Waiting on every poll, so a status edge alone is not the
        // decision being answered. Only running again is.
        let decision = coal.last_decision.take();
        coal = Coalesce::default();
        if o.new_status != AgentStatus::Running {
            coal.last_decision = decision;
        }
    }

    let decide = |out: &mut Vec<Message>,
                  coal: &mut Coalesce,
                  text: String,
                  options: Vec<String>,
                  signature: Vec<String>| {
        if coal.last_decision.as_ref() == Some(&signature) {
            return;
        }
        out.push(base(Kind::Decision).with_text(text).with_options(options));
        coal.last_decision = Some(signature);
    };

    match &o.event.kind {
        EventKind::UserPrompt { text } => {
            coal.last_decision = None;
            // None when the harness opened the turn itself (a finished
            // background task): the user's side stays the user's.
            if let Some(shown) = human_text(text) {
                out.push(base(Kind::User).with_text(shown));
            }
        }
        EventKind::ToolUse { activity } => {
            coal.last_decision = None;
            let name = config.tool_aliases.get(&activity.tool).cloned().unwrap_or_else(|| activity.tool.clone());
            if config.coalesce_tools
                && coal.last_tool.as_deref() == Some(name.as_str())
                && coal.last_detail.as_deref() == Some(activity.detail.as_str())
                && coal.last_is_error == Some(activity.is_error)
            {
                coal.last_count += 1;
            } else {
                let mut e = base(Kind::Tool);
                e.tool = Some(name.clone());
                e.detail = Some(activity.detail.clone());
                e.is_error = Some(activity.is_error);
                out.push(e);
                coal.last_tool = Some(name);
                coal.last_detail = Some(activity.detail.clone());
                coal.last_is_error = Some(activity.is_error);
                coal.last_count = 1;
            }
        }
        EventKind::Question { prompt, options, .. } => {
            let mut sig = vec!["question".to_string(), prompt.clone()];
            sig.extend(options.iter().cloned());
            decide(&mut out, &mut coal, prompt.clone(), options.clone(), sig);
        }
        EventKind::Suggest { options } => {
            let mut sig = vec!["suggest".to_string()];
            sig.extend(options.iter().cloned());
            decide(
                &mut out,
                &mut coal,
                options.join(" · "),
                options.clone(),
                sig,
            );
        }
        EventKind::Notification { text, .. } => {
            let t = text.trim();
            if !t.is_empty() {
                out.push(base(Kind::Notice).with_text(t));
            }
        }
        EventKind::ScreenObserved { message, .. } if config.screen_fallback => {
            let t = message.trim();
            if !t.is_empty() {
                out.push(base(Kind::Notice).with_text(t));
            }
        }
        _ => {}
    }

    if o.is_completion_signal {
        let prose = o.info.last_assistant_message.trim();
        if !prose.is_empty() {
            out.push(base(Kind::Assistant).with_text(prose));
        }
    }
    (out, coal)
}

/// Which status changes earn a row: a turn starting or ending, and an
/// error. Idle ↔ Waiting is detection settling, and leaving Unknown is a
/// pane being registered.
pub fn is_turn_edge(old: AgentStatus, new: AgentStatus) -> bool {
    old != AgentStatus::Unknown && (old == AgentStatus::Running || new == AgentStatus::Running || new == AgentStatus::Error)
}

#[cfg(test)]
mod tests {
    use super::*;
    use seahelm_core_registry::PaneInfo;
    use seahelm_core_types::{ActivityEvent, AgentType, EventSource, NormalizedEvent, QuestionFlags};
    use std::collections::BTreeMap;

    use AgentStatus::*;

    fn outcome(kind: EventKind, changed: bool, old: AgentStatus, new: AgentStatus, completion: bool, assistant: &str) -> Outcome {
        let mut info = PaneInfo::new("t1".into(), None, "/wt".into(), "p".into(), "main".into(), None);
        info.status = new;
        info.last_assistant_message = assistant.into();
        Outcome {
            info,
            status_changed: changed,
            old_status: old,
            new_status: new,
            hold_seconds: 0.0,
            is_completion_signal: completion,
            event: NormalizedEvent { pane: "t1".into(), source: EventSource::Hook("cursor".into()), kind },
            seq: 1,
        }
    }

    fn plain(kind: EventKind) -> Outcome {
        outcome(kind, false, Idle, Running, false, "")
    }

    fn run(o: &Outcome, c: &Coalesce) -> (Vec<Message>, Coalesce) {
        project(o, "t1", &MessageConfig::default(), c, 0.0)
    }

    fn tool(name: &str, detail: &str) -> EventKind {
        EventKind::ToolUse { activity: ActivityEvent { tool: name.into(), detail: detail.into(), is_error: false, timestamp: 0.0 } }
    }

    fn approval() -> EventKind {
        EventKind::Question {
            prompt: "Claude Code requires approval".into(),
            options: vec!["1. Yes".into(), "2. No".into()],
            followups: vec![],
            flags: QuestionFlags::default(),
        }
    }

    fn scan(status: AgentStatus) -> EventKind {
        EventKind::ScreenObserved {
            status,
            message: String::new(),
            activity: vec![],
            command_line: None,
            agent_type: AgentType::ClaudeCode,
            round_duration: 0.0,
            tasks: vec![],
            background_busy: false,
        }
    }

    fn kinds(m: &[Message]) -> Vec<Kind> {
        m.iter().map(|e| e.kind).collect()
    }

    fn decisions(m: &[Message]) -> usize {
        m.iter().filter(|e| e.kind == Kind::Decision).count()
    }

    #[test]
    fn user_prompt_emits_user() {
        let (e, _) = run(&plain(EventKind::UserPrompt { text: "ship it".into() }), &Coalesce::default());
        assert_eq!(kinds(&e), [Kind::User]);
        assert_eq!(e[0].text.as_deref(), Some("ship it"));
        assert_eq!(e[0].pane_session_key, "t1");
    }

    #[test]
    fn a_machine_prompt_is_not_the_users() {
        let (e, _) = run(&plain(EventKind::UserPrompt { text: "<task-notification>done</task-notification>".into() }), &Coalesce::default());
        assert!(e.is_empty());
    }

    #[test]
    fn tool_use_emits_tool() {
        let (e, _) = run(&plain(tool("Read", "a.swift")), &Coalesce::default());
        assert_eq!(kinds(&e), [Kind::Tool]);
        assert_eq!((e[0].tool.as_deref(), e[0].detail.as_deref()), (Some("Read"), Some("a.swift")));
    }

    #[test]
    fn coalesce_identical_tools() {
        let o = plain(tool("Shell", "ls"));
        let (first, c1) = run(&o, &Coalesce::default());
        assert_eq!(first.len(), 1);
        let (second, c2) = run(&o, &c1);
        assert!(second.is_empty());
        assert_eq!(c2.last_count, 2);
    }

    #[test]
    fn assistant_only_on_completion() {
        let (e, _) = run(&outcome(EventKind::AgentStopped { success: true }, true, Running, Idle, true, "done"), &Coalesce::default());
        assert!(e.iter().any(|m| m.kind == Kind::Assistant && m.text.as_deref() == Some("done")));
        assert!(e.iter().any(|m| m.kind == Kind::Status));
        let (e, _) = run(&outcome(tool("Read", "x"), false, Idle, Running, false, "stale prose"), &Coalesce::default());
        assert!(!e.iter().any(|m| m.kind == Kind::Assistant));
    }

    #[test]
    fn leaving_unknown_is_not_a_status_row() {
        let (e, _) = run(&outcome(scan(Idle), true, Unknown, Idle, false, ""), &Coalesce::default());
        assert!(e.is_empty());
    }

    #[test]
    fn screen_fallback_off_ignores_scan_soup() {
        let mut k = scan(Running);
        if let EventKind::ScreenObserved { message, .. } = &mut k {
            *message = "Shell".into();
        }
        let (e, _) = run(&plain(k.clone()), &Coalesce::default());
        assert!(e.is_empty());
        let on = MessageConfig { screen_fallback: true, ..MessageConfig::default() };
        let (e, _) = project(&plain(k), "t1", &on, &Coalesce::default(), 0.0);
        assert_eq!(kinds(&e), [Kind::Notice]);
    }

    #[test]
    fn rescanned_question_emits_one_decision() {
        let (first, mut c) = run(&outcome(approval(), true, Running, Waiting, false, ""), &Coalesce::default());
        assert_eq!(decisions(&first), 1);
        let decision = first.iter().find(|row| row.kind == Kind::Decision).unwrap();
        assert_eq!(
            decision.options.as_ref().unwrap(),
            &vec!["1. Yes".to_string(), "2. No".to_string()]
        );
        for _ in 0..3 {
            let (again, next) = run(&outcome(approval(), false, Waiting, Waiting, false, ""), &c);
            assert!(again.is_empty());
            c = next;
        }
    }

    #[test]
    fn suggestion_decision_keeps_its_options_for_card_matching() {
        let options = vec!["Start the worktree".to_string(), "Not now".to_string()];
        let messages = run(
            &plain(EventKind::Suggest {
                options: options.clone(),
            }),
            &Coalesce::default(),
        )
        .0;
        let decision = messages.iter().find(|row| row.kind == Kind::Decision).unwrap();
        assert_eq!(decision.options.as_ref(), Some(&options));
    }

    #[test]
    fn notification_does_not_reopen_decision() {
        let (_, c1) = run(&outcome(approval(), true, Running, Waiting, false, ""), &Coalesce::default());
        let note = EventKind::Notification { level: "info".into(), text: "Claude needs your permission".into() };
        let (_, c2) = run(&outcome(note, false, Waiting, Waiting, false, ""), &c1);
        let (again, _) = run(&outcome(approval(), false, Waiting, Waiting, false, ""), &c2);
        assert_eq!(decisions(&again), 0);
    }

    #[test]
    fn same_question_after_tool_run_or_running_again_is_new() {
        let (_, c1) = run(&outcome(approval(), true, Running, Waiting, false, ""), &Coalesce::default());
        let (_, c2) = run(&outcome(tool("Bash", "ls"), false, Waiting, Waiting, false, ""), &c1);
        assert_eq!(decisions(&run(&outcome(approval(), false, Waiting, Waiting, false, ""), &c2).0), 1);
        let (_, c3) = run(&outcome(scan(Running), true, Waiting, Running, false, ""), &c1);
        assert_eq!(decisions(&run(&outcome(approval(), true, Running, Waiting, false, ""), &c3).0), 1);
    }

    #[test]
    fn idle_waiting_flicker_during_one_approval_is_one_decision() {
        let (mut all, mut c) = run(&outcome(approval(), true, Idle, Waiting, false, ""), &Coalesce::default());
        for _ in 0..8 {
            for (k, old, new) in [(scan(Idle), Waiting, Idle), (approval(), Idle, Waiting)] {
                let (e, next) = run(&outcome(k, true, old, new, false, ""), &c);
                all.extend(e);
                c = next;
            }
        }
        assert_eq!(decisions(&all), 1);
        assert!(!all.iter().any(|m| m.kind == Kind::Status));
    }

    #[test]
    fn only_turn_edges_are_status_rows() {
        for (old, new, want) in [
            (Idle, Running, true),
            (Running, Idle, true),
            (Running, Waiting, true),
            (Waiting, Running, true),
            (Idle, Error, true),
            (Running, Error, true),
            (Idle, Waiting, false),
            (Waiting, Idle, false),
            (Unknown, Running, false),
        ] {
            assert_eq!(is_turn_edge(old, new), want, "{old:?} → {new:?}");
        }
    }

    #[test]
    fn different_question_is_new_decision() {
        let (_, c1) = run(&outcome(approval(), true, Running, Waiting, false, ""), &Coalesce::default());
        let other = EventKind::Question {
            prompt: "Claude Code requires approval".into(),
            options: vec!["1. Yes".into(), "2. Always".into(), "3. No".into()],
            followups: vec![],
            flags: QuestionFlags::default(),
        };
        assert_eq!(decisions(&run(&outcome(other, false, Waiting, Waiting, false, ""), &c1).0), 1);
    }

    #[test]
    fn tool_alias_applied() {
        let cfg = MessageConfig { tool_aliases: BTreeMap::from([("run_terminal_cmd".to_string(), "Shell".to_string())]), ..MessageConfig::default() };
        let (e, _) = project(&plain(tool("run_terminal_cmd", "ls")), "t1", &cfg, &Coalesce::default(), 0.0);
        assert_eq!(e[0].tool.as_deref(), Some("Shell"));
    }
}
