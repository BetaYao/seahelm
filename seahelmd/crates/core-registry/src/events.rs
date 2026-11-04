//! The event stream subscribers read: a bounded ring keyed by the registry's
//! monotonic sequence, so a client that reconnects can replay what it missed
//! with `events_after`.
//!
//! Ported from `Sources/Core/EventHub.swift`. The Swift hub also pushed to
//! subscriber closures; here the owner (the core's RPC server) polls
//! `events_after` with the last seq it sent, which keeps this crate free of
//! callbacks and threads. Event JSON is shaped exactly as `AgentRegistry`
//! published it, field for field, so a client cannot tell the two apart.

use std::collections::VecDeque;

use serde_json::{json, Map, Value};

use crate::pane::PaneInfo;
use crate::registry::Outcome;
use seahelm_core_types::EventKind;

/// How many events the ring keeps.
pub const RING_CAPACITY: usize = 500;

#[derive(Debug, Default)]
pub struct EventHub {
    ring: VecDeque<(u64, Value)>,
}

impl EventHub {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record an event stamped with its sequence; the oldest falls off past
    /// `RING_CAPACITY`.
    pub fn publish(&mut self, seq: u64, event: Value) {
        self.ring.push_back((seq, event));
        while self.ring.len() > RING_CAPACITY {
            self.ring.pop_front();
        }
    }

    /// Buffered events with seq strictly greater than `seq`, oldest first.
    pub fn events_after(&self, seq: u64) -> Vec<Value> {
        self.ring
            .iter()
            .filter(|(s, _)| *s > seq)
            .map(|(_, e)| e.clone())
            .collect()
    }

    /// Same, with each event's seq beside it.
    pub fn entries_after(&self, seq: u64) -> Vec<(u64, Value)> {
        self.ring
            .iter()
            .filter(|(s, _)| *s > seq)
            .cloned()
            .collect()
    }

    /// The seq of the newest buffered event, 0 when empty.
    pub fn current_seq(&self) -> u64 {
        self.ring.back().map(|(s, _)| *s).unwrap_or(0)
    }

    pub fn len(&self) -> usize {
        self.ring.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ring.is_empty()
    }
}

/// Everything a client draws for a pane: `pane.list {detail: true}` adds
/// it to each pane, and `pane.status_changed` / `pane.updated` carry it as
/// `info`, so one event is enough to redraw a row.
pub fn pane_detail(p: &PaneInfo) -> Value {
    json!({
        "status": p.status.as_str(),
        "display_status": p.display_status().as_str(),
        "agent_type": agent_type_str(p.agent_type),
        "last_message": p.last_message,
        "last_assistant_message": p.last_assistant_message,
        "last_assistant_message_at": p.last_assistant_message_at,
        "last_user_prompt": p.last_user_prompt,
        "last_user_prompt_at": p.last_user_prompt_at,
        "command_line": p.command_line,
        "round_duration": p.round_duration,
        "started_at": p.started_at,
        "tasks": p.tasks,
        "activity_events": p.activity_events,
        "scan_status": p.scan_status.as_str(),
        "hook_status": p.hook_status.as_str(),
        "program_status": p.program_status.as_str(),
        "program_state": p.program_state.map(|s| format!("{s:?}").to_lowercase()),
        "background_busy": p.background_busy,
        "unseen": p.unseen_completion,
    })
}

/// The fields every pane event starts with.
fn base(kind: &str, seq: u64, pane: &PaneInfo) -> Map<String, Value> {
    let mut m = Map::new();
    m.insert("type".into(), kind.into());
    m.insert("seq".into(), seq.into());
    m.insert("pane_id".into(), pane.public_id().into());
    m.insert("pane_session_key".into(), pane.id.clone().into());
    m.insert("worktree_path".into(), pane.worktree_path.clone().into());
    m
}

/// `pane.status_changed` / `pane.updated` for one ingest outcome
/// (`AgentRegistry.event(from:)`).
pub fn outcome_event(o: &Outcome) -> Value {
    let kind = if o.status_changed {
        "pane.status_changed"
    } else {
        "pane.updated"
    };
    let mut d = base(kind, o.seq, &o.info);
    d.insert("status".into(), o.new_status.as_str().into());
    d.insert("old_status".into(), o.old_status.as_str().into());
    d.insert(
        "agent_type".into(),
        agent_type_str(o.info.agent_type).into(),
    );
    d.insert("last_message".into(), o.info.last_message.clone().into());
    d.insert("info".into(), pane_detail(&o.info));
    // Only a completion carries the agent's real final prose; gating on the
    // flag stops unrelated events re-sending stale prose left on the snapshot.
    if o.is_completion_signal {
        d.insert("is_completion".into(), true.into());
        let fin = o.info.last_assistant_message.trim();
        if !fin.is_empty() {
            d.insert("final_message".into(), fin.into());
        }
    }
    match &o.event.kind {
        // What the user typed, so remote history shows both sides.
        EventKind::UserPrompt { text } => {
            if let Some(shown) = human_prompt_text(text) {
                d.insert("user_prompt".into(), shown.into());
            }
        }
        // Open decisions, so remote clients can show and answer them.
        EventKind::Question {
            prompt,
            options,
            flags,
            ..
        } => {
            let mut q = Map::new();
            q.insert("prompt".into(), prompt.clone().into());
            q.insert("options".into(), json!(options));
            if flags.multi_select {
                q.insert("multi_select".into(), true.into());
            }
            d.insert("question".into(), Value::Object(q));
        }
        // The exception to the completion gate: the options were written
        // inside this very message, so the prose is what they answer.
        EventKind::Suggest { options } => {
            let mut p = Map::new();
            p.insert("options".into(), json!(options));
            let prose = o.info.last_assistant_message.trim();
            if !prose.is_empty() {
                p.insert("message".into(), prose.into());
            }
            d.insert("suggest".into(), Value::Object(p));
        }
        _ => {}
    }
    Value::Object(d)
}

/// `pane.closed`: lets remote mirrors drop the pane instead of keeping a ghost.
pub fn closed_event(seq: u64, pane: &PaneInfo) -> Value {
    Value::Object(base("pane.closed", seq, pane))
}

/// `pane.rehomed`: `pane` is already filed under its new worktree.
pub fn rehomed_event(seq: u64, pane: &PaneInfo, old_worktree_path: &str) -> Value {
    let mut d = base("pane.rehomed", seq, pane);
    d.insert("old_worktree_path".into(), old_worktree_path.into());
    Value::Object(d)
}

/// `pane.unseen_changed`: moves a remote row without waiting for a status edge.
pub fn unseen_event(seq: u64, pane: &PaneInfo) -> Value {
    let mut d = base("pane.unseen_changed", seq, pane);
    d.insert("unseen".into(), pane.unseen_completion.into());
    Value::Object(d)
}

/// An agent type's wire name (`claudeCode`), as the Swift raw value.
pub(crate) fn agent_type_str(t: seahelm_core_types::AgentType) -> String {
    match serde_json::to_value(t) {
        Ok(Value::String(s)) => s,
        _ => "unknown".into(),
    }
}

/// Blocks the harness writes into a turn on its own account.
const MACHINE_BLOCKS: [&str; 2] = ["task-notification", "system-reminder"];

/// What a human should be shown for a submitted prompt, or None when the
/// turn was not a person speaking (`UserPromptText.humanText`). A prompt is
/// machine plumbing only when it is *entirely* one such block; Claude Code's
/// `<pasted_content …>` wrapper is taken off, since every reader here is a
/// person to whom it is noise around their own words.
///
/// Duplicated from the hooks side (which owns the type in Swift) because the
/// registry shapes the event and the crates do not depend on each other.
pub fn human_prompt_text(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let machine = MACHINE_BLOCKS.iter().any(|tag| {
        trimmed.starts_with(&format!("<{tag}>")) && trimmed.ends_with(&format!("</{tag}>"))
    });
    if machine {
        return None;
    }
    let unwrapped = unwrap_pasted_content(trimmed);
    (!unwrapped.is_empty()).then_some(unwrapped)
}

/// Remove `<pasted_content…>` and `</pasted_content…>` tags (the closing tag
/// repeats the attribute, which no markup parser accepts, so this matches the
/// shape Claude Code writes), then fold the blank lines they leave behind.
fn unwrap_pasted_content(text: &str) -> String {
    if !text.contains("<pasted_content") {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    loop {
        let open = rest.find("<pasted_content");
        let close = rest.find("</pasted_content");
        let at = match (open, close) {
            (Some(a), Some(b)) => a.min(b),
            (Some(a), None) | (None, Some(a)) => a,
            (None, None) => break,
        };
        out.push_str(&rest[..at]);
        match rest[at..].find('>') {
            Some(end) => rest = &rest[at + end + 1..],
            None => {
                // An unterminated tag: `[^>]*>` would not match, so keep it.
                out.push_str(&rest[at..]);
                rest = "";
                break;
            }
        }
    }
    out.push_str(rest);
    // `\n{3,}` → `\n\n`.
    let mut folded = String::with_capacity(out.len());
    let mut run = 0;
    for c in out.chars() {
        if c == '\n' {
            run += 1;
            if run <= 2 {
                folded.push(c);
            }
        } else {
            run = 0;
            folded.push(c);
        }
    }
    folded.trim().to_string()
}
