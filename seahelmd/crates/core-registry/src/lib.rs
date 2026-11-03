//! The agent state model of seahelm-core: every pane, the arbitration that
//! turns what the screen shows, what the hooks said and what the program
//! reports into one status, the timers at the edges of a turn, unseen
//! completions, worktree rollups, the notification decision, and the event
//! ring subscribers replay from.
//!
//! Ported from the Swift app (`AgentRegistry`, `PaneInfo`,
//! `UnseenCompletion`, `WorktreeStatusAggregator`, `PaneStatus`, `EventHub`,
//! the decision half of `NotificationManager`, and the completion logic of
//! `TabCoordinator`). Pure: no threads, timers or globals; every timing rule
//! takes `now`, and the manifest authority comes in as an argument because
//! the scan crate owns manifests. See docs/core-crates.md for the contract.

pub mod events;
pub mod notify;
pub mod pane;
pub mod registry;
pub mod rollup;
pub mod unseen;

pub use events::EventHub;
pub use pane::{PaneInfo, Registration};
pub use registry::{
    arbitrate, arbitrate_detailed, DecidedBy, Graces, HookInput, HookResult, Outcome, Registry,
};
