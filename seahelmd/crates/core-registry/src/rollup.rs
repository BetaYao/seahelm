//! A worktree's status out of its panes', and when the worktree last did
//! something.
//!
//! Ported from `Sources/Status/WorktreeStatusAggregator.swift` and
//! `PaneStatus.swift`. Two rules coexist on purpose, for parity with the
//! app (docs/status-core-port.md, decision 2):
//! - **recency** (`WorktreeStatus::rolled_up_status`): the pane that changed
//!   status most recently speaks for the worktree, status and message both,
//!   so the row dot and its text describe the same pane;
//! - **priority** (`grouping_status`): the most urgent pane, which is what
//!   "group by status" files the row under.
//!
//! Fixed in the port: the Swift rebuild re-created each `PaneStatus`
//! without `backgroundBusy`, so the flag was lost on the first rebuild and a
//! worktree watching CI rolled up as idle.

use std::collections::HashMap;

use seahelm_core_types::{AgentStatus, AgentType, Timestamp};
use serde::Serialize;

use crate::pane::{display_status, PaneInfo};

/// One pane's contribution to its worktree's rollup.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct PaneStatus {
    /// 1-based, in the split tree's leaf order.
    pub pane_index: usize,
    pub pane: String,
    pub status: AgentStatus,
    pub last_message: String,
    pub last_user_prompt: String,
    /// When status or message last changed.
    pub last_updated: Timestamp,
    /// When `status` last changed, not moved by message-only updates: a pane
    /// merely printing output must not take the badge from one that just
    /// went waiting.
    pub status_changed_at: Timestamp,
    pub agent_type: AgentType,
    /// Carried beside `status`, never folded into it: the pane edge that
    /// notifications ride on must keep seeing the agent's own state.
    pub background_busy: bool,
}

impl PaneStatus {
    /// What the dashboard draws for this pane; mirrors `PaneInfo::display_status`.
    pub fn display_status(&self) -> AgentStatus {
        display_status(self.status, self.background_busy)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct WorktreeStatus {
    pub worktree_path: String,
    /// In leaf order.
    pub panes: Vec<PaneStatus>,
    /// The representative pane, whose message is shown.
    pub most_recent_pane_index: usize,
    pub most_recent_message: String,
    pub most_recent_user_prompt: String,
}

impl WorktreeStatus {
    pub fn statuses(&self) -> Vec<AgentStatus> {
        self.panes.iter().map(|p| p.status).collect()
    }

    /// Any pane urgent, whichever pane owns the badge.
    pub fn has_urgent(&self) -> bool {
        self.panes.iter().any(|p| p.status.is_urgent())
    }

    /// The pane that changed status most recently. Ties go to the earlier
    /// leaf, as Swift's `max(by:)` resolves them.
    pub fn representative(&self) -> Option<&PaneStatus> {
        most_recent(&self.panes)
    }

    /// The recency rule: the representative's display status.
    pub fn rolled_up_status(&self) -> AgentStatus {
        self.representative()
            .map(|p| p.display_status())
            .unwrap_or(AgentStatus::Unknown)
    }

    /// The priority rule, over the panes' display statuses.
    pub fn grouping_status(&self) -> AgentStatus {
        AgentStatus::highest_priority(self.panes.iter().map(|p| p.display_status()))
    }
}

/// The priority rule straight from the registry's panes, which is how the
/// app computed a row's grouping status (`AgentStatus.highestPriority` over
/// every pane's `displayStatus`).
pub fn grouping_status<'a>(panes: impl IntoIterator<Item = &'a PaneInfo>) -> AgentStatus {
    AgentStatus::highest_priority(panes.into_iter().map(|p| p.display_status()))
}

fn most_recent(panes: &[PaneStatus]) -> Option<&PaneStatus> {
    let mut best: Option<&PaneStatus> = None;
    for p in panes {
        if best.is_none_or(|b| b.status_changed_at < p.status_changed_at) {
            best = Some(p);
        }
    }
    best
}

/// A pane's status moved: the edge notifications are decided from.
#[derive(Clone, Debug, PartialEq)]
pub struct PaneStatusChange {
    pub worktree_path: String,
    pub pane: String,
    pub pane_index: usize,
    pub old_status: AgentStatus,
    pub new_status: AgentStatus,
    pub last_message: String,
}

/// What one pane update changed.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Update {
    /// Set when a pane seen before changed status.
    pub pane_change: Option<PaneStatusChange>,
    /// Set when the worktree's rollup changed in anything visible.
    pub worktree: Option<WorktreeStatus>,
    /// Set when the worktree's last-activity time advanced (to persist it).
    pub activity: Option<(String, Timestamp)>,
}

/// What the aggregator is told about a pane: the parts of an outcome a
/// rollup reads.
#[derive(Clone, Debug, PartialEq)]
pub struct PaneUpdate {
    pub status: AgentStatus,
    pub last_message: String,
    pub last_user_prompt: String,
    pub agent_type: AgentType,
    pub background_busy: bool,
}

impl PaneUpdate {
    /// From the registry's pane after an outcome (`TabCoordinator` fed the
    /// aggregator exactly these fields).
    pub fn from_pane(p: &PaneInfo) -> Self {
        PaneUpdate {
            status: p.status,
            last_message: p.last_message.clone(),
            last_user_prompt: p.last_user_prompt.clone(),
            agent_type: p.agent_type,
            background_busy: p.background_busy,
        }
    }
}

#[derive(Debug, Default)]
pub struct Aggregator {
    statuses: HashMap<String, WorktreeStatus>,
    pane_states: HashMap<String, PaneStatus>,
    pane_worktree: HashMap<String, String>,
    /// Worktree → panes, in leaf order.
    worktree_panes: HashMap<String, Vec<String>>,
    /// Per worktree, the last real activity. Seeded from persisted state so
    /// it does not reset to launch time.
    last_activity: HashMap<String, Timestamp>,
}

impl Aggregator {
    pub fn new() -> Self {
        Self::default()
    }

    /// Seed persisted last-activity times; entries already known win.
    pub fn seed_last_activity(&mut self, map: &HashMap<String, Timestamp>) {
        for (path, at) in map {
            self.last_activity.entry(path.clone()).or_insert(*at);
        }
    }

    pub fn last_activity(&self, worktree: &str) -> Option<Timestamp> {
        self.last_activity.get(worktree).copied()
    }

    /// File a pane at a leaf position (0-based).
    pub fn register_pane(&mut self, pane: &str, worktree: &str, leaf_index: usize) {
        self.pane_worktree
            .insert(pane.to_string(), worktree.to_string());
        let ids = self.worktree_panes.entry(worktree.to_string()).or_default();
        if !ids.iter().any(|p| p == pane) {
            if leaf_index < ids.len() {
                ids.insert(leaf_index, pane.to_string());
            } else {
                ids.push(pane.to_string());
            }
        }
    }

    pub fn unregister_pane(&mut self, pane: &str, worktree: &str) {
        self.pane_worktree.remove(pane);
        self.pane_states.remove(pane);
        if let Some(ids) = self.worktree_panes.get_mut(worktree) {
            ids.retain(|p| p != pane);
            if ids.is_empty() {
                self.worktree_panes.remove(worktree);
                self.statuses.remove(worktree);
                self.last_activity.remove(worktree);
            }
        }
    }

    /// The split tree's leaves changed order. Returns the rollup if it changed.
    pub fn update_leaf_order(
        &mut self,
        worktree: &str,
        panes: Vec<String>,
    ) -> Option<WorktreeStatus> {
        self.worktree_panes.insert(worktree.to_string(), panes);
        self.rebuild(worktree)
    }

    /// Fold one pane's latest state in. Nothing happens unless status,
    /// message, prompt or background work changed.
    pub fn update(&mut self, pane: &str, u: PaneUpdate, now: Timestamp) -> Update {
        let mut out = Update::default();
        let Some(worktree) = self.pane_worktree.get(pane).cloned() else {
            return out;
        };
        let old = self.pane_states.get(pane).cloned();
        let status_changed = old.as_ref().map(|o| o.status) != Some(u.status);
        let background_changed = old.as_ref().map(|o| o.background_busy) != Some(u.background_busy);
        let message_changed =
            old.as_ref().map(|o| o.last_message.as_str()) != Some(u.last_message.as_str());
        let prompt_changed =
            old.as_ref().map(|o| o.last_user_prompt.as_str()) != Some(u.last_user_prompt.as_str());
        if !(status_changed || message_changed || prompt_changed || background_changed) {
            return out;
        }

        // A first-ever sighting of a pane is launch/restore noise: keep a
        // persisted time, stamping now only when there is no history at all.
        if old.is_some() || !self.last_activity.contains_key(&worktree) {
            self.last_activity.insert(worktree.clone(), now);
            out.activity = Some((worktree.clone(), now));
        }

        let pane_index = self.pane_index(pane, &worktree);
        let prompt = if u.last_user_prompt.is_empty() {
            old.as_ref()
                .map(|o| o.last_user_prompt.clone())
                .unwrap_or_default()
        } else {
            u.last_user_prompt
        };
        let agent_type = if u.agent_type == AgentType::Unknown {
            old.as_ref()
                .map(|o| o.agent_type)
                .unwrap_or(AgentType::Unknown)
        } else {
            u.agent_type
        };
        let status_changed_at = if status_changed {
            now
        } else {
            old.as_ref().map(|o| o.status_changed_at).unwrap_or(now)
        };
        self.pane_states.insert(
            pane.to_string(),
            PaneStatus {
                pane_index,
                pane: pane.to_string(),
                status: u.status,
                last_message: u.last_message.clone(),
                last_user_prompt: prompt,
                last_updated: now,
                status_changed_at,
                agent_type,
                background_busy: u.background_busy,
            },
        );

        if status_changed {
            if let Some(old) = &old {
                out.pane_change = Some(PaneStatusChange {
                    worktree_path: worktree.clone(),
                    pane: pane.to_string(),
                    pane_index,
                    old_status: old.status,
                    new_status: u.status,
                    last_message: u.last_message,
                });
            }
        }
        out.worktree = self.rebuild(&worktree);
        out
    }

    pub fn status(&self, worktree: &str) -> Option<&WorktreeStatus> {
        self.statuses.get(worktree)
    }

    fn pane_index(&self, pane: &str, worktree: &str) -> usize {
        self.worktree_panes
            .get(worktree)
            .and_then(|ids| ids.iter().position(|p| p == pane))
            .unwrap_or(0)
            + 1
    }

    /// Re-number the panes in leaf order and recompute the rollup. Returns it
    /// only when something visible changed.
    fn rebuild(&mut self, worktree: &str) -> Option<WorktreeStatus> {
        let ids = self.worktree_panes.get(worktree)?.clone();
        let mut panes = Vec::new();
        for (i, id) in ids.iter().enumerate() {
            if let Some(p) = self.pane_states.get_mut(id) {
                p.pane_index = i + 1;
                panes.push(p.clone());
            }
        }
        let rep = most_recent(&panes)?.clone();
        let ws = WorktreeStatus {
            worktree_path: worktree.to_string(),
            panes,
            most_recent_pane_index: rep.pane_index,
            most_recent_message: rep.last_message,
            most_recent_user_prompt: rep.last_user_prompt,
        };
        if self.statuses.get(worktree) == Some(&ws) {
            return None;
        }
        self.statuses.insert(worktree.to_string(), ws.clone());
        Some(ws)
    }
}
