//! First Mate, run by the core (docs/first-mate-core.md): keeps its session
//! alive, turns PR changes and schedules into events, matches them to each
//! repo's rules, hands the prompts over when it is free, and gates every
//! action it asks for. Ported from `AutopilotCoordinator.swift`.
//!
//! One thread owns all of it and is talked to by message, so nothing here
//! ever waits on the core's lock while holding its own state: the RPC asks
//! (gate, propose, state, say) and waits for the answer; outcomes of First
//! Mate's pane and answered cards arrive without a reply.
//!
//! First Mate lives in the core and nowhere else (docs/app-reads-core.md).
//! The core runs it when `config.json` says `autopilot_enabled: true`, and
//! only while it holds `first-mate/owner.lock`: two cores would handle every
//! CI failure twice.

pub mod brief;
pub mod budget;
pub mod clock;
pub mod cron;
pub mod engine;
pub mod facts;
pub mod habits;
pub mod inventory;
pub mod lang;
pub mod learning;
pub mod memory;
pub mod routing;
pub mod observations;
mod generalisation;
pub mod tuning;
pub mod pane;
pub mod policy;
pub mod presence;
pub mod research;
pub mod rules;
pub mod sweep;
pub mod task_sources;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use serde_json::{json, Value};

use seahelm_core_registry::cards::CardKind;
use seahelm_core_types::AgentStatus;

use crate::core::Core;
use crate::rpc::{RpcError, RpcResult};
use clock::Local;
use cron::Cron;
use engine::{Audit, Detector, Dispatch, Entry, Event, Ledger, Observation};
use pane::Agent;
use rules::{Action, Autonomy, Config, Level, Rule, Trigger};

pub const APPROVE: &str = "Approve";
pub const REJECT: &str = "Reject";
pub const NOT_NOW: &str = "Not now";
/// Refused by policy (the app's `ControlError.autopilotRefused`).
pub const REFUSED: i64 = -32040;

/// What `config.json` says about First Mate.
#[derive(Clone, Debug, PartialEq)]
pub struct UserConfig {
    pub enabled: bool,
    pub paused: bool,
    pub agent: Agent,
    pub defaults: Autonomy,
    pub agent_yolo: bool,
    /// `first_mate_language`: what the brief and the core's note rows are
    /// written in (`lang`).
    pub language: lang::Lang,
    /// `first_mate_quiet_hours` (`"23:00-08:00"`): the user's own, laid over
    /// every repo's `quiet_hours` (either one holds things back).
    pub quiet_hours: Option<rules::QuietHours>,
}

impl UserConfig {
    pub fn load() -> Self {
        Self::parse(&std::fs::read_to_string(crate::rpc::config_dir().join("config.json")).unwrap_or_default())
    }

    pub fn parse(text: &str) -> Self {
        let v: Value = serde_json::from_str(text).unwrap_or_default();
        let b = |k: &str| v.get(k).and_then(Value::as_bool).unwrap_or(false);
        let autonomy: BTreeMap<String, String> = v
            .get("autopilot_autonomy")
            .and_then(Value::as_object)
            .map(|o| o.iter().filter_map(|(k, x)| x.as_str().map(|s| (k.clone(), s.to_string()))).collect())
            .unwrap_or_default();
        UserConfig {
            enabled: b("autopilot_enabled"),
            paused: b("autopilot_paused"),
            agent: Agent::from_config(v.get("autopilot_agent").and_then(Value::as_str).unwrap_or("claudeCode")),
            defaults: rules::defaults_overriding(&autonomy),
            agent_yolo: b("agent_yolo"),
            language: lang::Lang::parse(v.get("first_mate_language").and_then(Value::as_str)),
            quiet_hours: v.get("first_mate_quiet_hours").and_then(Value::as_str).and_then(rules::QuietHours::parse),
        }
    }
}

/// The policy's answer for one gated call.
#[derive(Clone, Debug, PartialEq)]
pub enum Gate {
    Allow,
    /// Turned into an approval card with this id; nothing ran.
    Queued(String),
    Deny(String),
}

pub enum Msg {
    TaskUnavailable { task: task_sources::Task },
    TasksFetched { results: Vec<task_sources::Fetched> },
    TaskReady { task: task_sources::Task, card: String },
    ResearchLaunched { id: u64, result: Result<research::Run, String> },
    ResearchSeen { worktrees: Vec<String> },
    Research { method: String, params: Value, reply: Sender<RpcResult> },
    Gate { action: Action, method: String, params: Value, reply: Sender<Gate> },
    HabitPropose { habit: Value, reply: Sender<RpcResult> },
    Propose { summary: String, options: Vec<Value>, reply: Sender<RpcResult> },
    State { reply: Sender<Value> },
    /// The user's own words.
    Say { text: String, reply: Sender<bool> },
    /// First Mate's pane changed status.
    Outcome { old: AgentStatus, new: AgentStatus },
    /// A card First Mate raised was answered (None: dismissed), and where
    /// (`_meta.via`), when the client said.
    Answered { payload: String, option: Option<String>, via: Option<String> },
    /// A failed create releases its routing reservation.
    CreateFailed,
    /// A gated call went through.
    DidRun { method: String, result: Value },
    /// An approved or picked call finished.
    Ran { action: Action, what: String, level: &'static str, params: Value, result: Result<Value, String> },
    /// The daily sweep measured, matched and deleted what it may on its own.
    Swept { report: sweep::Report },
    /// A deletion the user approved on a habit card finished.
    HabitDeleted { routed: sweep::Routed, result: Result<(), String> },
    /// The core refused a caller or caught a change it did not make
    /// (`peer.rs`, `.granted.json`): an audit line, and with `note` a line
    /// in the conversation too.
    Security { text: lang::Text, note: bool },
    /// The user asked for the inventory again (`habits.inventory`).
    Inventory { reply: Sender<RpcResult> },
    /// The inventory measured and grouped the worktrees.
    Inventoried { measured: usize, groups: Vec<(inventory::Group, Vec<sweep::Candidate>)> },
    /// The deletions of a group the user said to delete finished.
    InventoryDeleted { group: inventory::Group, report: inventory::DeleteReport },
}

/// How the core reaches First Mate.
#[derive(Clone)]
pub struct Handle(Sender<Msg>);

impl Handle {
    pub fn research(&self, method: &str, params: Value) -> RpcResult {
        self.ask(|reply| Msg::Research { method: method.into(), params, reply }, Err(refused("First Mate is not running")))
    }
    pub fn send(&self, m: Msg) {
        let _ = self.0.send(m);
    }

    fn ask<T>(&self, make: impl FnOnce(Sender<T>) -> Msg, fallback: T) -> T {
        let (tx, rx) = mpsc::channel();
        if self.0.send(make(tx)).is_err() {
            return fallback;
        }
        rx.recv_timeout(Duration::from_secs(10)).unwrap_or(fallback)
    }

    pub fn gate(&self, action: Action, method: &str, params: Value) -> Gate {
        self.ask(|reply| Msg::Gate { action, method: method.into(), params, reply }, Gate::Deny("First Mate is not running".into()))
    }

    pub fn propose(&self, summary: String, options: Vec<Value>) -> RpcResult {
        self.ask(|reply| Msg::Propose { summary, options, reply }, Err(refused("First Mate is not running")))
    }

    pub fn propose_habit(&self, habit: Value) -> RpcResult {
        self.ask(|reply| Msg::HabitPropose { habit, reply }, Err(refused("First Mate is not running")))
    }

    pub fn state(&self) -> Value {
        self.ask(|reply| Msg::State { reply }, json!({"enabled": false, "owner": "core"}))
    }

    pub fn say(&self, text: String) -> bool {
        self.ask(|reply| Msg::Say { text, reply }, false)
    }

    /// Take the inventory again: measure now, then one card per group.
    pub fn inventory(&self) -> RpcResult {
        self.ask(|reply| Msg::Inventory { reply }, Err(refused("First Mate is not running")))
    }
}

/// An audit line written while First Mate is not running (its log is
/// still where the user looks).
pub fn audit_directly(path: &Path, text: &str) {
    Audit::open(path.to_path_buf()).append(&Entry::new(seahelm_core_types::now(), "security", text));
}

pub fn refused(message: impl Into<String>) -> RpcError {
    RpcError { code: REFUSED, message: message.into() }
}

struct Approval {
    action: Action,
    method: String,
    params: Value,
    summary: String,
}

struct Proposal {
    route_text: String,
    summary: String,
    options: Vec<ProposalOption>,
}

struct ProposalOption {
    key: String,
    alias: Option<String>,
    label: String,
    action: Action,
    method: String,
    params: Value,
}

struct FirstMate {
    tasks: task_sources::State,
    tasks_running: bool,
    task_cards: HashMap<String, Vec<task_sources::Task>>,
    task_in_flight: std::collections::BTreeSet<String>,
    core: Arc<Core>,
    tx: Sender<Msg>,
    dir: PathBuf,
    audit: Audit,
    ledger: Ledger,
    detector: Detector,
    config: UserConfig,
    lease: Option<std::fs::File>,
    running: bool,
    launched_at: Option<Instant>,
    queue: Vec<Dispatch>,
    /// A prompt went in and First Mate has not been seen working on it yet.
    awaiting_since: Option<Instant>,
    active_rules: Vec<(Rule, Config)>,
    user_spoke: bool,
    route_text: String,
    route_used: bool,
    route_pending: bool,
    memory: memory::Store,
    alias_pending: HashMap<String, (String, String, String)>,
    #[cfg(test)]
    test_repos: Option<Vec<String>>,
    memory_pending: HashMap<String, (String, String)>,
    approvals: HashMap<String, Approval>,
    habit_proposals: HashMap<String, generalisation::PendingHabit>,
    reported_invalid: HashSet<String>,
    card_options: HashMap<String, Vec<lang::CardOption>>,
    proposals: HashMap<String, Proposal>,
    started: HashSet<String>,
    configs: HashMap<String, (Result<Config, String>, Option<SystemTime>)>,
    /// Per worktree with a PR: its repo and branch, and when that was read.
    git_info: HashMap<String, (String, String, Instant)>,
    last_minute: Option<i64>,
    research: research::State,
    research_minute: Option<i64>,
    research_starting: bool,
    research_launch_id: u64,
    research_launch_at: Option<f64>,
    research_cancel: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
    standing_research: bool,
    latest: Option<(String, String)>,
    next_id: u64,
    /// The habits (`habits`), and the cards about them.
    habits: habits::Store,
    offers: habits::Offers,
    /// Open sweep cards by payload, and per-item cards → (batch, index).
    batches: HashMap<String, sweep::Batch>,
    items: HashMap<String, (String, usize)>,
    sweep_state: sweep::State,
    /// A sweep's thread is measuring since then.
    sweep_running: Option<Instant>,
    /// When `maybe_sweep` last looked at the repos (it runs git).
    sweep_checked: Option<Instant>,
    /// When the habit files were last read for hand-raised levels.
    hand_checked: Option<Instant>,
    /// First Mate was just turned on: sweep without waiting for a new day.
    sweep_forced: bool,
    /// The inventory (`inventory`): its open cards, whether one is due
    /// (First Mate turned on, none ever taken), and since when one measures.
    inventory: inventory::Cards,
    inventory_schedule: inventory::Schedule,
    /// The interruption budget (`budget`, `brief`): the brief's and the
    /// cap's state, the cards held for the brief, when each card went up,
    /// and hand-raised levels whose confirmation expired unanswered.
    budget: budget::State,
    held: Vec<brief::Held>,
    expiry: budget::Expiry,
    expired_confirms: HashSet<(String, String, habits::HabitLevel)>,
    /// Whether seahelm-gateway can reach Telegram now (`gateway.status`):
    /// a brief for Telegram is only sent, and only counts, when it can.
    telegram_ready: Box<dyn Fn() -> bool + Send>,
    telegram_checked: Option<(Instant, bool)>,
}

/// Start First Mate's thread. It does nothing until the config gives it
/// First Mate.
pub fn spawn(core: Arc<Core>) -> Handle {
    let (tx, rx) = mpsc::channel();
    let fm = FirstMate::new(core, tx.clone(), pane::dir(), habits::Store::default_dir());
    let _ = std::thread::Builder::new().name("seahelm-core-first-mate".into()).spawn(move || fm.run(rx));
    Handle(tx)
}

impl FirstMate {
    /// First Mate over `dir` (its session's directory, audit, ledger and
    /// budget) and `habits_dir`; tests give both a scratch directory.
    fn new(core: Arc<Core>, tx: Sender<Msg>, dir: PathBuf, habits_dir: PathBuf) -> FirstMate {
        let audit = Audit::open(dir.join("audit.jsonl"));
        let latest = audit.recent(50).into_iter().rev().find(Entry::is_notable).map(|e| (e.headline(), e.at));
        let research = research::State::load(&dir);
        let research_started = research.active_paths();
        FirstMate {
            tasks: task_sources::State::load(&dir),
            tasks_running: false,
            task_cards: HashMap::new(),
            task_in_flight: std::collections::BTreeSet::new(),
            core: core.clone(),
            tx,
            ledger: Ledger::open(dir.join("state.json")),
            audit,
            budget: budget::State::load(&budget::State::path(&dir)),
            research,
            research_minute: None,
            research_starting: false,
            research_launch_id: 0,
            research_launch_at: None,
            research_cancel: None,
            standing_research: false,
            dir,
            detector: Detector::default(),
            config: UserConfig::parse("{}"),
            lease: None,
            running: false,
            launched_at: None,
            queue: Vec::new(),
            awaiting_since: None,
            active_rules: Vec::new(),
            user_spoke: false,
            route_text: String::new(),
            route_used: false,
            route_pending: false,
            memory: core.memory_store(),
            alias_pending: HashMap::new(),
            #[cfg(test)]
            test_repos: None,
            memory_pending: HashMap::new(),
            approvals: HashMap::new(),
            card_options: HashMap::new(),
            reported_invalid: HashSet::new(),
            habit_proposals: HashMap::new(),
            proposals: HashMap::new(),
            started: research_started,
            configs: HashMap::new(),
            git_info: HashMap::new(),
            last_minute: None,
            latest,
            next_id: 0,
            sweep_state: sweep::State::load(&sweep::State::path(&habits_dir)),
            habits: habits::Store::new(habits_dir),
            offers: habits::Offers::default(),
            batches: HashMap::new(),
            items: HashMap::new(),
            sweep_running: None,
            sweep_checked: None,
            hand_checked: None,
            sweep_forced: false,
            inventory: inventory::Cards::default(),
            inventory_schedule: inventory::Schedule::default(),
            held: Vec::new(),
            expiry: budget::Expiry::default(),
            expired_confirms: HashSet::new(),
            telegram_ready: Box::new(brief::telegram_ready),
            telegram_checked: None,
        }
    }
}

const TICK: Duration = Duration::from_secs(20);

impl FirstMate {
    fn run(mut self, rx: Receiver<Msg>) {
        let mut last_tick: Option<Instant> = None;
        loop {
            let wait = last_tick.map(|t| TICK.saturating_sub(t.elapsed())).unwrap_or_default();
            match rx.recv_timeout(wait) {
                Ok(m) => self.handle(m),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            if last_tick.is_none_or(|t| t.elapsed() >= TICK) {
                last_tick = Some(Instant::now());
                self.tick(seahelm_core_types::now());
            }
        }
    }

    fn handle(&mut self, m: Msg) {
        let now = seahelm_core_types::now();
        match m {
            Msg::TaskUnavailable { task } => self.task_unavailable(&task),
            Msg::TasksFetched { results } => self.tasks_fetched(results),
            Msg::TaskReady { task, card } => self.start_task_ready(task, card),
            Msg::ResearchLaunched { id, result } => self.research_launched(id, result, now),
            Msg::ResearchSeen { worktrees } => {
                self.research.seen(&worktrees);
                self.research.save(&self.dir);
            }
            Msg::Research { method, params, reply } => {
                let result = self.research_rpc(&method, &params, now);
                let _ = reply.send(result);
            }
            Msg::Gate { action, method, params, reply } => {
                let _ = reply.send(self.gate(action, &method, &params, now));
            }
            Msg::HabitPropose { habit, reply } => { let _ = reply.send(self.propose_habit(habit, now)); }
            Msg::Propose { summary, options, reply } => {
                let _ = reply.send(self.propose(&summary, &options, now));
            }
            Msg::State { reply } => {
                let _ = reply.send(self.state_json());
            }
            Msg::Say { text, reply } => {
                let _ = reply.send(self.say(&text, now));
            }
            Msg::Outcome { old, new } => {
                if new == AgentStatus::Running {
                    self.awaiting_since = None;
                }
                // A finished turn closes the events it was about.
                if new == AgentStatus::Idle && old == AgentStatus::Running && self.awaiting_since.is_none() {
                    self.active_rules.clear();
                    self.user_spoke = false;
                    self.core.set_user_turn(None);
                }
                self.deliver_if_ready(now);
            }
            Msg::Answered { payload, option, via } => self.answered(&payload, option.as_deref(), via, now),
            Msg::CreateFailed => self.route_pending = false,
            Msg::DidRun { method, result } => self.did_run(&method, &result),
            Msg::Ran { action, what, level, params, result } => {
                if let Some(task) = params.get("_task").and_then(|v| serde_json::from_value(v.clone()).ok()) {
                    self.task_finished(&task, result.is_ok(), now);
                }
                let outcome = match &result {
                    Ok(r) => {
                        if let Some(m) = r.get("_method").and_then(Value::as_str) {
                            self.did_run(m, r);
                        }
                        compact(r)
                    }
                    Err(e) => format!("failed: {e}"),
                };
                let mut e = Entry::new(now, "action", format!("{what} — {outcome}"));
                e.action = Some(action.as_str().into());
                e.level = Some(level.into());
                self.annotate(&mut e, action, &params);
                self.log(e);
                let verb = if level == "picked" { format!("picked \"{what}\"") } else { format!("approved: {what}") };
                self.tell(&format!("[seahelm] The user {verb}\nResult: {outcome}"));
            }
            Msg::Swept { report } => self.swept(report, now),
            Msg::HabitDeleted { routed, result } => self.habit_deleted(routed, result, now),
            Msg::Security { text, note } => {
                if note {
                    self.core.first_mate_line(text.get(self.config.language));
                }
                self.log(Entry::new(now, "security", text.en));
            }
            Msg::Inventory { reply } => {
                let _ = reply.send(self.request_inventory(now));
            }
            Msg::Inventoried { measured, groups } => self.inventoried(measured, groups, now),
            Msg::InventoryDeleted { group, report } => self.inventory_deleted(group, report, now),
        }
    }

    // MARK: lifecycle

    fn tick(&mut self, now: f64) {
        // Reading the grants checks their seal; a change the core did not
        // make was put back, and the user hears it here.
        self.habits.check_grants();
        for text in habits::take_tamper_reports(Some(&self.habits.dir)) {
            self.core.first_mate_line(text.get(self.config.language));
            self.log(Entry::new(now, "security", text.en));
        }
        let config = UserConfig::load();
        if config.defaults != self.config.defaults {
            self.configs.clear();
        }
        let switched = config.agent != self.config.agent;
        self.config = config;
        let want = self.config.enabled;
        if want && !self.running {
            self.start();
        } else if !want && self.running {
            self.stop();
        }
        if !want && self.budget.review_enabled_at > 0.0 {
            self.budget.review_enabled_at = 0.0;
            self.save_budget();
        }
        if !self.running { return; }
        if self.budget.review_enabled_at <= 0.0 {
            self.budget.review_enabled_at = now;
            self.save_budget();
        }
        if switched {
            self.launched_at = None;
        }
        self.ensure_session();
        self.observe_prs(now);
        self.check_schedules(now);
        self.research_tick(now);
        self.maybe_inventory(now);
        self.maybe_sweep(now);
        self.check_hand_edits(now);
        self.check_memory_edits(now);
        self.expire_cards(now);
        self.poll_tasks(now);
        self.maybe_brief(now);
        self.release_held(now);
        if self.awaiting_since.is_some_and(|t| t.elapsed() > Duration::from_secs(120)) {
            // The prompt never started a turn (lost on the way): try again.
            self.awaiting_since = None;
        }
        self.deliver_if_ready(now);
    }

    fn start(&mut self) {
        let _ = std::fs::create_dir_all(&self.dir);
        let Ok(file) = std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(self.dir.join("owner.lock")) else { return };
        if file.try_lock().is_err() {
            eprintln!("seahelm-core: First Mate is someone else's (owner.lock held)");
            return;
        }
        self.lease = Some(file);
        self.running = true;
        let now = seahelm_core_types::now();
        if let Err(e) = self.habits.ensure_seed(&Local::at(now).day_key(), now) {
            eprintln!("seahelm-core: habits: {e}");
        }
        self.sweep_forced = self.sweep_state.sweep_on_start(now);
        self.inventory_schedule.turned_on(&self.sweep_state);
        eprintln!("seahelm-core: running First Mate");
    }

    fn stop(&mut self) {
        let ids: Vec<String> = self.approvals.keys().chain(self.proposals.keys()).chain(self.habit_proposals.keys()).chain(self.memory_pending.keys()).chain(self.alias_pending.keys()).cloned().collect();
        for id in ids {
            self.core.drop_card_payload(&id);
        }
        for id in std::mem::take(&mut self.task_cards).keys() { self.core.drop_card_payload(id); }
        self.task_in_flight.clear();
        self.approvals.clear();
        self.proposals.clear();
        self.habit_proposals.clear();
        self.card_options.clear();
        self.memory_pending.clear();
        self.alias_pending.clear();
        self.drop_habit_cards();
        for h in std::mem::take(&mut self.held) {
            self.core.drop_card_payload(&h.payload);
        }
        self.expiry.clear();
        self.active_rules.clear();
        self.queue.clear();
        self.awaiting_since = None;
        self.running = false;
        self.lease = None;
        self.core.unregister_pane(policy::SESSION);
        eprintln!("seahelm-core: First Mate stopped");
    }

    /// The session exists and hosts First Mate's agent. A session without
    /// it (an exit, a bare shell), or launched for another agent or an older
    /// version, is replaced.
    fn ensure_session(&mut self) {
        let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("seahelm-core"));
        pane::provision(&self.dir, &exe, self.config.language);
        let agent = self.config.agent;
        let young = self.launched_at.is_some_and(|t| t.elapsed() < Duration::from_secs(60));
        let mut exists = seahelmd::client::connect(policy::SESSION).is_ok();
        let has_agent = self.core.pane_agent(policy::SESSION).is_some_and(|a| a.is_ai_agent());
        if exists && (!pane::session_is_current(&self.dir, agent, self.config.language) || (!young && self.launched_at.is_some() && !has_agent)) {
            let _ = seahelmd::client::request(policy::SESSION, &seahelmd::proto::Msg::Kill);
            let deadline = Instant::now() + Duration::from_secs(5);
            while seahelmd::client::connect(policy::SESSION).is_ok() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(100));
            }
            exists = false;
        }
        if !exists {
            pane::mark_session_current(&self.dir, agent, self.config.language);
            let out = std::process::Command::new(crate::actions::seahelmd_bin())
                .current_dir(&self.dir)
                .args(["new", "--hold", "10", policy::SESSION, "--"])
                .args(pane::session_argv(&self.dir, agent))
                .output();
            match out {
                Ok(o) if o.status.success() => self.launched_at = Some(Instant::now()),
                Ok(o) => eprintln!("seahelm-core: First Mate session: {}", String::from_utf8_lossy(&o.stderr).trim()),
                Err(e) => eprintln!("seahelm-core: First Mate session: {e}"),
            }
        } else if self.launched_at.is_none() {
            // Already there from an earlier run: judge it as an old session.
            self.launched_at = Some(Instant::now() - Duration::from_secs(120));
        }
        self.core.ensure_first_mate_pane(&self.dir.to_string_lossy());
    }

    // MARK: events

    /// Every worktree with a PR, as of the core's last look.
    fn observe_prs(&mut self, now: f64) {
        let mut obs = Vec::new();
        for (worktree, pr) in self.core.worktree_prs() {
            if Path::new(&worktree) == self.dir {
                continue;
            }
            let fresh = self.git_info.get(&worktree).is_some_and(|(_, _, at)| at.elapsed() < Duration::from_secs(300));
            if !fresh {
                let wt = Path::new(&worktree);
                let common = facts::git(wt, &["rev-parse", "--path-format=absolute", "--git-common-dir"]);
                let repo = common.and_then(|c| Path::new(c.trim()).parent().map(|p| p.to_string_lossy().into_owned())).unwrap_or_default();
                let branch = facts::git(wt, &["rev-parse", "--abbrev-ref", "HEAD"]).map(|b| b.trim().to_string()).unwrap_or_default();
                self.git_info.insert(worktree.clone(), (repo, branch, Instant::now()));
            }
            let (repo, branch, _) = self.git_info[&worktree].clone();
            // The main checkout is not PR work.
            if repo.is_empty() || branch.is_empty() || branch == "HEAD" || same_path(&repo, &worktree) {
                continue;
            }
            obs.push(Observation { worktree, repo, branch, pr: Some(pr) });
        }
        let ledger = &self.ledger;
        let events = self.detector.observe(&obs, |k| ledger.merge_handled(k));
        for e in events {
            self.on_event(e, now);
        }
    }

    /// Fire the schedule rules whose cron matches this minute, once. Missed
    /// minutes are not caught up: a morning triage at noon is not what anyone
    /// asked for.
    fn check_schedules(&mut self, now: f64) {
        let minute = (now / 60.0).floor() as i64;
        if self.last_minute == Some(minute) {
            return;
        }
        self.last_minute = Some(minute);
        let local = Local::at(now);
        for repo in self.core.repos() {
            let Ok(config) = self.config_for(&repo) else { continue };
            let mut crons: Vec<String> = config
                .rules
                .iter()
                .filter(|r| r.enabled)
                .filter_map(|r| match &r.trigger {
                    Trigger::Schedule(c) if Cron::parse(c).is_some_and(|c| c.matches(&local)) => Some(c.clone()),
                    _ => None,
                })
                .collect();
            crons.sort();
            crons.dedup();
            for cron in crons {
                let e = Event { trigger: Trigger::Schedule(cron), repo: repo.clone(), worktree: repo.clone(), branch: String::new(), pr: None, facts: None };
                self.on_event(e, now);
            }
        }
    }

    fn on_event(&mut self, mut event: Event, now: f64) {
        if event.trigger == Trigger::PrMerged {
            if let Some(pr) = &event.pr {
                self.ledger.mark_merge_handled(&engine::merged_key(&event.repo, pr.number));
            }
        }
        if matches!(event.trigger, Trigger::PrMerged | Trigger::CiFailed) && event.facts.is_none() {
            event.facts = Some(self.core.measure_worktree(&event.worktree, event.pr.as_ref()));
        }
        // A merged worktree someone worked in today is not asked about now:
        // its pane being idle between turns is not nobody using it, and every
        // merge from it asked again. The daily sweep takes it once it has been
        // idle a day (delete-merged-clean wants idle_days >= 1).
        if event.trigger == Trigger::PrMerged && event.facts.as_ref().is_some_and(|f| f.idle_days == Some(0)) {
            let mut entry = Entry::new(now, "skipped", format!("pr.merged · {} active today — left for the sweep", short(&event.worktree)));
            entry.worktree_path = Some(event.worktree.clone());
            entry.pr = event.pr.as_ref().map(|p| p.number);
            self.log(entry);
            return;
        }
        let config = match self.config_for(&event.repo) {
            Ok(c) => c,
            Err(e) => {
                let mut entry = Entry::new(now, "skipped", format!("{} ignored — {e}", event.trigger.event_name()));
                entry.worktree_path = Some(event.worktree.clone());
                entry.pr = event.pr.as_ref().map(|p| p.number);
                self.log(entry);
                return;
            }
        };
        let day = Local::at(now).day_key();
        let quiet = self.quiet_now(config.settings.quiet_hours, now);
        for d in engine::dispatches(&event, &config, &self.ledger, &day) {
            if let Some(pr) = &event.pr {
                self.ledger.record_attempt(&d.rule.name, &event.repo, pr.number, &day);
            }
            let mut text = format!("{} · {}", event.trigger.event_name(), short(&event.worktree));
            if let Some(pr) = &event.pr {
                text += &format!(" · PR #{}", pr.number);
            }
            if let Some(f) = &event.facts {
                text += &format!(" — {}", f.summary());
            }
            if quiet {
                text += " (quiet hours — queued)";
            }
            let mut entry = Entry::new(now, "event", text);
            entry.rule = Some(d.rule.name.clone());
            entry.worktree_path = Some(event.worktree.clone());
            entry.pr = event.pr.as_ref().map(|p| p.number);
            self.log(entry);
            self.queue.push(d);
        }
        self.deliver_if_ready(now);
    }

    /// A repo's rules, re-read when the file changes; the user's defaults
    /// laid under them.
    fn config_for(&mut self, repo: &str) -> Result<Config, String> {
        let path = Path::new(repo).join(rules::RELATIVE_PATH);
        let mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        if let Some((c, m)) = self.configs.get(repo) {
            if *m == mtime {
                return c.clone();
            }
        }
        let mut loaded = Config::load(Path::new(repo));
        if let Ok(c) = &mut loaded {
            c.defaults = self.config.defaults.clone();
        }
        self.configs.insert(repo.to_string(), (loaded.clone(), mtime));
        loaded
    }

    /// A repo's quiet hours, or the user's own (`first_mate_quiet_hours`).
    fn quiet_now(&self, repo: Option<rules::QuietHours>, now: f64) -> bool {
        let local = Local::at(now);
        repo.is_some_and(|q| q.contains(&local)) || self.config.quiet_hours.is_some_and(|q| q.contains(&local))
    }

    // MARK: delivery

    fn deliver_if_ready(&mut self, now: f64) {
        if !self.running || self.config.paused || self.awaiting_since.is_some() {
            return;
        }
        if self.core.pane_status(policy::SESSION) != Some(AgentStatus::Idle) {
            return;
        }
        if self.queue.is_empty() {
            self.review_if_due(now);
            return;
        }
        let local = Local::at(now);
        let mut ready = Vec::new();
        let mut held = Vec::new();
        for d in std::mem::take(&mut self.queue) {
            let repo_quiet = self.config_for(&d.event.repo).ok().and_then(|c| c.settings.quiet_hours);
            let quiet = repo_quiet.is_some_and(|q| q.contains(&local)) || self.config.quiet_hours.is_some_and(|q| q.contains(&local));
            if quiet {
                held.push(d);
            } else {
                ready.push(d);
            }
        }
        self.queue = held;
        if ready.is_empty() {
            return;
        }
        let text = ready.iter().map(|d| { let memory = self.memory.context(&d.event.repo); if memory.is_empty() { d.prompt.clone() } else { format!("{}\n\n[seahelm project memory]\n{}",d.prompt,memory) } }).collect::<Vec<_>>().join("\n\n---\n\n");
        for d in &ready {
            if let Ok(c) = self.config_for(&d.event.repo) {
                self.active_rules.push((d.rule.clone(), c));
            }
        }
        self.tell(&text);
        for d in ready {
            let mut e = Entry::new(now, "delivered", "handed to First Mate");
            e.rule = Some(d.rule.name);
            e.worktree_path = Some(d.event.worktree);
            e.pr = d.event.pr.map(|p| p.number);
            self.log(e);
        }
    }

    /// Into First Mate's composer, now: an answer to what it asked, or the
    /// user's words, must reach it whatever it is doing.
    fn tell(&mut self, text: &str) {
        if !self.running {
            return;
        }
        self.awaiting_since = Some(Instant::now());
        let send = |b: &[u8]| seahelmd::client::request(policy::SESSION, &seahelmd::proto::Msg::Send(b.to_vec()));
        if send(text.as_bytes()).is_ok() {
            std::thread::sleep(Duration::from_millis(80));
            let _ = send(b"\r");
        }
    }

    fn say(&mut self, text: &str, now: f64) -> bool {
        let t = text.trim();
        if !self.running || t.is_empty() {
            return false;
        }
        self.research.followup(t);
        self.research.save(&self.dir);
        self.user_spoke = true;
        self.route_text = t.into();
        self.core.set_user_turn(Some(t.to_string()));
        self.route_used = false;
        self.route_pending = false;
        self.tell(&format!("{}\n\n[seahelm projects] {}", t, self.project_list()));
        self.log(Entry::new(now, "message", t));
        true
    }

    // MARK: gate

    /// The strictest of the rules First Mate is working on, plus the user's
    /// defaults once the user has spoken (talking cannot loosen a rule) or
    /// when it acts on nothing in particular.
    fn level(&self, action: Action) -> Level {
        let mut levels: Vec<Level> = self.active_rules.iter().map(|(r, c)| c.autonomy(action, Some(r))).collect();
        if self.user_spoke || levels.is_empty() {
            levels.push(self.config.defaults.get(&action).copied().unwrap_or(Level::Ask));
        }
        levels.into_iter().max().unwrap_or(Level::Ask)
    }

    fn gate(&mut self, action: Action, method: &str, params: &Value, now: f64) -> Gate {
        if !self.running {
            return Gate::Deny("First Mate is off".into());
        }
        if self.config.paused {
            return Gate::Deny("First Mate is paused".into());
        }
        // Described with the pane as the user knows it, never a raw id.
        let shown = self.with_pane_label(params);
        let mut summary = policy::describe(method, &shown, params.get("_facts").and_then(Value::as_str));
        if let Some(id) = params.get("habit").and_then(Value::as_str) { summary = format!("{summary} [habit: {id}]"); }
        let deny = |fm: &mut Self, level: Option<&str>, text: String| {
            let mut e = Entry::new(now, "denied", text);
            e.action = Some(action.as_str().into());
            e.level = level.map(str::to_string);
            fm.log(e);
        };
        if action == Action::StartAgent {
            if let Some(why) = self.budget_refusal(params) {
                deny(self, None, format!("{summary} — {why}"));
                return Gate::Deny(why);
            }
        }
        if action == Action::StartAgent && !self.standing_research {
            if let Some(g) = self.route_gate(params, now) { return g; }
        }
        let mut level = self.level(action);
        if let Some(id) = params.get("habit").and_then(Value::as_str) {
            let habit = self.habits.all(&Self::today(now)).into_iter().find_map(|book| {
                book.get(id).filter(|h| h.active()).map(|h| (h.clone(), book.level(h)))
            });
            let Some((habit, granted)) = habit else { return Gate::Deny("unknown habit".into()); };
            if granted < habits::HabitLevel::Ask || habit.act != habits::Do::DeleteWorktree || action != Action::DeleteWorktree {
                return Gate::Deny("habit does not grant this action".into());
            }
            if level == Level::Auto { level = Level::Ask; }
        }
        if self.standing_research && action == Action::StartAgent && level != Level::Deny { return Gate::Allow; }
        match level {
            Level::Auto => {
                let mut e = Entry::new(now, "action", summary);
                e.action = Some(action.as_str().into());
                e.level = Some("auto".into());
                self.annotate(&mut e, action, params);
                self.log(e);
                Gate::Allow
            }
            Level::Deny => {
                deny(self, Some("deny"), summary);
                Gate::Deny(format!("{} is set to deny", action.as_str()))
            }
            Level::Ask => {
                let id = self.mint("autopilot");
                // The user's own request is waiting on it: up at once, not
                // counted. So is a CI failure's (it cannot wait for the
                // brief; seahelm-gateway sends every First Mate card to
                // Telegram as it goes up). Any other rule's ask is First
                // Mate's initiative.
                let class = if self.user_spoke {
                    budget::Class::Answering
                } else if self.active_rules.iter().any(|(r, _)| r.trigger == Trigger::CiFailed) {
                    budget::Class::TimeSensitive
                } else {
                    budget::Class::Proactive
                };
                let lang = self.config.language;
                self.put_card(CardKind::Approval, &id, format!("{}{}", lang.pick("First Mate asks: ", "First Mate 请示："), lang::with_habit(brief::describe_action(lang, action, &shown).unwrap_or(summary.clone()), params.get("habit").and_then(Value::as_str), lang)), vec![APPROVE.into(), REJECT.into()], class, now);
                let mut e = Entry::new(now, "approval", summary.clone());
                e.action = Some(action.as_str().into());
                e.level = Some("ask".into());
                self.log(e);
                self.approvals.insert(id.clone(), Approval { action, method: method.into(), params: params.clone(), summary });
                Gate::Queued(id)
            }
        }
    }

    fn budget_refusal(&mut self, params: &Value) -> Option<String> {
        let repo = params.get("repo_path").and_then(Value::as_str).unwrap_or_default().to_string();
        let settings = self.config_for(&repo).map(|c| c.settings).unwrap_or_default();
        if let Some(cap) = settings.max_concurrent_agents {
            let live = self.core.live_worktrees();
            let n = self.started.iter().filter(|w| live.contains(*w)).count() as u32;
            if n >= cap {
                return Some(format!("max_concurrent_agents ({cap}) reached"));
            }
        }
        if let (Some(limit), Some(used)) = (settings.pause_above_usage, usage_percent()) {
            if used >= limit {
                return Some(format!("usage at {used:.0}% is above pause_above_usage ({limit:.0}%)"));
            }
        }
        None
    }

    fn did_run(&mut self, method: &str, result: &Value) {
        if method == "worktree.create" {
            self.route_pending = false;
            if let Some(p) = result.get("worktree_path").and_then(Value::as_str) {
                self.route_used = true;
                self.started.insert(p.to_string());
                self.core.first_mate_line(lang::route_started(p).get(self.config.language));
            }
        }
    }

    // MARK: proposals

    fn propose(&mut self, summary: &str, raw: &[Value], now: f64) -> RpcResult {
        if !self.running {
            return Err(refused("First Mate is off"));
        }
        let mut options = Vec::new();
        for (i, o) in raw.iter().enumerate() {
            let label = o.get("label").and_then(Value::as_str).map(str::trim).unwrap_or_default();
            let method = o.get("action").and_then(Value::as_str).unwrap_or_default();
            if label.is_empty() || method.is_empty() {
                return Err(RpcError::invalid_params(format!("option {} needs a label and an action", i + 1)));
            }
            let policy::Class::Gated(action) = policy::classify(method) else {
                return Err(refused(format!("option {}: {method} cannot be proposed", i + 1)));
            };
            if self.level(action) == Level::Deny {
                return Err(refused(format!("option {}: {} is set to deny", i + 1, action.as_str())));
            }
            if action == Action::StartAgent {
                let repo = o.pointer("/params/repo_path").and_then(Value::as_str).unwrap_or_default();
                if Path::new(repo).join(rules::RELATIVE_PATH).exists() {
                    if self.config_for(repo).map(|c| c.autonomy(action, None) == Level::Deny).unwrap_or(true) {
                        return Err(refused(lang::route_unknown().get(self.config.language)));
                    }
                }
            }
            options.push(ProposalOption { key: format!("choice:{i}"), alias: o.get("alias").and_then(Value::as_str).map(str::to_string), label: label.into(), action, method: method.into(), params: o.get("params").cloned().unwrap_or(json!({})) });
        }
        if options.is_empty() || options.len() > 5 {
            return Err(RpcError::invalid_params("between one and five options"));
        }
        let id = self.mint("proposal");
        let mut labels: Vec<String> = options.iter().map(|o| o.label.clone()).collect();
        labels.push(NOT_NOW.into());
        let class = if self.user_spoke { budget::Class::Answering } else { budget::Class::Proactive };
        self.put_card(CardKind::Proposal, &id, format!("{}{summary}", self.config.language.pick("First Mate suggests: ", "First Mate 建议：")), labels, class, now);
        self.log(Entry::new(now, "approval", format!("proposed: {summary}")));
        self.proposals.insert(id.clone(), Proposal { route_text: if self.user_spoke { self.route_text.clone() } else { String::new() }, summary: summary.into(), options });
        Ok(json!({"queued": "proposal", "card": id, "message": "Shown to the user; you will be told what they picked."}))
    }

    /// The user answered one of First Mate's cards.
    fn answered(&mut self, payload: &str, option: Option<&str>, via: Option<String>, now: f64) {
        let canonical = option.map(|answer| {
            self.card_options.get(payload).and_then(|options| options.iter()
                .find(|option| option.label == answer)
                .map(|option| option.key.clone())).unwrap_or_else(|| lang::option_key(answer))
        });
        let option = canonical.as_deref();
        if let (Some(age), Some(key)) = (self.expiry.age(payload, now), option) {
            let accepted = matches!(key,"approve" | "delete" | "delete_all") || key.starts_with("yes:") || key.starts_with("choice:");
            let evidence = if payload.starts_with(habits::PROMOTE_PREFIX) && payload.contains(":auto:") {
                tuning::Evidence::Promotion(accepted)
            } else if self.habit_proposals.contains_key(payload) || self.proposals.contains_key(payload)
                || payload.starts_with(habits::PROMOTE_PREFIX) || payload.starts_with(sweep::SWEEP_PREFIX) {
                tuning::Evidence::Suggestion(accepted)
            } else { tuning::Evidence::Answer };
            let notes = self.budget.tuned.record(evidence, Some(age));
            for note in notes { self.log(Entry::new(now, "tuning", note.en.clone())); self.budget.note(note); }
            self.save_budget();
        }
        self.card_options.remove(payload);
        self.expiry.forget(payload);
        if let Some((repo, digest)) = self.memory_pending.remove(payload) {
            let approve = option == Some("approve");
            let verdict = match option { Some("approve") => "approved", None => "dismissed", _ => "rejected" };
            self.log(Entry::new(now, "memory", format!("{verdict} an outside edit of {repo}'s memory ({})", &digest[..digest.len().min(12)])));
            self.observe_habit_answer("memory.confirm", payload, option, via.clone(), format!("outside edit of {repo}'s memory"), String::new(), repo.clone());
            let result = memory::answer_edit(&self.memory,&repo,&digest,approve);
            if let Err(e) = result { self.core.first_mate_line(lang::memory_failure(&e).get(self.config.language)); }
            return;
        }
        if self.answer_alias(payload, option, now) { return; }
        if let Some(pending) = self.habit_proposals.remove(payload) {
            self.observe_habit_answer("habit.propose", payload, option, via.clone(), format!("propose habit {}", pending.habit.id), format!("{}/{}", pending.key, pending.habit.id), String::new());
            if option == Some("approve") {
                let mut book = self.habits.load(&pending.key, &Self::today(now));
                let grant = habits::Grant::from_inventory_card(&pending.key, &pending.habit.id, pending.habit.level);
                if book.adopt_proposal(pending.habit, grant, &Self::today(now)).is_ok() {
                    if let Some(repo) = pending.repo { self.habits.remember_repo(&pending.key, &repo); }
                    self.save_book(&book, now);
                    self.log(Entry::new(now, "habit", format!("accepted habit proposal {payload}")));
                }
            }
            return;
        }
        if self.answer_task(payload, option, now) { return; }
        if self.research_answer(payload, option) { return; }
        if self.answered_habit(payload, option, via.clone(), now) {
            return;
        }
        // A delete approval is evidence for the habit its facts match.
        let habit = match self.approvals.get(payload) {
            Some(a) if a.action == Action::DeleteWorktree => {
                let params = a.params.clone();
                self.count_delete_approval(&params, option == Some("approve"), now)
            }
            _ => None,
        };
        self.observe_answer(payload, option, via, habit);
        if let Some(a) = self.approvals.remove(payload) {
            if option != Some("approve") {
                let mut e = Entry::new(now, "denied", format!("rejected: {}", a.summary));
                e.action = Some(a.action.as_str().into());
                self.log(e);
                self.tell(&format!("[seahelm] The user rejected: {}", a.summary));
                return;
            }
            self.execute(a.action, a.method, a.params, a.summary, "approved", payload);
            return;
        }
        let Some(p) = self.proposals.remove(payload) else { return };
        let Some(o) = p.options.into_iter().find(|o| Some(o.key.as_str()) == option) else {
            self.log(Entry::new(now, "denied", format!("not now: {}", p.summary)));
            self.tell(&format!("[seahelm] The user passed on your proposal: {}", p.summary));
            return;
        };
        // The level may have changed since the card went up.
        if self.level(o.action) == Level::Deny {
            let mut e = Entry::new(now, "denied", format!("{} — {} is set to deny", o.label, o.action.as_str()));
            e.action = Some(o.action.as_str().into());
            self.log(e);
            self.tell(&format!("[seahelm] The user picked \"{}\" but {} is set to deny; nothing ran.", o.label, o.action.as_str()));
            return;
        }
        if o.action == Action::StartAgent {
            if let Some(why) = self.budget_refusal(&o.params) {
                self.core.first_mate_line(lang::memory_failure(&why).get(self.config.language));
                return;
            }
            let repo=o.params["repo_path"].as_str().unwrap_or_default();
            self.route_pick(repo, &p.route_text, payload, now);
            if let Some(alias)=o.alias.as_deref() { self.offer_alias(repo,alias,payload,now); }
        }
        self.execute(o.action, o.method, o.params, o.label, "picked", payload);
    }

    /// The answer as evidence (`observations`): which card, what was picked, where.
    fn observe_answer(&self, payload: &str, option: Option<&str>, via: Option<String>, habit: Option<String>) {
        let s = |p: &Value, k: &str| p.get(k).and_then(Value::as_str).unwrap_or_default().to_string();
        let msg = if let Some(a) = self.approvals.get(payload) {
            observations::Msg::CardAnswered {
                card_kind: "approval",
                card: payload.into(),
                option: option.map(str::to_string),
                via,
                summary: a.summary.clone(),
                action: Some(a.action.as_str().into()),
                worktree: s(&a.params, "worktree_path"),
                repo: s(&a.params, "repo_path"),
                habit,
            }
        } else if let Some(p) = self.proposals.get(payload) {
            let picked = p.options.iter().find(|o| Some(o.key.as_str()) == option);
            observations::Msg::CardAnswered {
                card_kind: "proposal",
                card: payload.into(),
                option: option.map(str::to_string),
                via,
                summary: p.summary.clone(),
                action: picked.map(|o| o.action.as_str().into()),
                worktree: picked.map(|o| s(&o.params, "worktree_path")).unwrap_or_default(),
                repo: picked.map(|o| s(&o.params, "repo_path")).unwrap_or_default(),
                habit: None,
            }
        } else {
            return;
        };
        self.core.observe(msg);
    }

    /// Run a call as the user's, off this thread; the outcome comes back as
    /// `Msg::Ran`.
    /// `params` with `pane_id` replaced by the pane as the user knows it
    /// (`#7 · feat-x`), for descriptions only.
    fn with_pane_label(&self, params: &Value) -> Value {
        let mut shown = params.clone();
        if let Some(label) = params.get("pane_id").and_then(Value::as_str).and_then(|p| self.core.pane_label(p)) {
            shown["pane_id"] = json!(label);
        }
        shown
    }

    /// The structured side of an action's audit line, which the brief
    /// describes in the user's language (`brief::describe_entry`).
    fn annotate(&self, e: &mut Entry, action: Action, params: &Value) {
        let s = |k: &str| params.get(k).and_then(Value::as_str).filter(|v| !v.is_empty()).map(str::to_string);
        match action {
            Action::MessagePane => {
                e.pane = s("pane_id").map(|p| self.core.pane_label(&p).unwrap_or(p));
                e.detail = s("command").or_else(|| s("text")).or_else(|| {
                    params.get("keys").and_then(Value::as_array).map(|k| k.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "))
                });
            }
            Action::StartAgent => {
                e.worktree_path = e.worktree_path.take().or_else(|| s("repo_path"));
                e.detail = s("prompt");
            }
            Action::DeleteWorktree => {
                e.worktree_path = e.worktree_path.take().or_else(|| s("worktree_path"));
            }
        }
    }

    fn execute(&self, action: Action, method: String, params: Value, what: String, level: &'static str, card: &str) {
        let core = self.core.clone();
        let tx = self.tx.clone();
        let card = card.to_string();
        std::thread::spawn(move || {
            let result = if method == "worktree.create" {
                crate::actions::worktree_create_first_mate(&core, &policy::as_user(&params))
            } else {
                core.act(&method, &policy::as_user(&params))
            };
            if let Ok(r) = &result {
                core.note_performed(&method, &params, r, observations::By::FirstMate, Some(level), Some(&card), None);
            }
            let result = result.map(|mut r| {
                r["_method"] = json!(method);
                r
            });
            let _ = tx.send(Msg::Ran { action, what, level, params, result: result.map_err(|e| e.message) });
        });
    }

    // MARK: state

    /// First Mate as a client draws it (`autopilot.state`, the app's shape).
    fn state_json(&self) -> Value {
        let status = self.core.pane_status(policy::SESSION);
        let (activity, tone) = if !self.running {
            ("off", "quiet")
        } else if self.config.paused {
            ("paused", "quiet")
        } else {
            match status {
                Some(AgentStatus::Running) => ("thinking", "working"),
                Some(AgentStatus::Waiting) | Some(AgentStatus::Error) => ("needs you", "wants_you"),
                Some(AgentStatus::Idle) => ("watching", "watching"),
                _ => ("starting", "quiet"),
            }
        };
        let cards: Vec<Value> = self
            .core
            .cards_with_payloads(|p| self.approvals.contains_key(p) || self.proposals.contains_key(p) || self.is_habit_card(p))
            .into_iter()
            .map(|c| {
                json!({"card": c["payload"], "id": c["id"], "kind": c["kind"], "message": c["message"], "options": c["options"]})
            })
            .collect();
        // Cards up, not those held for the brief: those wait for it.
        let pending = cards.len();
        let tone = if pending > 0 { "wants_you" } else { tone };
        let detail = match (&self.latest, self.queue.len()) {
            (_, q) if q > 0 => format!("{q} queued"),
            (Some((text, _)), _) => text.clone(),
            _ => String::new(),
        };
        let mut v = json!({
            "enabled": self.running,
            "owner": "core",
            "activity": activity,
            "tone": tone,
            "detail": detail,
            "pending": pending,
            "queued": self.queue.len(),
            "agent": self.config.agent.raw(),
            "language": self.config.language.pick("en", "zh"),
            "cards": cards,
            "held": self.held.len(),
        });
        if self.running {
            v["pane"] = json!({
                "pane_id": policy::SESSION, "pane_session_key": policy::SESSION,
                "worktree_path": self.dir, "project": pane::PROJECT, "branch": "",
                "status": status.map(|s| s.as_str()).unwrap_or("Unknown"), "first_mate": true,
            });
        }
        v
    }

    fn log(&mut self, e: Entry) {
        if e.is_notable() {
            self.latest = Some((e.headline(), e.at.clone()));
        }
        self.audit.append(&e);
        if let Ok(entry) = serde_json::to_value(&e) {
            self.core.publish_event(json!({"type": "autopilot.audit", "entry": entry}));
        }
    }

    fn mint(&mut self, prefix: &str) -> String {
        self.next_id += 1;
        let seed = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        format!("{prefix}-{:08x}", (seed as u64 ^ (self.next_id << 32)) as u32)
    }
}

/// A call's result in words, for the audit line and First Mate.
pub fn compact(r: &Value) -> String {
    let name = r.get("worktree_path").and_then(Value::as_str).map(short);
    if r.get("deleted").and_then(Value::as_bool) == Some(true) {
        return format!("deleted {}", name.unwrap_or_else(|| "the worktree".into()));
    }
    if r.get("pane_session_key").is_some() {
        if let Some(n) = name {
            return format!("started in {n}");
        }
    }
    if r.get("sent").and_then(Value::as_bool) == Some(true) || r.get("ok").and_then(Value::as_bool) == Some(true) {
        return "sent".into();
    }
    "done".into()
}

fn short(path: &str) -> String {
    Path::new(path).file_name().and_then(|n| n.to_str()).unwrap_or(path).to_string()
}

fn same_path(a: &str, b: &str) -> bool {
    match (Path::new(a).canonicalize(), Path::new(b).canonicalize()) {
        (Ok(x), Ok(y)) => x == y,
        _ => a == b,
    }
}

/// The higher of Claude's and Codex's 5h usage, when either is known.
fn usage_percent() -> Option<f64> {
    let s = crate::usage::summary(seahelm_core_types::now());
    ["claude", "codex"].iter().filter_map(|p| s.pointer(&format!("/{p}/rate_limit/used_percent")).and_then(Value::as_f64)).reduce(f64::max)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_reads_switch_agent_and_defaults() {
        let c = UserConfig::parse(r#"{"autopilot_enabled": true, "autopilot_autonomy": {"delete_worktree": "deny"}, "autopilot_agent": "codex"}"#);
        assert!(c.enabled);
        assert_eq!(c.agent, Agent::Codex);
        assert_eq!(c.defaults.get(&Action::DeleteWorktree), Some(&Level::Deny));
        assert_eq!(c.defaults.get(&Action::MessagePane), Some(&Level::Auto));
    }

    #[test]
    fn config_reads_language_and_the_users_quiet_hours() {
        let c = UserConfig::parse(r#"{"first_mate_language": "zh", "first_mate_quiet_hours": "23:00-08:00"}"#);
        assert_eq!(c.language, lang::Lang::Zh);
        let q = c.quiet_hours.unwrap();
        assert!(q.contains(&clock::Local::with_offset(1_793_577_600.0 + 23.5 * 3600.0, 0)));
        assert!(!q.contains(&clock::Local::with_offset(1_793_577_600.0 + 12.0 * 3600.0, 0)));
        let d = UserConfig::parse("{}");
        assert_eq!((d.language, d.quiet_hours), (lang::Lang::En, None));
        assert_eq!(UserConfig::parse(r#"{"first_mate_quiet_hours": "late"}"#).quiet_hours, None, "unreadable: none");
    }

    #[test]
    fn state_reports_first_mates_configured_language() {
        let dir = tempfile::tempdir().unwrap();
        let core = Core::for_test(dir.path());
        let (tx, _rx) = mpsc::channel();
        let mut mate = FirstMate::new(core, tx, dir.path().join("mate"), dir.path().join("habits"));

        mate.config = UserConfig::parse(r#"{"first_mate_language":"zh"}"#);
        assert_eq!(mate.state_json()["language"], "zh");
        mate.config = UserConfig::parse("{}");
        assert_eq!(mate.state_json()["language"], "en");
    }

    #[test]
    fn results_in_words() {
        assert_eq!(compact(&json!({"worktree_path": "/w/x", "deleted": true})), "deleted x");
        assert_eq!(compact(&json!({"worktree_path": "/w/x", "pane_session_key": "s"})), "started in x");
        assert_eq!(compact(&json!({"sent": true})), "sent");
    }
}
