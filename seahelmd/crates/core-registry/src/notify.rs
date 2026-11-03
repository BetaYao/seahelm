//! Whether a pane's status change is worth telling the user about, and
//! whether a finished turn counts as unread. Decisions only: clients deliver
//! (UserNotifications, a toast, libnotify) and format.
//!
//! Ported from the decision half of `Sources/Status/NotificationManager.swift`
//! (`shouldNotify`, the turn fingerprint, the cooldown and its agent-over-scan
//! override, the 1 s stability gate) and from the completion logic of
//! `TabCoordinator.deliverPaneStatusChange` / `deliverAgentCompletion` that
//! decides, before any of that, whether to wait for the agent's own Stop,
//! drop an at-rest 7501 idle, or mark the pane unseen. The Swift timers
//! become deadlines: `NotificationPolicy::notify` returns `Hold`, and the
//! owner calls `due(now)` once the time has come; `completion_step` returns
//! `Retry` and the owner asks again after `after` seconds.

use std::collections::HashMap;

use seahelm_core_types::{AgentStatus, ProgramState, Timestamp};
use serde::Serialize;

use crate::pane::PaneInfo;
use crate::registry::Outcome;
use crate::unseen;

/// Who reported a change. The agent reporting its own stop is worth more
/// than the scan inferring one: the scan cannot tell a thinking pause from a
/// finished turn, so an agent-reported completion may correct a scan-derived
/// notice inside the cooldown window.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    Scan,
    Agent,
}

/// What was last announced for a key.
#[derive(Clone, Debug, PartialEq)]
pub struct Delivery {
    pub at: Timestamp,
    pub source: Source,
    /// The turn announced (see `turn_fingerprint`).
    pub turn: String,
}

/// The eligibility gate: only a `Running → Waiting | Error | Idle` edge, a
/// turn not already announced, and not within the cooldown of the last
/// notice for the key, unless an agent report overtakes a scan one.
///
/// A turn is announced at most once. A finished pane keeps moving (Claude
/// compacts, a shell it left paints) and each settle makes another
/// `Running → Idle` edge out of the *same* completion, minutes later and past
/// any cooldown. Identity, not timing, tells them apart. An empty
/// fingerprint identifies nothing, so it never matches itself.
pub fn should_notify(
    old: AgentStatus,
    new: AgentStatus,
    source: Source,
    turn: &str,
    last: Option<&Delivery>,
    cooldown: f64,
    now: Timestamp,
) -> bool {
    if old != AgentStatus::Running {
        return false;
    }
    if !matches!(
        new,
        AgentStatus::Waiting | AgentStatus::Error | AgentStatus::Idle
    ) {
        return false;
    }
    let Some(last) = last else { return true };
    if !turn.is_empty() && turn == last.turn {
        return false;
    }
    if now - last.at < cooldown {
        return source == Source::Agent && last.source == Source::Scan;
    }
    true
}

/// Identifies the turn a notice is about: its outcome plus the words it
/// would show. Two edges carrying the same answer to the same prompt are the
/// same completion seen twice.
pub fn turn_fingerprint(
    status: AgentStatus,
    last_assistant_message: &str,
    last_message: &str,
    last_user_prompt: &str,
) -> String {
    let body = if last_assistant_message.is_empty() {
        last_message
    } else {
        last_assistant_message
    };
    let body = body.trim();
    if body.is_empty() {
        return String::new();
    }
    format!("{}|{}|{}", status.as_str(), last_user_prompt.trim(), body)
}

/// Whether the agent's prose can be the answer to the prompt the pane
/// holds. When an order lands and the agent has not spoken since, its prose
/// answers the *previous* order; quoting it under the new one is out of
/// order, and the new prompt made a new fingerprint out of old words. Only
/// the agent's own prose is held to this; a pane with none (anything read
/// off the screen) has nothing to be out of order with.
pub fn answers_current_prompt(
    last_assistant_message: &str,
    assistant_at: Option<Timestamp>,
    prompt_at: Option<Timestamp>,
) -> bool {
    match (
        last_assistant_message.trim().is_empty(),
        assistant_at,
        prompt_at,
    ) {
        (false, Some(a), Some(p)) => a >= p,
        _ => true,
    }
}

/// Whether a held notice still fires: only if the status it was about is
/// still the latest one seen for its key.
pub fn should_deliver_pending(target: AgentStatus, latest: Option<AgentStatus>) -> bool {
    latest == Some(target)
}

/// Whether a notice waits out the stability delay. The gate exists for the
/// scan, which reads a thinking pause as a finished turn and needs a moment
/// to take it back. An agent that reported the end itself has nothing to
/// take back (`Running` a moment later is the *next* turn), and holding it
/// lost the answer whenever the next turn came quickly. Worktree-level
/// notices (no pane) have no status stream to cancel against.
pub fn uses_stability_gate(stability_delay: f64, pane: &str, agent_reported_end: bool) -> bool {
    stability_delay > 0.0 && !pane.is_empty() && !agent_reported_end
}

/// Whether a banner would only repeat what the user is looking at: the pane
/// on screen, or an expanded card for it, and only while the app is in
/// front. A client applies this; the core reports `is_target_visible`.
pub fn should_suppress_banner(
    app_active: bool,
    target_visible: bool,
    card_on_screen: bool,
) -> bool {
    app_active && (target_visible || card_on_screen)
}

/// The cooldown key: per pane when there is one, else per worktree;
/// namespaced so the two can never alias.
pub fn cooldown_key(pane: &str, worktree_path: &str) -> String {
    if pane.is_empty() {
        format!("wt:{worktree_path}")
    } else {
        format!("tid:{pane}")
    }
}

/// Agent when the hooks already say the status the edge arrived at.
pub fn source_for(hook_status: AgentStatus, new_status: AgentStatus) -> Source {
    if hook_status == new_status {
        Source::Agent
    } else {
        Source::Scan
    }
}

/// Everything a notice needs, gathered by the caller at the edge.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct NotifyRequest {
    pub worktree_path: String,
    /// "" for worktree-level callers.
    pub pane: String,
    pub pane_index: usize,
    pub pane_count: usize,
    pub old_status: AgentStatus,
    pub new_status: AgentStatus,
    pub last_message: String,
    pub last_user_prompt: String,
    pub last_assistant_message: String,
    pub last_assistant_message_at: Option<Timestamp>,
    pub last_user_prompt_at: Option<Timestamp>,
    /// The pane is the one on screen (a client may suppress its banner).
    pub is_target_visible: bool,
    pub source: Source,
    pub agent_reported_end: bool,
}

impl NotifyRequest {
    /// A request for one pane's edge, its words taken from the registry.
    #[allow(clippy::too_many_arguments)]
    pub fn for_pane(
        pane: &PaneInfo,
        old_status: AgentStatus,
        new_status: AgentStatus,
        last_message: &str,
        pane_index: usize,
        pane_count: usize,
        is_target_visible: bool,
        agent_reported_end: bool,
    ) -> Self {
        NotifyRequest {
            worktree_path: pane.worktree_path.clone(),
            pane: pane.id.clone(),
            pane_index,
            pane_count,
            old_status,
            new_status,
            last_message: last_message.to_string(),
            last_user_prompt: pane.last_user_prompt.clone(),
            last_assistant_message: pane.last_assistant_message.clone(),
            last_assistant_message_at: pane.last_assistant_message_at,
            last_user_prompt_at: pane.last_user_prompt_at,
            is_target_visible,
            source: source_for(pane.hook_status, new_status),
            agent_reported_end,
        }
    }
}

/// A notice to deliver now.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Notice {
    pub key: String,
    pub turn: String,
    #[serde(flatten)]
    pub request: NotifyRequest,
}

/// What `notify` decided.
#[derive(Clone, Debug, PartialEq)]
pub enum Decision {
    Drop,
    Deliver(Notice),
    /// Held by the stability gate; `due(until)` delivers it if the status
    /// still holds then.
    Hold {
        key: String,
        until: Timestamp,
    },
}

/// The stateful half: last deliveries, latest status per key, held notices.
#[derive(Debug)]
pub struct NotificationPolicy {
    /// Minimum seconds between notices for one key.
    pub cooldown: f64,
    /// How long a scan edge is held before it counts; 0 disables the gate.
    pub stability_delay: f64,
    last_notified: HashMap<String, Delivery>,
    latest_status: HashMap<String, AgentStatus>,
    pending: HashMap<String, (Timestamp, Notice)>,
}

impl Default for NotificationPolicy {
    fn default() -> Self {
        NotificationPolicy {
            cooldown: 30.0,
            stability_delay: 1.0,
            last_notified: HashMap::new(),
            latest_status: HashMap::new(),
            pending: HashMap::new(),
        }
    }
}

impl NotificationPolicy {
    pub fn new() -> Self {
        Self::default()
    }

    /// The eligibility check for a key, against what was delivered there.
    /// Pure: the cooldown is consumed only by a delivery, so a notice the
    /// stability gate drops does not burn it.
    pub fn should_notify(
        &self,
        key: &str,
        old: AgentStatus,
        new: AgentStatus,
        source: Source,
        turn: &str,
        now: Timestamp,
    ) -> bool {
        should_notify(
            old,
            new,
            source,
            turn,
            self.last_notified.get(key),
            self.cooldown,
            now,
        )
    }

    /// The single entry point (`NotificationManager.notify`). Call it on
    /// every pane edge, qualifying or not: the latest status per key is what
    /// lets a held notice tell that the agent moved on.
    pub fn notify(&mut self, req: NotifyRequest, now: Timestamp) -> Decision {
        let key = cooldown_key(&req.pane, &req.worktree_path);
        self.latest_status.insert(key.clone(), req.new_status);
        if !answers_current_prompt(
            &req.last_assistant_message,
            req.last_assistant_message_at,
            req.last_user_prompt_at,
        ) {
            return Decision::Drop;
        }
        let turn = turn_fingerprint(
            req.new_status,
            &req.last_assistant_message,
            &req.last_message,
            &req.last_user_prompt,
        );
        if !self.should_notify(&key, req.old_status, req.new_status, req.source, &turn, now) {
            return Decision::Drop;
        }
        self.pending.remove(&key);
        let gated = uses_stability_gate(self.stability_delay, &req.pane, req.agent_reported_end);
        let notice = Notice {
            key: key.clone(),
            turn,
            request: req,
        };
        if !gated {
            self.record(&notice, now);
            return Decision::Deliver(notice);
        }
        let until = now + self.stability_delay;
        self.pending.insert(key.clone(), (until, notice));
        Decision::Hold { key, until }
    }

    /// Held notices whose time has come and whose status still holds; the
    /// rest of the due ones are dropped. Oldest deadline first.
    pub fn due(&mut self, now: Timestamp) -> Vec<Notice> {
        let mut ready: Vec<(Timestamp, Notice)> = Vec::new();
        self.pending.retain(|_, (until, notice)| {
            if *until <= now {
                ready.push((*until, notice.clone()));
                false
            } else {
                true
            }
        });
        ready.sort_by(|a, b| a.0.total_cmp(&b.0));
        let mut out = Vec::new();
        for (_, notice) in ready {
            if should_deliver_pending(
                notice.request.new_status,
                self.latest_status.get(&notice.key).copied(),
            ) {
                self.record(&notice, now);
                out.push(notice);
            }
        }
        out
    }

    /// The earliest held deadline, for the owner's timer.
    pub fn next_deadline(&self) -> Option<Timestamp> {
        self.pending
            .values()
            .map(|(t, _)| *t)
            .min_by(|a, b| a.total_cmp(b))
    }

    fn record(&mut self, n: &Notice, now: Timestamp) {
        self.last_notified.insert(
            n.key.clone(),
            Delivery {
                at: now,
                source: n.request.source,
                turn: n.turn.clone(),
            },
        );
    }
}

/// How long a completion the agent has not confirmed is held before looking
/// again, and how many looks it gets. Each look re-reads the pane, so the
/// wait ends the moment the agent's Stop lands.
pub const PROSE_RETRY_INTERVAL: f64 = 1.5;
pub const PROSE_ATTEMPTS: u32 = 10;

/// Whether a completion is worth holding because the agent has not said it
/// finished: the screen reads idle while the hooks still have the turn open.
/// The answer can land seconds after the screen goes quiet, and announcing
/// early quoted a shell command and then refused the real Stop. Panes
/// without hooks (`Unknown`) are never held: the screen is all they have.
pub fn should_wait_for_completion(new: AgentStatus, hook: AgentStatus) -> bool {
    new == AgentStatus::Idle && hook == AgentStatus::Running
}

/// Whether the program said this idle is not a completion: 7501 `idle` is
/// at rest (just started, interrupted), `done` is finished work. Announcing
/// the first sent a notice for every agent launched.
pub fn program_says_at_rest(new: AgentStatus, program_state: Option<ProgramState>) -> bool {
    new == AgentStatus::Idle && program_state == Some(ProgramState::Idle)
}

/// One pane edge, as `deliverPaneStatusChange` received it.
#[derive(Clone, Debug)]
pub struct CompletionInput<'a> {
    /// The registry's pane, if it is still there.
    pub pane: Option<&'a PaneInfo>,
    pub old_status: AgentStatus,
    pub new_status: AgentStatus,
    /// The agent's own Stop (`deliverAgentCompletion`): the edge is
    /// `Running → Idle` whatever the rollup thinks.
    pub agent_reported_end: bool,
    /// Looks left at a held completion; start at `PROSE_ATTEMPTS`.
    pub attempts_left: u32,
    /// The worktree is visible *and* the app is in front: what it takes for
    /// a finished turn to count as seen.
    pub worktree_on_screen: bool,
    /// A pending order card (question / suggestion) already shows this
    /// pane's "needs input"; a notice on top would say it twice.
    pub has_pending_card: bool,
    /// How many completion signals the pane has had so far
    /// (`CompletionSignals::count`).
    pub completion_signals: u64,
}

/// What to do with the edge.
#[derive(Clone, Debug, PartialEq)]
pub enum CompletionStep {
    /// Nothing to announce.
    Ignore,
    /// Ask again after `after` seconds with `attempts_left`, unless
    /// `retry_proceeds` says the wait settled it.
    Retry {
        after: f64,
        attempts_left: u32,
        signals_seen: u64,
    },
    /// Mark unseen if asked, then hand a `NotifyRequest` to the policy.
    Proceed { mark_unseen: bool, source: Source },
}

/// The completion decision of `deliverPaneStatusChange`, in its order:
/// an at-rest 7501 idle is dropped; an idle the hooks dispute is held; a
/// waiting edge with a card already up is dropped; otherwise a turn that
/// ended off screen is marked unseen and the edge goes on to the policy.
pub fn completion_step(input: &CompletionInput) -> CompletionStep {
    let hook = input.pane.map(|p| p.hook_status).unwrap_or_default();
    if program_says_at_rest(input.new_status, input.pane.and_then(|p| p.program_state)) {
        return CompletionStep::Ignore;
    }
    if input.attempts_left > 0 && should_wait_for_completion(input.new_status, hook) {
        return CompletionStep::Retry {
            after: PROSE_RETRY_INTERVAL,
            attempts_left: input.attempts_left - 1,
            signals_seen: input.completion_signals,
        };
    }
    if input.new_status == AgentStatus::Waiting && input.pane.is_some() && input.has_pending_card {
        return CompletionStep::Ignore;
    }
    let mark_unseen = unseen::marks(input.old_status, input.new_status)
        && input.pane.is_some()
        && !input.worktree_on_screen;
    CompletionStep::Proceed {
        mark_unseen,
        source: source_for(hook, input.new_status),
    }
}

/// Whether a held completion is still worth deciding when its retry comes
/// round: not if the pane is working again (whatever it does now will
/// announce itself), nor if the agent finished meanwhile and said so with
/// its own completion, which has gone out already.
pub fn retry_proceeds(
    status_now: Option<AgentStatus>,
    signals_seen: u64,
    signals_now: u64,
) -> bool {
    status_now != Some(AgentStatus::Running) && signals_seen == signals_now
}

/// How many times each pane's agent has reported finishing a turn. Only the
/// count matters: a held edge compares it with what it saw on the way in.
#[derive(Debug, Default)]
pub struct CompletionSignals(HashMap<String, u64>);

impl CompletionSignals {
    pub fn new() -> Self {
        Self::default()
    }

    /// Count the outcome if it is a completion. Returns whether it was.
    pub fn note(&mut self, o: &Outcome) -> bool {
        if o.is_completion_signal {
            *self.0.entry(o.info.id.clone()).or_default() += 1;
        }
        o.is_completion_signal
    }

    pub fn count(&self, pane: &str) -> u64 {
        self.0.get(pane).copied().unwrap_or(0)
    }
}
