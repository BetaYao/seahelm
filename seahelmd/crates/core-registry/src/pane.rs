//! One pane as the registry knows it: who it is, where it is filed, and the
//! three status components (scan, hook, OSC 7501) the arbitration combines.
//!
//! Ported from `Sources/Core/PaneInfo.swift`. The Swift struct also held the
//! pane's `Station` and its `AgentChannel`; both are app-side handles and
//! stay with the clients. `TaskProgress` is left out too: nothing in the app
//! ever wrote it (`updateTaskProgress` has no caller).

use seahelm_core_types::{
    ActivityEvent, AgentStatus, AgentType, ProgramState, TaskItem, Timestamp,
};
use serde::Serialize;

/// The snapshot of one pane. `id` is the core's pane key, the seahelmd
/// session name; `alias` is whatever id the client that registered it uses
/// (the Swift app's `Station.id` UUID), so either one finds the pane.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct PaneInfo {
    pub id: String,
    pub alias: Option<String>,
    pub worktree_path: String,
    pub agent_type: AgentType,
    pub project: String,
    pub branch: String,
    /// The arbitrated status: what the pane is doing, as edges and
    /// notifications see it.
    pub status: AgentStatus,
    /// Latest line worth showing (may be a scanned command line).
    pub last_message: String,
    /// The agent's final prose (Stop hook `last_assistant_message`). Never
    /// overwritten by screen scans, so a completion can quote the real answer
    /// instead of whatever tool line the screen last showed.
    pub last_assistant_message: String,
    pub last_user_prompt: String,
    /// When each of the two above last *changed*. A completion is announced
    /// as the answer to the prompt the pane holds, so prose recorded before
    /// the prompt landed cannot be its answer. Re-recording the same text does
    /// not move these.
    pub last_assistant_message_at: Option<Timestamp>,
    pub last_user_prompt_at: Option<Timestamp>,
    pub command_line: Option<String>,
    /// Seconds in the current running round, as the scan measures it.
    pub round_duration: f64,
    pub started_at: Option<Timestamp>,
    pub tasks: Vec<TaskItem>,
    /// Newest first, at most `ACTIVITY_LOG_SIZE`.
    pub activity_events: Vec<ActivityEvent>,
    /// The latest screen-scan observation.
    pub scan_status: AgentStatus,
    /// What the hooks have told us so far.
    pub hook_status: AgentStatus,
    /// The OSC 7501 live root record's status; decides whenever it is known.
    pub program_status: AgentStatus,
    /// The 7501 state behind `program_status`. Kept because two states map
    /// to `Idle` and mean different things: `done` finished something, `idle`
    /// is merely at rest (just started, or interrupted) and announces nothing.
    pub program_state: Option<ProgramState>,
    /// The session has background work of its own (a shell it launched, a
    /// monitor it watches). A separate axis from `status` on purpose: folding
    /// it in pinned such a pane on `Running` for the life of the monitor and
    /// cost it every completion edge.
    pub background_busy: bool,
    /// The agent finished a turn while nobody was looking, and nobody has
    /// looked since. Not a status: an unseen completion is still `Idle` to
    /// everything that reasons about the agent.
    pub unseen_completion: bool,
}

/// How many activity events a pane keeps.
pub const ACTIVITY_LOG_SIZE: usize = 20;

impl PaneInfo {
    pub fn new(
        id: String,
        alias: Option<String>,
        worktree_path: String,
        project: String,
        branch: String,
        started_at: Option<Timestamp>,
    ) -> Self {
        PaneInfo {
            id,
            alias,
            worktree_path,
            agent_type: AgentType::Unknown,
            project,
            branch,
            status: AgentStatus::Unknown,
            last_message: String::new(),
            last_assistant_message: String::new(),
            last_user_prompt: String::new(),
            last_assistant_message_at: None,
            last_user_prompt_at: None,
            command_line: None,
            round_duration: 0.0,
            started_at,
            tasks: Vec::new(),
            activity_events: Vec::new(),
            scan_status: AgentStatus::Unknown,
            hook_status: AgentStatus::Unknown,
            program_status: AgentStatus::Unknown,
            program_state: None,
            background_busy: false,
            unseen_completion: false,
        }
    }

    /// The id clients know the pane by: the alias they registered it under,
    /// else the session name. This is what the wire calls `pane_id`, so the
    /// Swift app keeps seeing its `Station.id` there.
    pub fn public_id(&self) -> &str {
        self.alias.as_deref().unwrap_or(&self.id)
    }

    /// What the dashboard draws. Background work still reads as busy (a
    /// worktree watching CI is not "done") while `status` stays the honest
    /// answer that edges and notifications ride on.
    pub fn display_status(&self) -> AgentStatus {
        display_status(self.status, self.background_busy)
    }

    /// Seconds since `started_at`, or 0 without one.
    pub fn total_duration(&self, now: Timestamp) -> f64 {
        self.started_at.map(|s| now - s).unwrap_or(0.0)
    }

    /// A copy re-attributed to another worktree, keeping every live field.
    /// A move must not look like a freshly opened pane: it exists to preserve
    /// exactly the agent state a re-registration would throw away.
    pub fn rehomed(&self, worktree_path: &str, branch: &str, project: &str) -> PaneInfo {
        PaneInfo {
            worktree_path: worktree_path.to_string(),
            branch: branch.to_string(),
            project: project.to_string(),
            ..self.clone()
        }
    }
}

/// The one place the two axes are recombined, shared by `PaneInfo` and the
/// rollup's `PaneStatus` so the card and the dots can never disagree.
pub fn display_status(status: AgentStatus, background_busy: bool) -> AgentStatus {
    if status == AgentStatus::Idle && background_busy {
        AgentStatus::Running
    } else {
        status
    }
}

/// What a client tells the registry about a pane it lays out.
#[derive(Clone, Debug, PartialEq)]
pub struct Registration {
    /// The seahelmd session name.
    pub pane: String,
    /// The client's own id for the pane, if it has one.
    pub alias: Option<String>,
    pub worktree_path: String,
    pub project: String,
    pub branch: String,
    /// What the client already knows runs there; `Unknown` lets the scan and
    /// hooks decide.
    pub agent_type: AgentType,
    pub started_at: Option<Timestamp>,
}

/// Insert at the front, cap at `max` (`AgentRegistry.appendToRingBuffer`).
pub fn append_to_ring_buffer(buffer: &mut Vec<ActivityEvent>, event: ActivityEvent, max: usize) {
    buffer.insert(0, event);
    buffer.truncate(max);
}

/// Replace the newest event when it is the same tool call seen again (a
/// start followed by its end), else push a new one (`upsertLatest`).
pub fn upsert_latest(buffer: &mut Vec<ActivityEvent>, event: ActivityEvent, max: usize) {
    match buffer.first_mut() {
        Some(latest) if latest.tool == event.tool && latest.detail == event.detail => {
            *latest = event
        }
        _ => append_to_ring_buffer(buffer, event, max),
    }
}
