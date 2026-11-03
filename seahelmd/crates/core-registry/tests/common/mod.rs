//! Shared fixtures for the ported Swift tests. The Swift tests drove the
//! `AgentRegistry.shared` singleton through `DispatchQueue.main`; here each
//! test owns a `Registry`, outcomes come back from `ingest`, and time is an
//! explicit `now` the test advances.
#![allow(dead_code)]

use seahelm_core_registry::{Outcome, Registration, Registry};
use seahelm_core_types::{
    ActivityEvent, AgentStatus, AgentType, Authority, EventKind, EventSource, NormalizedEvent,
    TaskItem, Timestamp,
};

pub const T0: Timestamp = 1_000_000.0;

/// The bundled manifests' authorities (Resources/Manifests/*.json): the
/// agents with real lifecycle hooks are `session_only`, the rest — and the
/// generic "agent" manifest an unknown pane falls back to — `screen_only`.
pub fn authority_of(t: AgentType) -> Authority {
    match t {
        AgentType::ClaudeCode | AgentType::Codex | AgentType::Cursor | AgentType::Pi => {
            Authority::SessionOnly
        }
        _ => Authority::ScreenOnly,
    }
}

pub fn register(r: &mut Registry, pane: &str, worktree: &str) {
    register_full(r, pane, worktree, "main", "proj", None);
}

pub fn register_full(
    r: &mut Registry,
    pane: &str,
    worktree: &str,
    branch: &str,
    project: &str,
    started: Option<f64>,
) {
    r.register(Registration {
        pane: pane.into(),
        alias: None,
        worktree_path: worktree.into(),
        project: project.into(),
        branch: branch.into(),
        agent_type: AgentType::Unknown,
        started_at: started,
    });
}

pub fn ingest(
    r: &mut Registry,
    pane: &str,
    source: EventSource,
    kind: EventKind,
    now: Timestamp,
) -> Option<Outcome> {
    r.ingest_with(
        NormalizedEvent {
            pane: pane.into(),
            source,
            kind,
        },
        &authority_of,
        now,
    )
}

pub fn hook(r: &mut Registry, pane: &str, kind: EventKind, now: Timestamp) -> Option<Outcome> {
    ingest(r, pane, EventSource::Hook("claude-code".into()), kind, now)
}

pub fn screen(status: AgentStatus, agent: AgentType) -> EventKind {
    screen_full(status, "", agent, 0.0, vec![])
}

pub fn screen_full(
    status: AgentStatus,
    message: &str,
    agent: AgentType,
    round: f64,
    tasks: Vec<TaskItem>,
) -> EventKind {
    EventKind::ScreenObserved {
        status,
        message: message.into(),
        activity: vec![],
        command_line: None,
        agent_type: agent,
        round_duration: round,
        tasks,
        background_busy: false,
    }
}

pub fn scan(
    r: &mut Registry,
    pane: &str,
    status: AgentStatus,
    agent: AgentType,
    now: Timestamp,
) -> Option<Outcome> {
    ingest(r, pane, EventSource::Scan, screen(status, agent), now)
}

pub fn prompt(text: &str) -> EventKind {
    EventKind::UserPrompt { text: text.into() }
}

pub fn stop(success: bool) -> EventKind {
    EventKind::AgentStopped { success }
}

pub fn question(prompt: &str, options: &[&str]) -> EventKind {
    EventKind::Question {
        prompt: prompt.into(),
        options: options.iter().map(|s| s.to_string()).collect(),
        followups: vec![],
        flags: Default::default(),
    }
}

pub fn tool(tool: &str, detail: &str, is_error: bool, now: Timestamp) -> EventKind {
    EventKind::ToolUse {
        activity: activity(tool, detail, is_error, now),
    }
}

pub fn activity(tool: &str, detail: &str, is_error: bool, now: Timestamp) -> ActivityEvent {
    ActivityEvent {
        tool: tool.into(),
        detail: detail.into(),
        is_error,
        timestamp: now,
    }
}

pub fn status(r: &Registry, pane: &str) -> AgentStatus {
    r.pane(pane).map(|p| p.status).unwrap_or_default()
}
