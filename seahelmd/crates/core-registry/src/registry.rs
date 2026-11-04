//! The registry: every pane, the one write path (`ingest`), and the
//! arbitration between what the screen shows, what the hooks said and what
//! the program itself reports over OSC 7501.
//!
//! Ported from `Sources/Core/AgentRegistry.swift`. What changed: the pane
//! key is the seahelmd session name and the app's `Station.id` is an alias;
//! the lock and the main-queue hops are gone (one owner drives this, and
//! what `onOutcome` delivered is returned as an `Outcome` and published to
//! the `EventHub`); time comes in as `now`; the manifest authority comes in
//! as an argument, since the scan crate owns manifests. Not ported, because
//! nothing in the app reaches them: the `delegate`, `updateStatus` /
//! `PaneReducer`, the per-pane event log, the index-only
//! `registerTerminalID`, and the channel/backend bookkeeping (that is
//! transport, which stays with the clients).

use std::collections::HashMap;

use seahelm_core_types::{
    AgentStatus, AgentType, Authority, EventKind, EventSource, NormalizedEvent, ProgramState,
    ProgramStatus, Timestamp,
};
use serde_json::{json, Value};

use crate::events::{self, EventHub};
use crate::pane::{upsert_latest, PaneInfo, Registration, ACTIVITY_LOG_SIZE};
use crate::unseen;

/// The time windows the arbitration uses at the edges of a turn, where a
/// hook knows first and the screen lags (or the other way round).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Graces {
    /// Before a scan `Idle` may clear a hook `Running` the screen has shown:
    /// long enough for the agent to start drawing its spinner after a prompt.
    pub hook_running: f64,
    /// The same reclaim for a run the screen never showed. Before the
    /// spinner lands the frame still holds the last turn's prompt, and a 3 s
    /// window reclaimed every such start, blinking the pane to Idle while it
    /// worked. Long but finite, so a turn that died before drawing anything
    /// still comes back.
    pub hook_running_unseen: f64,
    /// How long a hook `Idle` (a Stop) outranks a scan `Running`. Short on
    /// purpose: past it the screen takes authority back, so a stale Stop can
    /// never pin a visibly working pane at idle.
    pub hook_idle: f64,
    /// Before a scan `Running` may clear a hook `Waiting`: long enough that
    /// the question has replaced the spinner on screen, so the pre-question
    /// frame cannot reclaim its own question.
    pub hook_waiting: f64,
}

impl Default for Graces {
    fn default() -> Self {
        Graces {
            hook_running: 3.0,
            hook_running_unseen: 15.0,
            hook_idle: 3.0,
            hook_waiting: 3.0,
        }
    }
}

/// Which input decided a pane's status, as `pane.explain` names it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DecidedBy {
    Osc7501,
    Urgent,
    Hook,
    Screen,
}

impl DecidedBy {
    pub fn as_str(self) -> &'static str {
        match self {
            DecidedBy::Osc7501 => "osc7501",
            DecidedBy::Urgent => "urgent",
            DecidedBy::Hook => "hook",
            DecidedBy::Screen => "screen",
        }
    }
}

/// An authority's manifest spelling (`session_only`, …).
pub fn authority_str(a: Authority) -> &'static str {
    match a {
        Authority::SessionOnly => "session_only",
        Authority::FullLifecycle => "full_lifecycle",
        Authority::ScreenOnly => "screen_only",
    }
}

/// Combine the status sources into one.
///
/// OSC 7501 sits above everything: it is the program's own statement, not a
/// guess from the screen nor an edge a hook may fail to deliver. Next, an
/// urgent state (waiting/error) from either source always surfaces; a
/// blocked agent is never hidden behind an authority rule. Then the
/// authority: `full_lifecycle` trusts the hook (the screen only fills an
/// unknown), `screen_only` the screen, and `session_only` the screen except
/// at the two edges of a turn:
/// - leading: a hook `Running` beats a scan `Idle`, so a submitted prompt
///   shows at once instead of waiting for the spinner and the next scan;
/// - trailing: a *fresh* hook `Idle` beats a scan `Running`, because a TUI
///   still has a spinner line on screen at the instant a turn ends, and
///   screen authority alone dropped the completion.
pub fn arbitrate_detailed(
    scan: AgentStatus,
    hook: AgentStatus,
    authority: Authority,
    hook_idle_fresh: bool,
    program: AgentStatus,
) -> (AgentStatus, DecidedBy) {
    use AgentStatus::*;
    if program != Unknown {
        return (program, DecidedBy::Osc7501);
    }
    let urgent = AgentStatus::highest_priority([scan, hook].into_iter().filter(|s| s.is_urgent()));
    if urgent.is_urgent() {
        return (urgent, DecidedBy::Urgent);
    }
    match authority {
        Authority::FullLifecycle => {
            if hook != Unknown {
                (hook, DecidedBy::Hook)
            } else {
                (scan, DecidedBy::Screen)
            }
        }
        Authority::ScreenOnly => (scan, DecidedBy::Screen),
        Authority::SessionOnly => {
            if scan == Idle && hook == Running {
                return (hook, DecidedBy::Hook);
            }
            if hook_idle_fresh && hook == Idle && scan == Running {
                return (hook, DecidedBy::Hook);
            }
            if scan != Unknown {
                (scan, DecidedBy::Screen)
            } else {
                (hook, DecidedBy::Hook)
            }
        }
    }
}

/// `arbitrate_detailed` without the reason.
pub fn arbitrate(
    scan: AgentStatus,
    hook: AgentStatus,
    authority: Authority,
    hook_idle_fresh: bool,
    program: AgentStatus,
) -> AgentStatus {
    arbitrate_detailed(scan, hook, authority, hook_idle_fresh, program).0
}

/// What one recorded event did to its pane: the Swift `IngestOutcome`.
#[derive(Clone, Debug, PartialEq)]
pub struct Outcome {
    /// The pane after the event.
    pub info: PaneInfo,
    pub status_changed: bool,
    pub old_status: AgentStatus,
    pub new_status: AgentStatus,
    /// How long the pane had held `old_status` (0 when unchanged).
    pub hold_seconds: f64,
    /// The agent finished a turn: a Stop, or a 7501 `done`/`error` after
    /// `working` on a pane without hooks.
    pub is_completion_signal: bool,
    pub event: NormalizedEvent,
    /// The registry's monotonic sequence at ingest.
    pub seq: u64,
}

impl Outcome {
    /// The `pane.status_changed` / `pane.updated` event for this outcome.
    pub fn to_event(&self) -> Value {
        events::outcome_event(self)
    }
}

/// A hook payload already decoded by the hooks crate, plus what the
/// registry needs from the raw event (`handleWebhookEvent`).
#[derive(Clone, Debug, PartialEq)]
pub struct HookInput {
    /// `seahelm_pane_id`: a session name or a client alias.
    pub pane_hint: Option<String>,
    pub cwd: String,
    /// The hook's `source` ("claude-code", "codex", …).
    pub source: String,
    /// The decoded event; None for kinds that carry no pane event
    /// (cwd_changed, subagent_stop, assistant_response). They still resolve
    /// and type the pane.
    pub kind: Option<EventKind>,
    /// A Stop's `last_assistant_message`, sentinel already stripped.
    pub last_assistant_message: Option<String>,
}

/// Where a hook landed.
#[derive(Clone, Debug, PartialEq)]
pub struct HookResult {
    pub pane: Option<String>,
    /// The pane hint named a pane that did not resolve, so the event went to
    /// the worktree's first pane instead. Worth a log line: a misrouted
    /// clearing hook is how a card sticks on "Needs input".
    pub fell_back_from_hint: bool,
    pub outcome: Option<Outcome>,
}

#[derive(Debug, Default)]
pub struct Registry {
    pub graces: Graces,
    panes: HashMap<String, PaneInfo>,
    /// Registration order (then `reorder`), for `panes()`.
    order: Vec<String>,
    /// Client alias → pane key.
    aliases: HashMap<String, String>,
    /// Worktree path → pane keys, in registration order (1:N).
    worktree_index: HashMap<String, Vec<String>>,
    /// Worktrees with background work (subagents, background shells): their
    /// suggestions are suppressed, since the agent will resume on its own.
    background_busy: std::collections::HashSet<String>,
    /// When each pane entered its current status, for `hold_seconds`.
    status_entered_at: HashMap<String, Timestamp>,
    /// When the hook last asserted `Running` (a leading edge).
    hook_running_since: HashMap<String, Timestamp>,
    /// When the screen last showed the pane running: what tells an idle frame
    /// that ends a run from one taken before the run reached the screen.
    scan_running_at: HashMap<String, Timestamp>,
    /// When the hook last asserted `Idle` (a Stop).
    hook_idle_since: HashMap<String, Timestamp>,
    /// When the hook last asserted `Waiting`.
    hook_waiting_since: HashMap<String, Timestamp>,
    /// When the prompt that started the current turn was submitted. Unlike
    /// `hook_running_since` it survives an approval mid-turn.
    turn_started_at: HashMap<String, Timestamp>,
    /// The live 7501 root record, for `explain`.
    program_records: HashMap<String, ProgramStatus>,
    /// Panes a client asked to close (`pane.close`): their `pane.closed`
    /// says so, so the client drawing them removes them instead of
    /// recovering the session.
    closing: std::collections::HashSet<String>,
    seq: u64,
    events: EventHub,
}

impl Registry {
    pub fn new() -> Self {
        Self::default()
    }

    // MARK: registration

    /// File a pane. Registering a known pane again rebuilds its entry (as the
    /// Swift does) but keeps its place in the order.
    pub fn register(&mut self, r: Registration) {
        if let Some(old) = self.panes.get(&r.pane) {
            let (old_path, old_alias) = (old.worktree_path.clone(), old.alias.clone());
            if old_path != r.worktree_path {
                self.unindex(&r.pane, &old_path);
            }
            if let Some(old_alias) = old_alias {
                self.aliases.remove(&old_alias);
            }
        }
        let mut info = PaneInfo::new(
            r.pane.clone(),
            r.alias.clone(),
            r.worktree_path.clone(),
            r.project,
            r.branch,
            r.started_at,
        );
        info.agent_type = r.agent_type;
        if let Some(alias) = r.alias {
            self.aliases.insert(alias, r.pane.clone());
        }
        self.index(&r.pane, &r.worktree_path);
        if !self.order.contains(&r.pane) {
            self.order.push(r.pane.clone());
        }
        self.panes.insert(r.pane, info);
    }

    /// Give a pane a new client alias, keeping everything else: a client
    /// that restarted names the same session with a new id.
    pub fn set_alias(&mut self, pane: &str, alias: Option<String>) {
        let Some(info) = self.panes.get_mut(pane) else { return };
        if info.alias == alias {
            return;
        }
        if let Some(old) = info.alias.take() {
            self.aliases.remove(&old);
        }
        if let Some(a) = &alias {
            self.aliases.insert(a.clone(), pane.to_string());
        }
        info.alias = alias;
    }

    /// The next `unregister` of `pane` was asked for (`pane.close`).
    pub fn mark_closing(&mut self, pane: &str) {
        self.closing.insert(pane.to_string());
    }

    /// Forget a pane and every timer it had, and announce `pane.closed`.
    pub fn unregister(&mut self, pane: &str) {
        let by_request = self.closing.remove(pane);
        let closed = self.panes.remove(pane);
        if let Some(info) = &closed {
            self.unindex(pane, &info.worktree_path);
            if let Some(alias) = &info.alias {
                self.aliases.remove(alias);
            }
        }
        self.order.retain(|p| p != pane);
        for timers in [
            &mut self.status_entered_at,
            &mut self.hook_running_since,
            &mut self.scan_running_at,
            &mut self.hook_idle_since,
            &mut self.hook_waiting_since,
            &mut self.turn_started_at,
        ] {
            timers.remove(pane);
        }
        self.program_records.remove(pane);
        self.seq += 1;
        if let Some(info) = closed {
            let seq = self.seq;
            let mut ev = events::closed_event(seq, &info);
            if by_request {
                ev["by_request"] = Value::Bool(true);
            }
            self.events.publish(seq, ev);
        }
    }

    /// Re-attribute a live pane to another worktree, keeping its history.
    /// False when the pane is unknown or already filed there.
    ///
    /// Deliberately not `unregister` + `register`: that drops every timer and
    /// rebuilds the entry at `Unknown`, so a pane that merely moved came back
    /// looking freshly opened.
    pub fn rehome(&mut self, pane: &str, worktree: &str, branch: &str, project: &str) -> bool {
        let Some(old) = self.panes.get(pane) else {
            return false;
        };
        if old.worktree_path == worktree {
            return false;
        }
        let old_path = old.worktree_path.clone();
        let moved = old.rehomed(worktree, branch, project);
        self.unindex(pane, &old_path);
        self.index(pane, worktree);
        self.seq += 1;
        let seq = self.seq;
        self.events
            .publish(seq, events::rehomed_event(seq, &moved, &old_path));
        self.panes.insert(pane.to_string(), moved);
        true
    }

    fn index(&mut self, pane: &str, worktree: &str) {
        let ids = self.worktree_index.entry(worktree.to_string()).or_default();
        if !ids.iter().any(|p| p == pane) {
            ids.push(pane.to_string());
        }
    }

    fn unindex(&mut self, pane: &str, worktree: &str) {
        if let Some(ids) = self.worktree_index.get_mut(worktree) {
            ids.retain(|p| p != pane);
            if ids.is_empty() {
                self.worktree_index.remove(worktree);
            }
        }
    }

    // MARK: resolution

    /// The worktree `cwd` belongs to: the indexed path that is the **longest**
    /// prefix of it (on a path boundary). The Swift registry took the first
    /// match in dictionary order, which picked the outer worktree for a cwd in
    /// a worktree nested inside another (`<repo>/.claude/worktrees/<name>`).
    pub fn worktree_for_cwd(&self, cwd: &str) -> Option<&str> {
        self.worktree_index
            .keys()
            .filter(|path| path_contains(path, cwd))
            .max_by_key(|path| path.len())
            .map(String::as_str)
    }

    /// The pane key a hint names: a pane key itself, or an alias.
    fn pane_for_hint(&self, hint: &str) -> Option<&str> {
        if let Some((key, _)) = self.panes.get_key_value(hint) {
            return Some(key.as_str());
        }
        self.aliases
            .get(hint)
            .map(String::as_str)
            .filter(|k| self.panes.contains_key(*k))
    }

    /// The pane an event is about: the hint (`seahelm_pane_id`, a session or
    /// an alias) when it names a registered pane, else the first pane of the
    /// worktree whose path is the longest prefix of `cwd`.
    pub fn resolve(&self, pane_hint: Option<&str>, cwd: &str) -> Option<String> {
        if let Some(key) = pane_hint.and_then(|h| self.pane_for_hint(h)) {
            return Some(key.to_string());
        }
        let wt = self.worktree_for_cwd(cwd)?;
        self.worktree_index
            .get(wt)
            .and_then(|ids| ids.first())
            .cloned()
    }

    /// `resolve`, after adopting the hinted pane if it is live but not
    /// registered yet: it inherits worktree, branch and project from a
    /// sibling in the worktree `cwd` names.
    ///
    /// Resolution must be stable. When a hint only counted with an entry
    /// already present, the same pane resolved to itself or to its worktree's
    /// first pane depending on registration timing, and a card filed under
    /// one id was never cleared by the prompt filed under the other.
    /// `is_live` says whether a session name is a live seahelmd session
    /// (the Swift asked `StationRegistry`). Without a sibling there is no
    /// worktree to adopt into, and cwd matching decides.
    pub fn resolve_or_adopt(
        &mut self,
        pane_hint: Option<&str>,
        cwd: &str,
        is_live: &dyn Fn(&str) -> bool,
    ) -> Option<String> {
        if let Some(hint) = pane_hint {
            if self.pane_for_hint(hint).is_none() && is_live(hint) {
                let sibling = self
                    .worktree_for_cwd(cwd)
                    .and_then(|wt| self.worktree_index.get(wt))
                    .and_then(|ids| ids.first())
                    .and_then(|id| self.panes.get(id))
                    .map(|s| (s.worktree_path.clone(), s.project.clone(), s.branch.clone()));
                if let Some((wt, project, branch)) = sibling {
                    let info =
                        PaneInfo::new(hint.to_string(), None, wt.clone(), project, branch, None);
                    self.panes.insert(hint.to_string(), info);
                    self.index(hint, &wt);
                    if !self.order.iter().any(|p| p == hint) {
                        self.order.push(hint.to_string());
                    }
                }
            }
        }
        self.resolve(pane_hint, cwd)
    }

    // MARK: the write path

    /// Record one event with a fixed authority. See `ingest_with`.
    pub fn ingest(
        &mut self,
        ev: NormalizedEvent,
        authority: Authority,
        now: Timestamp,
    ) -> Option<Outcome> {
        self.ingest_with(ev, &|_| authority, now)
    }

    /// THE write path: fold the event into its pane's components, arbitrate,
    /// and report what changed. `authority_of` maps the pane's agent type to
    /// its manifest authority; it is asked after the event has had its say,
    /// so a scan that first identifies the agent arbitrates under that
    /// agent's manifest, as the Swift did.
    ///
    /// None when the pane is unknown, or when a screen scan changed nothing a
    /// client can render: scans re-fire every poll while an agent works, and
    /// passing those on cost a full fan-out every 2 s per pane. Hook and
    /// lifecycle events are edges and always pass.
    pub fn ingest_with(
        &mut self,
        ev: NormalizedEvent,
        authority_of: &dyn Fn(AgentType) -> Authority,
        now: Timestamp,
    ) -> Option<Outcome> {
        self.seq = self.seq.wrapping_add(1);
        let seq = self.seq;
        let id = ev.pane.clone();
        let current = self.panes.get(&id)?.clone();

        let mut next = current.clone();
        let mut is_completion = false;
        let mut message = current.last_message.clone();

        match &ev.kind {
            EventKind::ScreenObserved {
                status,
                message: msg,
                activity,
                command_line,
                agent_type,
                round_duration,
                tasks,
                background_busy,
            } => {
                let status = *status;
                next.scan_status = status;
                next.background_busy = *background_busy;
                next.round_duration = *round_duration;
                if !tasks.is_empty() {
                    next.tasks = tasks.clone();
                }
                if !msg.is_empty() {
                    message = msg.clone();
                }
                if let Some(cl) = command_line {
                    next.command_line = Some(cl.clone());
                }
                if *agent_type != AgentType::Unknown {
                    next.agent_type = *agent_type;
                }
                if !activity.is_empty() {
                    next.activity_events = activity.clone();
                }
                if status == AgentStatus::Running {
                    self.scan_running_at.insert(id.clone(), now);
                }
                let session_only = authority_of(next.agent_type) == Authority::SessionOnly;
                // Trailing-edge reclaim: a sustained scan idle past the grace
                // window drops a stale hook `Running`, so an Esc that fires no
                // Stop hook does not stick on "running".
                if status == AgentStatus::Idle
                    && next.hook_status == AgentStatus::Running
                    && session_only
                {
                    if let Some(&since) = self.hook_running_since.get(&id) {
                        let showed_run =
                            self.scan_running_at.get(&id).is_some_and(|&at| at >= since);
                        let grace = if showed_run {
                            self.graces.hook_running
                        } else {
                            self.graces.hook_running_unseen
                        };
                        if now - since >= grace {
                            next.hook_status = AgentStatus::Unknown;
                            self.hook_running_since.remove(&id);
                        }
                    }
                }
                // The same for a stale hook `Waiting`: the agent is visibly
                // working again. `Waiting` is urgent and outranks every scan,
                // so without this one undelivered clearing hook stranded the
                // card on "Needs input" for good.
                if status == AgentStatus::Running
                    && next.hook_status == AgentStatus::Waiting
                    && session_only
                {
                    if let Some(&since) = self.hook_waiting_since.get(&id) {
                        if now - since >= self.graces.hook_waiting {
                            next.hook_status = AgentStatus::Unknown;
                            self.hook_waiting_since.remove(&id);
                        }
                    }
                }
            }
            EventKind::SessionStarted { label } => {
                self.hook_running(&mut next, now);
                message = label.clone();
            }
            EventKind::UserPrompt { text } => {
                self.hook_running(&mut next, now);
                if next.last_user_prompt != *text {
                    next.last_user_prompt_at = Some(now);
                }
                next.last_user_prompt = text.clone();
                self.turn_started_at.insert(id.clone(), now);
            }
            EventKind::ToolUse { activity } => {
                self.hook_running(&mut next, now);
                upsert_latest(
                    &mut next.activity_events,
                    activity.clone(),
                    ACTIVITY_LOG_SIZE,
                );
                if !activity.detail.is_empty() {
                    message = activity.detail.clone();
                }
            }
            EventKind::AwaitingInput { text } => {
                self.hook_waiting(&mut next, now);
                message = text.clone();
            }
            EventKind::Question { prompt, .. } => {
                // A hook-native question owns the hook status; a choice the
                // scan found on screen owns the scan status, so the next
                // frame clears it naturally.
                if ev.source == EventSource::Scan {
                    next.scan_status = AgentStatus::Waiting;
                } else {
                    self.hook_waiting(&mut next, now);
                }
                message = prompt.clone();
            }
            EventKind::AgentStopped { success } => {
                next.hook_status = if *success {
                    AgentStatus::Idle
                } else {
                    AgentStatus::Error
                };
                self.hook_running_since.remove(&id);
                self.turn_started_at.remove(&id);
                self.hook_waiting_since.remove(&id);
                // Overwritten by every Stop: each is the agent saying anew
                // that it finished.
                self.hook_idle_since.insert(id.clone(), now);
                next.activity_events.clear();
                is_completion = true;
            }
            EventKind::Notification { level, text } => {
                // Neutral notifications keep the hook status they found.
                match level.as_str() {
                    "error" => next.hook_status = AgentStatus::Error,
                    "warning" => {
                        next.hook_status = AgentStatus::Waiting;
                        self.hook_waiting_since.entry(id.clone()).or_insert(now);
                    }
                    _ => {}
                }
                if !text.is_empty() {
                    message = text.clone();
                }
            }
            EventKind::TaskUpdate { tasks } => next.tasks = tasks.clone(),
            // Options only; they travel on the outcome's event.
            EventKind::Suggest { .. } => {}
            EventKind::ProgramStatus { record } => {
                next.program_status = record
                    .as_ref()
                    .map(|r| r.agent_status())
                    .unwrap_or(AgentStatus::Unknown);
                next.program_state = record.as_ref().map(|r| r.state);
                if let Some(text) = record
                    .as_ref()
                    .map(|r| r.message())
                    .filter(|t| !t.is_empty())
                {
                    message = text;
                }
                // `done` after `working` is a finished turn. A pane that also
                // reports hooks gets its completion from the Stop, and counting
                // both would notify twice, so 7501 completes only without hooks.
                if let Some(state) = next.program_state {
                    if matches!(state, ProgramState::Done | ProgramState::Error)
                        && current.program_status == AgentStatus::Running
                        && next.hook_status == AgentStatus::Unknown
                    {
                        is_completion = true;
                    }
                }
                match record {
                    Some(r) => self.program_records.insert(id.clone(), r.clone()),
                    None => self.program_records.remove(&id),
                };
            }
        }

        next.last_message = message;
        let old_status = current.status;
        let new_status = arbitrate(
            next.scan_status,
            next.hook_status,
            authority_of(next.agent_type),
            self.hook_idle_is_fresh(&id, now),
            next.program_status,
        );
        next.status = new_status;
        self.panes.insert(id.clone(), next.clone());

        let status_changed = old_status != new_status;
        let mut hold = 0.0;
        if status_changed {
            let entered = self.status_entered_at.get(&id).copied().unwrap_or(now);
            hold = now - entered;
            self.status_entered_at.insert(id.clone(), now);
        }

        if matches!(ev.kind, EventKind::ScreenObserved { .. })
            && !status_changed
            && displayed_state_unchanged(&current, &next)
        {
            return None;
        }

        let outcome = Outcome {
            info: next,
            status_changed,
            old_status,
            new_status,
            hold_seconds: hold,
            is_completion_signal: is_completion,
            event: ev,
            seq,
        };
        self.events.publish(seq, outcome.to_event());
        Some(outcome)
    }

    /// A hook leading edge: the agent is running.
    fn hook_running(&mut self, next: &mut PaneInfo, now: Timestamp) {
        next.hook_status = AgentStatus::Running;
        self.hook_running_since
            .entry(next.id.clone())
            .or_insert(now);
        self.hook_waiting_since.remove(&next.id);
    }

    /// A hook says the agent waits on the user.
    fn hook_waiting(&mut self, next: &mut PaneInfo, now: Timestamp) {
        next.hook_status = AgentStatus::Waiting;
        self.hook_running_since.remove(&next.id);
        self.hook_waiting_since
            .entry(next.id.clone())
            .or_insert(now);
    }

    /// The hook path end to end (`handleWebhookEvent`): resolve the pane
    /// (adopting a live unregistered one), let the hook's source type it,
    /// stash a Stop's final prose *before* ingest so the completion event
    /// carries it, then ingest.
    pub fn ingest_hook(
        &mut self,
        input: HookInput,
        is_live: &dyn Fn(&str) -> bool,
        authority_of: &dyn Fn(AgentType) -> Authority,
        now: Timestamp,
    ) -> HookResult {
        let resolved = self.resolve_or_adopt(input.pane_hint.as_deref(), &input.cwd, is_live);
        let hint_key = input
            .pane_hint
            .as_deref()
            .and_then(|h| self.pane_for_hint(h))
            .map(str::to_string);
        let fell_back_from_hint =
            input.pane_hint.is_some() && resolved.is_some() && resolved != hint_key;
        let Some(pane) = resolved else {
            return HookResult {
                pane: None,
                fell_back_from_hint: false,
                outcome: None,
            };
        };
        // Every hook source that names a known agent types the pane.
        let hook_agent = AgentType::from_hook_source(&input.source);
        if hook_agent != AgentType::Unknown {
            self.update_detection(&pane, hook_agent, None);
        }
        let Some(kind) = input.kind else {
            return HookResult {
                pane: Some(pane),
                fell_back_from_hint,
                outcome: None,
            };
        };
        if matches!(kind, EventKind::AgentStopped { success: true }) {
            if let Some(text) = input
                .last_assistant_message
                .as_deref()
                .map(str::trim)
                .filter(|t| !t.is_empty())
            {
                if let Some(info) = self.panes.get_mut(&pane) {
                    if info.last_assistant_message != text {
                        info.last_assistant_message_at = Some(now);
                    }
                    info.last_assistant_message = text.to_string();
                }
            }
        }
        let ev = NormalizedEvent {
            pane: pane.clone(),
            source: EventSource::Hook(input.source),
            kind,
        };
        let outcome = self.ingest_with(ev, authority_of, now);
        HookResult {
            pane: Some(pane),
            fell_back_from_hint,
            outcome,
        }
    }

    /// Record the agent's final prose without touching status, for a
    /// suggestion card's summary line (`noteAssistantMessage`). Resolves like
    /// a hook. Returns the pane updated.
    pub fn note_assistant_message(
        &mut self,
        pane_hint: Option<&str>,
        cwd: &str,
        message: &str,
        now: Timestamp,
    ) -> Option<String> {
        let trimmed = message.trim();
        if trimmed.is_empty() {
            return None;
        }
        let pane = self.resolve(pane_hint, cwd)?;
        let info = self.panes.get_mut(&pane)?;
        info.last_message = trimmed.to_string();
        if info.last_assistant_message != trimmed {
            info.last_assistant_message_at = Some(now);
        }
        info.last_assistant_message = trimmed.to_string();
        Some(pane)
    }

    /// What the scan or a hook learned about what runs in the pane. Returns
    /// whether anything changed. Type rules: from `Unknown` or a shell task,
    /// anything goes; an AI agent may only become another AI agent (no
    /// demotion to the `brew` it happens to run); `Unknown` changes nothing.
    pub fn update_detection(
        &mut self,
        pane: &str,
        agent: AgentType,
        command_line: Option<String>,
    ) -> bool {
        let Some(info) = self.panes.get_mut(pane) else {
            return false;
        };
        let mut changed = false;
        if let Some(cl) = command_line {
            if info.command_line.as_deref() != Some(cl.as_str()) {
                info.command_line = Some(cl);
                changed = true;
            }
        }
        if agent != AgentType::Unknown {
            let current = info.agent_type;
            let allowed = !current.is_ai_agent() || agent.is_ai_agent();
            if allowed && current != agent {
                info.agent_type = agent;
                changed = true;
            }
        }
        changed
    }

    /// Mark the worktree owning `cwd` busy (or not) with background work.
    /// A cwd outside every known worktree is ignored.
    pub fn set_background_busy(&mut self, cwd: &str, busy: bool) {
        let Some(path) = self.worktree_for_cwd(cwd).map(str::to_string) else {
            return;
        };
        if busy {
            self.background_busy.insert(path);
        } else {
            self.background_busy.remove(&path);
        }
    }

    /// Whether the worktree owning `cwd` has background work running.
    pub fn is_background_busy(&self, cwd: &str) -> bool {
        self.worktree_for_cwd(cwd)
            .is_some_and(|p| self.background_busy.contains(p))
    }

    /// Mark or clear a pane's unseen completion. Returns whether it changed;
    /// a change is published as `pane.unseen_changed`.
    pub fn set_unseen(&mut self, pane: &str, unseen: bool) -> bool {
        let Some(info) = self.panes.get_mut(pane) else {
            return false;
        };
        if info.unseen_completion == unseen {
            return false;
        }
        info.unseen_completion = unseen;
        let info = info.clone();
        self.seq += 1;
        let seq = self.seq;
        self.events.publish(seq, events::unseen_event(seq, &info));
        true
    }

    /// The outcome's pane moved on (working again, asking, gone): its unread
    /// finish is superseded. Returns whether it was cleared.
    pub fn settle_unseen(&mut self, outcome: &Outcome) -> bool {
        outcome.info.unseen_completion
            && unseen::clears(outcome.new_status)
            && self.set_unseen(&outcome.info.id, false)
    }

    /// The worktree is on screen in front of the user: every pane of it has
    /// been seen. Returns the panes cleared.
    pub fn mark_worktree_seen(&mut self, worktree: &str) -> Vec<String> {
        let ids: Vec<String> = self
            .panes_in_worktree(worktree)
            .filter(|p| p.unseen_completion)
            .map(|p| p.id.clone())
            .collect();
        ids.into_iter()
            .filter(|id| self.set_unseen(id, false))
            .collect()
    }

    /// A client showed this pane (session or alias): `pane.seen`. False when
    /// there was nothing unseen.
    pub fn mark_pane_seen(&mut self, pane_hint: &str) -> bool {
        match self.pane_for_hint(pane_hint).map(str::to_string) {
            Some(key) => self.set_unseen(&key, false),
            None => false,
        }
    }

    /// Put panes in the order the client's cards are in. Stable: panes of
    /// the same worktree keep their registration order, so a worktree's
    /// representative pane does not change on each call.
    pub fn reorder(&mut self, paths: &[String]) {
        let rank = |id: &String| {
            let wt = self
                .panes
                .get(id)
                .map(|p| p.worktree_path.as_str())
                .unwrap_or("");
            paths.iter().position(|p| p == wt).unwrap_or(usize::MAX)
        };
        let mut ranked: Vec<(usize, String)> =
            self.order.iter().map(|id| (rank(id), id.clone())).collect();
        ranked.sort_by_key(|(r, _)| *r); // stable
        self.order = ranked.into_iter().map(|(_, id)| id).collect();
    }

    // MARK: queries

    pub fn pane(&self, pane: &str) -> Option<&PaneInfo> {
        self.panes.get(pane)
    }

    /// Every pane, in registration (or `reorder`) order.
    pub fn panes(&self) -> impl Iterator<Item = &PaneInfo> {
        self.order.iter().filter_map(|id| self.panes.get(id))
    }

    /// The pane keys filed under a worktree, in registration order.
    pub fn pane_ids_in_worktree(&self, worktree: &str) -> &[String] {
        self.worktree_index
            .get(worktree)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    pub fn panes_in_worktree<'a>(
        &'a self,
        worktree: &str,
    ) -> impl Iterator<Item = &'a PaneInfo> + 'a {
        self.pane_ids_in_worktree(worktree)
            .iter()
            .filter_map(|id| self.panes.get(id))
    }

    /// The worktree's first pane.
    pub fn pane_for_worktree(&self, worktree: &str) -> Option<&PaneInfo> {
        self.panes_in_worktree(worktree).next()
    }

    /// Whether *any* pane of the worktree is mid-turn. Not the first pane's
    /// status: one busy split is enough to make the worktree unsafe to touch.
    pub fn has_running_pane(&self, worktree: &str) -> bool {
        self.panes_in_worktree(worktree)
            .any(|p| p.status == AgentStatus::Running)
    }

    pub fn panes_for_project<'a>(
        &'a self,
        project: &'a str,
    ) -> impl Iterator<Item = &'a PaneInfo> + 'a {
        self.panes().filter(move |p| p.project == project)
    }

    pub fn hook_status(&self, pane: &str) -> AgentStatus {
        self.panes
            .get(pane)
            .map(|p| p.hook_status)
            .unwrap_or_default()
    }

    /// When the prompt that began the pane's current turn was submitted,
    /// until the turn's Stop. None between turns or without hooks.
    pub fn turn_started(&self, pane: &str) -> Option<Timestamp> {
        self.turn_started_at.get(pane).copied()
    }

    /// Whether the pane's last Stop is still inside its trailing-edge window.
    pub fn hook_idle_is_fresh(&self, pane: &str, now: Timestamp) -> bool {
        self.hook_idle_since
            .get(pane)
            .is_some_and(|&since| now - since < self.graces.hook_idle)
    }

    /// The arbitration fields of `pane.explain`, as the pipeline would decide
    /// right now from the components it holds. The live screen detection and
    /// manifest fields come from the scan crate's `explain`; a caller that has
    /// a fresher scan status than the last ingested one merges it there.
    pub fn explain(&self, pane: &str, authority: Authority, now: Timestamp) -> Value {
        let Some(info) = self.panes.get(pane) else {
            return Value::Null;
        };
        let fresh = self.hook_idle_is_fresh(pane, now);
        let (status, decided_by) = arbitrate_detailed(
            info.scan_status,
            info.hook_status,
            authority,
            fresh,
            info.program_status,
        );
        let records: Vec<Value> = self
            .program_records
            .get(pane)
            .map(|r| {
                let mut d = json!({ "id": "", "state": program_state_str(r.state), "app": r.app });
                if let Some(kind) = &r.kind {
                    d["kind"] = kind.clone().into();
                }
                if let Some(p) = r.progress {
                    d["progress"] = p.into();
                }
                if !r.title.is_empty() {
                    d["title"] = r.title.clone().into();
                }
                if !r.msg.is_empty() {
                    d["msg"] = r.msg.clone().into();
                }
                vec![d]
            })
            .unwrap_or_default();
        json!({
            "pane_id": info.public_id(),
            "pane_session_key": info.id,
            "agent": events::agent_type_str(info.agent_type),
            "authority": authority_str(authority),
            "status": status.as_str(),
            "decided_by": decided_by.as_str(),
            "scan_status": info.scan_status.as_str(),
            "hook_status": info.hook_status.as_str(),
            "hook_idle_fresh": fresh,
            "program_status_live": info.program_status != AgentStatus::Unknown,
            "program_status": records,
        })
    }

    /// One pane as `pane.list` reports it (`PaneSnapshot.dict`). `title` is
    /// left empty: the OSC title is screen state, which the caller has from
    /// the daemon's snapshot and sets (with `display_title`) itself.
    pub fn pane_json(&self, pane: &str) -> Option<Value> {
        let p = self.panes.get(pane)?;
        let mut d = json!({
            "pane_id": p.public_id(),
            "pane_session_key": p.id,
            "worktree_path": p.worktree_path,
            "branch": p.branch,
            "project": p.project,
            "agent_type": events::agent_type_str(p.agent_type),
            "status": p.status.as_str(),
            "last_message": p.last_message,
            "title": "",
        });
        if p.unseen_completion {
            d["unseen"] = true.into();
        }
        Some(d)
    }

    pub fn events(&self) -> &EventHub {
        &self.events
    }

    /// The last sequence number handed out.
    pub fn seq(&self) -> u64 {
        self.seq
    }

    /// Publish an event the registry did not make itself (a notice the
    /// caller decided on) under the next sequence number, so subscribers see
    /// it in order with the rest. Its `seq` field is set here.
    pub fn publish(&mut self, mut event: Value) -> u64 {
        self.seq = self.seq.wrapping_add(1);
        if let Some(obj) = event.as_object_mut() {
            obj.insert("seq".into(), Value::from(self.seq));
        }
        self.events.publish(self.seq, event);
        self.seq
    }
}

/// Whether `dir` is `path` or one of its ancestors, on a `/` boundary.
fn path_contains(dir: &str, path: &str) -> bool {
    path == dir || (path.starts_with(dir) && path[dir.len()..].starts_with('/'))
}

fn program_state_str(s: ProgramState) -> &'static str {
    match s {
        ProgramState::Idle => "idle",
        ProgramState::Working => "working",
        ProgramState::Done => "done",
        ProgramState::Blocked => "blocked",
        ProgramState::Error => "error",
    }
}

/// Whether two snapshots agree on every field a client renders.
/// `round_duration` is left out on purpose: it ticks every poll for any
/// running pane, and elapsed-time labels refresh on their own clock.
fn displayed_state_unchanged(a: &PaneInfo, b: &PaneInfo) -> bool {
    a.status == b.status
        && a.last_message == b.last_message
        && a.last_user_prompt == b.last_user_prompt
        && a.command_line == b.command_line
        && a.agent_type == b.agent_type
        && a.scan_status == b.scan_status
        && a.hook_status == b.hook_status
        && a.program_status == b.program_status
        && a.tasks == b.tasks
        && a.activity_events == b.activity_events
}
