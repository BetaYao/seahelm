//! Debounce between what one frame says and what the pane commits to.
//!
//! Ported from `DebouncedStatusTracker` in `StatusDetector.swift`. The poll is
//! coarse (2 s), so an agent can look idle for a frame in the middle of a
//! turn. A bare running → idle flip is therefore held for a few consecutive
//! observations before it commits; a frame that proves the agent finished
//! (`visible_idle`) commits at once.

use seahelm_core_types::AgentStatus;

/// One pane's committed scan status.
#[derive(Clone, Debug)]
pub struct DebouncedStatusTracker {
    current: AgentStatus,
    /// Consecutive plain-idle observations required to leave running.
    pub pending_idle_confirmations: u32,
    /// Consecutive observations required to leave running on a *defaulted*
    /// idle, one where no rule matched at all. Absence of evidence is far
    /// weaker than a matched idle rule: an agent that paused to think looks
    /// exactly like this, so the hold (~12 s at the 2 s poll) outlasts a
    /// thinking gap. Agents with hooks never wait on it; their Stop hook ends
    /// the turn directly.
    pub defaulted_idle_confirmations: u32,
    pending_idle: u32,
}

impl Default for DebouncedStatusTracker {
    fn default() -> Self {
        DebouncedStatusTracker {
            current: AgentStatus::Unknown,
            pending_idle_confirmations: 2,
            defaulted_idle_confirmations: 6,
            pending_idle: 0,
        }
    }
}

impl DebouncedStatusTracker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn current_status(&self) -> AgentStatus {
        self.current
    }

    /// Feed one observation; true when the committed status changed.
    /// `Unknown` means "no data" and changes nothing.
    ///
    /// The Swift defaults were `visible_idle: true, defaulted: false`; Rust
    /// has no default arguments, so callers spell them out.
    pub fn update(&mut self, status: AgentStatus, visible_idle: bool, defaulted: bool) -> bool {
        if status == AgentStatus::Unknown {
            return false;
        }
        if self.current == AgentStatus::Running && status == AgentStatus::Idle && (defaulted || !visible_idle) {
            self.pending_idle += 1;
            let needed = if defaulted { self.defaulted_idle_confirmations } else { self.pending_idle_confirmations };
            if self.pending_idle < needed {
                return false;
            }
        }
        self.pending_idle = 0;
        if status == self.current {
            return false;
        }
        self.current = status;
        true
    }

    pub fn force_status(&mut self, status: AgentStatus) {
        self.current = status;
        self.pending_idle = 0;
    }

    pub fn reset(&mut self) {
        self.current = AgentStatus::Unknown;
        self.pending_idle = 0;
    }
}
