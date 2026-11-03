//! When a pane's finished turn becomes "unseen", and when it stops being.
//!
//! Ported from `Sources/Core/UnseenCompletion.swift`. What counts as
//! *looking* is the client's to say (`client.visible`, `pane.seen`); the
//! registry applies it (`Registry::mark_worktree_seen`, `mark_pane_seen`,
//! `settle_unseen`) and `notify::completion_step` decides the marking.

use seahelm_core_types::AgentStatus;

/// The "group by status" heading for idle rows with an unread finish.
pub const GROUP_TITLE: &str = "Finished";

/// A turn ending: the agent was working and is now at rest. Answering a
/// question (`Waiting → Idle`) is not one.
pub fn marks(old: AgentStatus, new: AgentStatus) -> bool {
    old == AgentStatus::Running && new == AgentStatus::Idle
}

/// Anything the agent does next supersedes the unread result: it works
/// again, wants something (which says so louder), or is gone. A pane the
/// scan lost sight of (`Unknown`) has not been read.
pub fn clears(new: AgentStatus) -> bool {
    match new {
        AgentStatus::Running | AgentStatus::Waiting | AgentStatus::Error | AgentStatus::Exited => {
            true
        }
        AgentStatus::Idle | AgentStatus::Unknown => false,
    }
}
