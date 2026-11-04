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

pub mod clock;
pub mod cron;
pub mod engine;
pub mod facts;
pub mod pane;
pub mod policy;
pub mod rules;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use serde_json::{json, Value};

use seahelm_core_registry::cards::{CardKind, Raise};
use seahelm_core_types::AgentStatus;

use crate::core::Core;
use crate::rpc::{RpcError, RpcResult};
use clock::Local;
use cron::Cron;
use engine::{Audit, Detector, Dispatch, Entry, Event, Ledger, Observation};
use facts::Facts;
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
    Gate { action: Action, method: String, params: Value, reply: Sender<Gate> },
    Propose { summary: String, options: Vec<Value>, reply: Sender<RpcResult> },
    State { reply: Sender<Value> },
    /// The user's own words.
    Say { text: String, reply: Sender<bool> },
    /// First Mate's pane changed status.
    Outcome { old: AgentStatus, new: AgentStatus },
    /// A card First Mate raised was answered (None: dismissed).
    Answered { payload: String, option: Option<String> },
    /// A gated call went through.
    DidRun { method: String, result: Value },
    /// An approved or picked call finished.
    Ran { action: Action, what: String, level: &'static str, result: Result<Value, String> },
}

/// How the core reaches First Mate.
#[derive(Clone)]
pub struct Handle(Sender<Msg>);

impl Handle {
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

    pub fn state(&self) -> Value {
        self.ask(|reply| Msg::State { reply }, json!({"enabled": false, "owner": "core"}))
    }

    pub fn say(&self, text: String) -> bool {
        self.ask(|reply| Msg::Say { text, reply }, false)
    }
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
    summary: String,
    options: Vec<ProposalOption>,
}

struct ProposalOption {
    label: String,
    action: Action,
    method: String,
    params: Value,
}

struct FirstMate {
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
    approvals: HashMap<String, Approval>,
    proposals: HashMap<String, Proposal>,
    started: HashSet<String>,
    configs: HashMap<String, (Result<Config, String>, Option<SystemTime>)>,
    /// Per worktree with a PR: its repo and branch, and when that was read.
    git_info: HashMap<String, (String, String, Instant)>,
    last_minute: Option<i64>,
    latest: Option<(String, String)>,
    next_id: u64,
}

/// Start First Mate's thread. It does nothing until the config gives it
/// First Mate.
pub fn spawn(core: Arc<Core>) -> Handle {
    let (tx, rx) = mpsc::channel();
    let dir = pane::dir();
    let audit = Audit::open(dir.join("audit.jsonl"));
    let latest = audit.recent(50).into_iter().rev().find(Entry::is_notable).map(|e| (e.headline(), e.at));
    let fm = FirstMate {
        core,
        tx: tx.clone(),
        ledger: Ledger::open(dir.join("state.json")),
        audit,
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
        approvals: HashMap::new(),
        proposals: HashMap::new(),
        started: HashSet::new(),
        configs: HashMap::new(),
        git_info: HashMap::new(),
        last_minute: None,
        latest,
        next_id: 0,
    };
    let _ = std::thread::Builder::new().name("seahelm-core-first-mate".into()).spawn(move || fm.run(rx));
    Handle(tx)
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
            Msg::Gate { action, method, params, reply } => {
                let _ = reply.send(self.gate(action, &method, &params, now));
            }
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
                }
                self.deliver_if_ready(now);
            }
            Msg::Answered { payload, option } => self.answered(&payload, option.as_deref(), now),
            Msg::DidRun { method, result } => self.did_run(&method, &result),
            Msg::Ran { action, what, level, result } => {
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
                self.log(e);
                let verb = if level == "picked" { format!("picked \"{what}\"") } else { format!("approved: {what}") };
                self.tell(&format!("[seahelm] The user {verb}\nResult: {outcome}"));
            }
        }
    }

    // MARK: lifecycle

    fn tick(&mut self, now: f64) {
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
        if !self.running {
            return;
        }
        if switched {
            self.launched_at = None;
        }
        self.ensure_session();
        self.observe_prs(now);
        self.check_schedules(now);
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
        eprintln!("seahelm-core: running First Mate");
    }

    fn stop(&mut self) {
        let ids: Vec<String> = self.approvals.keys().chain(self.proposals.keys()).cloned().collect();
        for id in ids {
            self.core.drop_card_payload(&id);
        }
        self.approvals.clear();
        self.proposals.clear();
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
        pane::provision(&self.dir, &exe);
        let agent = self.config.agent;
        let young = self.launched_at.is_some_and(|t| t.elapsed() < Duration::from_secs(60));
        let mut exists = seahelmd::client::connect(policy::SESSION).is_ok();
        let has_agent = self.core.pane_agent(policy::SESSION).is_some_and(|a| a.is_ai_agent());
        if exists && (!pane::session_is_current(&self.dir, agent) || (!young && self.launched_at.is_some() && !has_agent)) {
            let _ = seahelmd::client::request(policy::SESSION, &seahelmd::proto::Msg::Kill);
            let deadline = Instant::now() + Duration::from_secs(5);
            while seahelmd::client::connect(policy::SESSION).is_ok() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(100));
            }
            exists = false;
        }
        if !exists {
            pane::mark_session_current(&self.dir, agent);
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
            let mut f = Facts::probe(Path::new(&event.worktree));
            f.busy_panes = self.core.busy_panes(&event.worktree);
            event.facts = Some(f);
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
        let quiet = config.settings.quiet_hours.is_some_and(|q| q.contains(&Local::at(now)));
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

    // MARK: delivery

    fn deliver_if_ready(&mut self, now: f64) {
        if !self.running || self.config.paused || self.awaiting_since.is_some() || self.queue.is_empty() {
            return;
        }
        if self.core.pane_status(policy::SESSION) != Some(AgentStatus::Idle) {
            return;
        }
        let local = Local::at(now);
        let mut ready = Vec::new();
        let mut held = Vec::new();
        for d in std::mem::take(&mut self.queue) {
            let quiet = self.config_for(&d.event.repo).ok().and_then(|c| c.settings.quiet_hours).is_some_and(|q| q.contains(&local));
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
        let text = ready.iter().map(|d| d.prompt.as_str()).collect::<Vec<_>>().join("\n\n---\n\n");
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
        self.user_spoke = true;
        self.tell(t);
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
        let summary = policy::describe(method, params, params.get("_facts").and_then(Value::as_str));
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
        match self.level(action) {
            Level::Auto => {
                let mut e = Entry::new(now, "action", summary);
                e.action = Some(action.as_str().into());
                e.level = Some("auto".into());
                self.log(e);
                Gate::Allow
            }
            Level::Deny => {
                deny(self, Some("deny"), summary);
                Gate::Deny(format!("{} is set to deny", action.as_str()))
            }
            Level::Ask => {
                let id = self.mint("autopilot");
                self.core.raise_card(Raise {
                    kind: Some(CardKind::Approval),
                    worktree_path: self.dir.to_string_lossy().into(),
                    project: pane::PROJECT.into(),
                    message: format!("First Mate asks: {summary}"),
                    options: vec![APPROVE.into(), REJECT.into()],
                    payload: Some(id.clone()),
                    ..Raise::default()
                });
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
            if let Some(p) = result.get("worktree_path").and_then(Value::as_str) {
                self.started.insert(p.to_string());
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
            options.push(ProposalOption { label: label.into(), action, method: method.into(), params: o.get("params").cloned().unwrap_or(json!({})) });
        }
        if options.is_empty() || options.len() > 5 {
            return Err(RpcError::invalid_params("between one and five options"));
        }
        let id = self.mint("proposal");
        let mut labels: Vec<String> = options.iter().map(|o| o.label.clone()).collect();
        labels.push(NOT_NOW.into());
        self.core.raise_card(Raise {
            kind: Some(CardKind::Proposal),
            worktree_path: self.dir.to_string_lossy().into(),
            project: pane::PROJECT.into(),
            message: format!("First Mate suggests: {summary}"),
            options: labels,
            payload: Some(id.clone()),
            ..Raise::default()
        });
        self.log(Entry::new(now, "approval", format!("proposed: {summary}")));
        self.proposals.insert(id.clone(), Proposal { summary: summary.into(), options });
        Ok(json!({"queued": "proposal", "card": id, "message": "Shown to the user; you will be told what they picked."}))
    }

    /// The user answered one of First Mate's cards.
    fn answered(&mut self, payload: &str, option: Option<&str>, now: f64) {
        if let Some(a) = self.approvals.remove(payload) {
            if option != Some(APPROVE) {
                let mut e = Entry::new(now, "denied", format!("rejected: {}", a.summary));
                e.action = Some(a.action.as_str().into());
                self.log(e);
                self.tell(&format!("[seahelm] The user rejected: {}", a.summary));
                return;
            }
            self.execute(a.action, a.method, a.params, a.summary, "approved");
            return;
        }
        let Some(p) = self.proposals.remove(payload) else { return };
        let Some(o) = p.options.into_iter().find(|o| Some(o.label.as_str()) == option) else {
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
        self.execute(o.action, o.method, o.params, o.label, "picked");
    }

    /// Run a call as the user's, off this thread; the outcome comes back as
    /// `Msg::Ran`.
    fn execute(&self, action: Action, method: String, params: Value, what: String, level: &'static str) {
        let core = self.core.clone();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = core.act(&method, &policy::as_user(&params)).map(|mut r| {
                r["_method"] = json!(method);
                r
            });
            let _ = tx.send(Msg::Ran { action, what, level, result: result.map_err(|e| e.message) });
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
        let pending = self.approvals.len() + self.proposals.len();
        let tone = if pending > 0 { "wants_you" } else { tone };
        let detail = match (&self.latest, self.queue.len()) {
            (_, q) if q > 0 => format!("{q} queued"),
            (Some((text, _)), _) => text.clone(),
            _ => String::new(),
        };
        let cards: Vec<Value> = self
            .core
            .cards_with_payloads(|p| self.approvals.contains_key(p) || self.proposals.contains_key(p))
            .into_iter()
            .map(|c| {
                json!({"card": c["payload"], "id": c["id"], "kind": c["kind"], "message": c["message"], "options": c["options"]})
            })
            .collect();
        let mut v = json!({
            "enabled": self.running,
            "owner": "core",
            "activity": activity,
            "tone": tone,
            "detail": detail,
            "pending": pending,
            "queued": self.queue.len(),
            "agent": self.config.agent.raw(),
            "cards": cards,
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
    fn results_in_words() {
        assert_eq!(compact(&json!({"worktree_path": "/w/x", "deleted": true})), "deleted x");
        assert_eq!(compact(&json!({"worktree_path": "/w/x", "pane_session_key": "s"})), "started in x");
        assert_eq!(compact(&json!({"sent": true})), "sent");
    }
}
