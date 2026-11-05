//! The service's state and its JSON-RPC methods: hooks and screens in, pane
//! and worktree state out.
//!
//! One lock over everything. Nothing slow happens under it: seahelmd
//! snapshots and the process table are read before taking it, so a hook never
//! waits behind a socket read. Subscribers wait on `changed` and read the
//! registry's event ring after the sequence they last saw.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use anyhow::Result;
use serde_json::{json, Value};

use seahelm_core_hooks as hooks;
use seahelm_core_registry::cards::{Answer, CardKind, Cards, Input, Raise};
use seahelm_core_registry::notify::{
    self, CompletionInput, CompletionSignals, CompletionStep, Decision, Notice, NotificationPolicy, NotifyRequest,
};
use seahelm_core_registry::rollup::{Aggregator, PaneUpdate};
use seahelm_core_registry::{HookInput, Outcome, Registration, Registry};
use seahelm_core_scan::manifest::ManifestStore;
use seahelm_core_scan::pane::{PaneScanner, ScanInput};
use seahelm_core_scan::process::{self, Probe, ProcessTable};
use seahelm_core_scan::Snapshot;
use seahelm_core_types::{now, AgentStatus, AgentType, Authority, EventKind, EventSource, NormalizedEvent, Timestamp};
use seahelmd::proto::Msg;

use crate::first_mate::{self, policy as fm_policy};
use crate::pr::{self, PrStore};
use crate::rpc::{self, Dispatch, Reply, RpcError, RpcResult};

/// When this service started: `core.ping` reports it, so a comparison
/// knows which history the core watched live rather than read back.
pub static STARTED_AT: std::sync::OnceLock<f64> = std::sync::OnceLock::new();

pub struct Core {
    state: Mutex<State>,
    /// Signalled whenever the registry's sequence moves.
    changed: Condvar,
    /// Each worktree's pull request, refreshed on the PR thread
    /// (`pr::spawn`); its own lock, so a slow GitHub never holds `state`.
    prs: PrStore,
    /// First Mate's thread (`first_mate::spawn`), once started.
    first_mate: std::sync::OnceLock<crate::first_mate::Handle>,
    /// Where each transcript was read to; its own lock, so reading one never
    /// holds `state`.
    transcripts: Mutex<seahelm_core_messages::Tail>,
    /// Stable pane handles (`#n`) for the command language.
    pub(crate) handles: Mutex<seahelm_core_command::Handles>,
    /// Per worktree: its repo root and branch, and when they were read.
    pub(crate) git_cache: Mutex<HashMap<String, (String, String, Instant)>>,
}

struct State {
    registry: Registry,
    aggregator: Aggregator,
    provider: hooks::provider::Provider,
    manifests: ManifestStore,
    /// Per pane: the scanner, the daemon's latest snapshot, the root pid of
    /// the session (the program `seahelmd list` reports), and the last 7501
    /// change counter we ingested.
    panes: HashMap<String, PaneScan>,
    /// Panes the app's last `pane.sync` listed, so the next one unregisters
    /// those it no longer lists. Every listed pane is claimed, however it was
    /// first registered: a pane a hook announced before the app synced it (a
    /// fork's Claude starts and reports at once) used to be left out, and
    /// stayed in `pane.list` for good after the app closed it.
    synced: HashSet<String>,
    /// Worktrees a client shows, and whether that client is frontmost:
    /// "on screen" for unseen completion.
    visible: HashSet<String>,
    app_active: bool,
    /// What each client (`client.visible {client}`) shows, and whether it is
    /// in front. `visible` / `app_active` are their union: a pane is on
    /// screen when any client in front shows it.
    clients: HashMap<String, (HashSet<String>, bool)>,
    /// The newest location each pane's agent reported (`pane.location`).
    locations: HashMap<String, Value>,
    /// Each worktree's title as the app's rows read it (session summary,
    /// else the last prompt), worked out off the lock (`spawn_titles`).
    worktree_titles: HashMap<String, String>,
    /// Agent session references (`config.json` `agent_sessions` shape), by pane.
    session_refs: HashMap<String, Value>,
    session_refs_path: PathBuf,
    cycle: u64,
    /// Notices: what was announced, what is held by the stability gate.
    policy: NotificationPolicy,
    /// Completion signals seen per pane, for held completions.
    signals: CompletionSignals,
    /// Completions held while the hooks still say running (the app waits for
    /// the agent's final prose this way).
    retries: Vec<Retry>,
    /// Everything waiting on the user (docs/first-mate-core.md).
    cards: Cards,
    /// Where First Mate's pane outcomes and answered cards go.
    first_mate: Option<crate::first_mate::Handle>,
    /// Every pane's message timeline (`message.*`).
    messages: seahelm_core_messages::Hub,
}

/// A completion decision put off for `PROSE_RETRY_INTERVAL`.
struct Retry {
    pane: String,
    old: AgentStatus,
    new: AgentStatus,
    agent_reported_end: bool,
    attempts_left: u32,
    signals_seen: u64,
    at: Timestamp,
}

#[derive(Default)]
struct PaneScan {
    scanner: PaneScanner,
    snapshot: Option<Snapshot>,
    root_pid: Option<u32>,
    program_seq: u64,
}

/// What `core.ping` says about the `seahelm` CLI's verbs: bumped when the
/// CLI starts to rely on something new here.
pub const CLI_DIALECT: u64 = 1;

/// Calls that act on the pane `pane_id` names, and so announce their caller
/// (`ControlRouter.presenceMethods`).
const PRESENCE_METHODS: &[&str] = &[
    "pane.read", "pane.send_text", "pane.run", "pane.send_keys",
    "pane.wait_for_output", "wait.output", "pane.wait_agent_status", "wait.agent_status",
];

impl Core {
    pub fn start() -> Result<Arc<Self>> {
        let (manifests, errors) = match ManifestStore::default_user_dir() {
            Some(dir) => ManifestStore::with_user_dir(&dir),
            None => (ManifestStore::bundled(), Vec::new()),
        };
        for e in errors {
            eprintln!("seahelm-core: manifest: {e}");
        }
        let session_refs_path = rpc::config_dir().join("core-agent-sessions.json");
        let session_refs = std::fs::read_to_string(&session_refs_path)
            .ok()
            .and_then(|t| serde_json::from_str::<HashMap<String, Value>>(&t).ok())
            .unwrap_or_default();
        Ok(Arc::new(Self {
            state: Mutex::new(State {
                registry: Registry::new(),
                aggregator: Aggregator::new(),
                provider: hooks::provider::Provider::new(),
                manifests,
                panes: HashMap::new(),
                synced: HashSet::new(),
                visible: HashSet::new(),
                app_active: false,
                clients: HashMap::new(),
                locations: HashMap::new(),
                worktree_titles: HashMap::new(),
                session_refs,
                session_refs_path,
                cycle: 0,
                policy: NotificationPolicy::new(),
                signals: CompletionSignals::new(),
                retries: Vec::new(),
                cards: Cards::new(),
                first_mate: None,
                messages: seahelm_core_messages::Hub::new(Some(seahelm_core_messages::hub::Store::open(&message_dir(), 2000)), 80),
            }),
            changed: Condvar::new(),
            prs: PrStore::new(Box::new(pr::Live)),
            first_mate: std::sync::OnceLock::new(),
            transcripts: Mutex::new(seahelm_core_messages::Tail::default()),
            handles: Mutex::new(seahelm_core_command::Handles::open(&handles_path(), Some(&rpc::config_dir().join("pane-handles.json")))),
            git_cache: Mutex::new(HashMap::new()),
        }))
    }

    /// One PR refresh: the worktrees clients listed plus every registered
    /// pane's worktree. Runs on the PR thread.
    pub fn pr_cycle(&self, now: Instant) {
        let mut worktrees = self.prs.listed();
        {
            let st = self.lock();
            for p in st.registry.panes() {
                if !worktrees.contains(&p.worktree_path) {
                    worktrees.push(p.worktree_path.clone());
                }
            }
        }
        self.prs.refresh(&worktrees, now);
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// One scan cycle over every registered pane.
    pub fn poll_cycle(&self) {
        // What to read, decided under the lock; read without it.
        let (work, cycle) = {
            let mut st = self.lock();
            st.cycle += 1;
            let work: Vec<(String, bool, bool)> = st
                .registry
                .panes()
                .map(|p| p.id.clone())
                .collect::<Vec<_>>()
                .into_iter()
                .map(|id| {
                    let scan = st.panes.entry(id.clone()).or_insert_with(|| PaneScan {
                        scanner: PaneScanner::for_pane(&id),
                        ..PaneScan::default()
                    });
                    let needs_probe = scan.scanner.needs_probe();
                    let needs_root = scan.root_pid.is_none() || st.cycle % 15 == 0;
                    (id, needs_probe, needs_root)
                })
                .collect();
            (work, st.cycle)
        };
        let mut snaps: Vec<(String, Option<Snapshot>, Option<u32>)> = Vec::with_capacity(work.len());
        let mut want_table = false;
        for (id, needs_probe, needs_root) in &work {
            let snap = read_snapshot(id, cycle);
            let root = if *needs_root { session_root_pid(id) } else { None };
            want_table |= *needs_probe;
            snaps.push((id.clone(), snap, root));
        }
        let table = want_table.then(ProcessTable::capture);

        let now = now();
        let mut st = self.lock();
        let before = st.registry.seq();
        for ((id, needs_probe, _), (_, snap, root)) in work.iter().zip(snaps) {
            if let Some(pid) = root {
                if let Some(scan) = st.panes.get_mut(id) {
                    scan.root_pid = Some(pid);
                }
            }
            let Some(snap) = snap else { continue };
            st.scan_one(id, snap, if *needs_probe { table.as_ref() } else { None }, now);
        }
        st.timers(now);
        let moved = st.registry.seq() != before;
        drop(st);
        if moved {
            self.changed.notify_all();
        }
    }

    fn call_inner(self: Arc<Self>, method: &str, p: Value) -> Reply {
        let now = now();
        // First Mate's calls go through its policy before anything runs.
        let mut gated = false;
        if fm_policy::is_first_mate(&p) {
            match fm_policy::classify(method) {
                fm_policy::Class::Open => {}
                fm_policy::Class::Forbidden => {
                    return Reply::Value(Err(first_mate::refused(format!("{method} is not available to First Mate"))));
                }
                fm_policy::Class::Gated(action) => {
                    let Some(fm) = self.first_mate.get() else {
                        return Reply::Value(Err(first_mate::refused("First Mate is not running")));
                    };
                    let mut params = p.clone();
                    // A card that would delete a worktree shows what is in it, as measured.
                    if action == first_mate::rules::Action::DeleteWorktree {
                        if let Some(path) = p.get("worktree_path").and_then(Value::as_str) {
                            let mut f = first_mate::facts::Facts::probe(std::path::Path::new(path));
                            f.busy_panes = self.busy_panes(path);
                            params["_facts"] = json!(f.summary());
                        }
                    }
                    match fm.gate(action, method, params) {
                        first_mate::Gate::Allow => gated = true,
                        first_mate::Gate::Queued(card) => {
                            return Reply::Value(Ok(json!({"queued": "approval", "card": card, "message": "Queued for the user's approval; nothing ran yet."})));
                        }
                        first_mate::Gate::Deny(why) => return Reply::Value(Err(first_mate::refused(why))),
                    }
                }
            }
        } else if method == "autopilot.propose" {
            return Reply::Value(Err(first_mate::refused("only First Mate proposes")));
        }
        self.note_presence(method, &p);
        let reply = self.clone().dispatch(method, p, now);
        if gated {
            if let (Some(fm), Reply::Value(Ok(r))) = (self.first_mate.get(), &reply) {
                fm.send(first_mate::Msg::DidRun { method: method.into(), result: r.clone() });
            }
        }
        reply
    }

    fn dispatch(self: Arc<Self>, method: &str, p: Value, now: Timestamp) -> Reply {
        let result: RpcResult = match method {
            // `cli`: this core answers the `seahelm` CLI's verbs in the app's
            // dialect (`pane.read` sources, `KeyChord` keys, `wait.output`,
            // `-32004`, `pane.presence`). A CLI newer than a core still running
            // from before an update sees no `cli` and asks the app instead.
            "core.ping" => Ok(json!({"ok": true, "version": env!("CARGO_PKG_VERSION"), "started_at": STARTED_AT.get().copied(),
                                     "cli": CLI_DIALECT})),
            "hook" | "suggest" => {
                let stdout = hook_stdout(method, &p);
                // The prose the agent wrote since its last hook, read from its
                // transcript without the lock, and put on the timeline before
                // this hook's own rows: above the tool call it introduces.
                let wanted = self.lock().transcript_request(&p);
                let prose = wanted.map(|(pane, alias, path, since)| {
                    let entries = self.transcripts.lock().unwrap_or_else(|e| e.into_inner()).new_prose(&path, since);
                    (pane, alias, entries)
                });
                let mut st = self.lock();
                let before = st.registry.seq();
                let before_messages = st.messages.seq();
                if let Some((pane, alias, entries)) = prose {
                    if st.registry.pane(&pane).is_some() {
                        let rows = entries
                            .into_iter()
                            .map(|e| {
                                let kind = if e.thinking { seahelm_core_messages::Kind::Thinking } else { seahelm_core_messages::Kind::Assistant };
                                seahelm_core_messages::Message::new(&alias, &pane, kind, e.timestamp.unwrap_or(now)).with_text(e.text)
                            })
                            .collect();
                        st.messages.append(rows);
                    }
                }
                st.hook(p, now);
                let moved = st.registry.seq() != before || st.messages.seq() != before_messages;
                drop(st);
                if moved {
                    self.changed.notify_all();
                }
                Ok(match stdout {
                    Some(out) => json!({"stdout": out}),
                    None => json!({}),
                })
            }
            "worktrees.set" => {
                let paths: Vec<String> = strings(&p, "paths");
                self.prs.set_listed(&paths);
                let mut st = self.lock();
                st.provider.set_worktrees(&paths, now);
                st.registry.reorder(&paths);
                Ok(json!({"worktrees": paths.len()}))
            }
            "pane.register" => {
                let Some(r) = registration(&p) else {
                    return Reply::Value(Err(RpcError::invalid_params("pane and worktree_path required")));
                };
                self.lock().register(r);
                self.changed.notify_all();
                Ok(json!({}))
            }
            "pane.unregister" => {
                let Some(pane) = str_param(&p, "pane") else {
                    return Reply::Value(Err(RpcError::invalid_params("pane required")));
                };
                let mut st = self.lock();
                st.unregister(&pane);
                Ok(json!({}))
            }
            "pane.sync" => {
                let panes = p.get("panes").and_then(Value::as_array).cloned().unwrap_or_default();
                let n = self.lock().sync(&panes);
                self.changed.notify_all();
                Ok(json!({"panes": n}))
            }
            "client.visible" => {
                let mut st = self.lock();
                let client = str_param(&p, "client").unwrap_or_else(|| "default".into());
                let shows: HashSet<String> = strings(&p, "worktrees").into_iter().collect();
                let active = p.get("app_active").and_then(Value::as_bool).unwrap_or(true);
                st.clients.insert(client, (shows.clone(), active));
                st.app_active = st.clients.values().any(|(_, a)| *a);
                st.visible = st.clients.values().filter(|(_, a)| *a).flat_map(|(w, _)| w.iter().cloned()).collect();
                if active {
                    let shown: Vec<String> = shows.into_iter().collect();
                    for wt in shown {
                        st.registry.mark_worktree_seen(&wt);
                    }
                }
                Ok(json!({}))
            }
            "pane.seen" => {
                let hint = str_param(&p, "pane_id").or_else(|| str_param(&p, "pane_session_key"));
                let Some(hint) = hint else {
                    return Reply::Value(Err(RpcError::invalid_params("pane_id required")));
                };
                let seen = self.lock().registry.mark_pane_seen(&hint);
                Ok(json!({"seen": seen}))
            }
            "pane.list" | "session.snapshot" => {
                let detail = p.get("detail").and_then(Value::as_bool).unwrap_or(false);
                let st = self.lock();
                // Each pane's `#n` too, minted on first sight: every surface
                // shows the core's numbers.
                let mut handles = self.handles.lock().unwrap_or_else(|e| e.into_inner());
                let panes: Vec<Value> = st
                    .registry
                    .panes()
                    .filter_map(|p| {
                        let mut v = st.pane_json(&p.id)?;
                        if p.id != fm_policy::SESSION {
                            v["handle"] = json!(handles.handle(&p.id));
                        }
                        if detail {
                            v["info"] = seahelm_core_registry::events::pane_detail(p);
                        }
                        Some(v)
                    })
                    .collect();
                Ok(json!({"panes": panes}))
            }
            "pane.explain" | "agent.explain" => {
                let st = self.lock();
                let Some(id) = str_param(&p, "pane_id").and_then(|h| st.registry.resolve(Some(&h), "")) else {
                    return Reply::Value(Err(RpcError::invalid_params("unknown pane")));
                };
                Ok(st.explain(&id, now))
            }
            "worktree.list" | "fleet.status" => {
                let mut worktrees = self.lock().worktrees_json(now);
                // Worktrees with panes only, as before; their PR rides along.
                // A worktree without panes is in `pr.list`.
                for w in &mut worktrees {
                    if let Some(pr) = w.get("worktree_path").and_then(Value::as_str).and_then(|p| self.prs.status(p)) {
                        w["pr"] = pr.to_json();
                    }
                }
                Ok(json!({"worktrees": worktrees}))
            }
            "pr.list" => Ok(json!({"prs": self.prs.list()})),
            "pane.locations" => {
                let st = self.lock();
                Ok(json!({"locations": st.locations}))
            }
            "agent.sessions" => {
                let st = self.lock();
                Ok(json!({"agent_sessions": st.session_refs}))
            }
            // A pane closed for good: its session name may be reused, and must
            // not resume the agent it used to hold.
            "agent.forget" => {
                let Some(key) = str_param(&p, "pane_session_key") else {
                    return Reply::Value(Err(RpcError::invalid_params("pane_session_key required")));
                };
                let mut st = self.lock();
                let forgot = st.session_refs.remove(&key).is_some();
                if forgot {
                    st.save_session_refs();
                }
                Ok(json!({"forgot": forgot}))
            }
            "pane.wait_agent_status" | "wait.agent_status" => self.wait_status(&p),
            "pane.wait_for_output" | "wait.output" => crate::actions::wait_output(&self, &p),
            "usage.summary" => Ok(crate::usage::summary(now)),
            "cards.list" => Ok(json!({"cards": self.lock().cards.to_json()})),
            "pane.read" | "pane.run" | "pane.send_text" | "pane.send_keys" | "worktree.create" | "worktree.delete" | "pane.new" | "pane.close" => self.act(method, &p),
            "worktree.options" => Ok(crate::actions::worktree_options(&self)),
            "autopilot.state" => Ok(match self.first_mate.get() {
                Some(fm) => fm.state(),
                None => json!({"enabled": false, "owner": "core"}),
            }),
            "autopilot.propose" => {
                let summary = str_param(&p, "summary").unwrap_or_default();
                let options = p.get("options").and_then(Value::as_array).cloned().unwrap_or_default();
                match self.first_mate.get() {
                    Some(fm) => fm.propose(summary, options),
                    None => Err(first_mate::refused("First Mate is not running")),
                }
            }
            "autopilot.say" => {
                let text = str_param(&p, "text").unwrap_or_default();
                Ok(json!({"ok": self.first_mate.get().is_some_and(|fm| fm.say(text))}))
            }
            // A First Mate card by its id (the app's `autopilot.answer {card, option}`).
            "autopilot.answer" => {
                let card = str_param(&p, "card").unwrap_or_default();
                let id = self.lock().cards.list().iter().find(|c| c.payload.as_deref() == Some(card.as_str())).map(|c| c.id.clone());
                match id {
                    Some(id) => {
                        let mut q = p.clone();
                        q["id"] = json!(id);
                        self.answer_card(&q, now).map(|_| json!({"ok": true}))
                    }
                    None => Ok(json!({"ok": false})),
                }
            }
            "cards.answer" => self.answer_card(&p, now),
            "cards.dismiss" => {
                let Some(id) = str_param(&p, "id") else {
                    return Reply::Value(Err(RpcError::invalid_params("id required")));
                };
                self.with_change(|st| {
                    let card = st.cards.get(&id).cloned();
                    if !st.cards.remove(&id, now) {
                        return Ok(json!({"ok": false}));
                    }
                    st.publish_cards();
                    // A raised card's owner learns it was declined.
                    if let Some(c) = card.filter(|c| raised(c.kind)) {
                        st.registry.publish(json!({"type": "card.answered", "card": c.to_json(), "option": null}));
                        if let (Some(fm), Some(payload)) = (&st.first_mate, &c.payload) {
                            fm.send(first_mate::Msg::Answered { payload: payload.clone(), option: None });
                        }
                    }
                    Ok(json!({"ok": true}))
                })
            }
            "cards.raise" => {
                let raise = Raise {
                    kind: str_param(&p, "kind").and_then(|k| CardKind::parse(&k)).filter(|k| raised(*k)),
                    pane: str_param(&p, "pane").unwrap_or_default(),
                    worktree_path: str_param(&p, "worktree_path").unwrap_or_default(),
                    branch: str_param(&p, "branch").unwrap_or_default(),
                    project: str_param(&p, "project").unwrap_or_default(),
                    message: str_param(&p, "message").unwrap_or_default(),
                    options: strings(&p, "options"),
                    payload: str_param(&p, "payload"),
                };
                if raise.kind.is_none() || raise.options.is_empty() {
                    return Reply::Value(Err(RpcError::invalid_params("kind (report/approval/proposal) and options required")));
                }
                self.with_change(|st| {
                    let id = st.cards.raise(raise, now);
                    st.publish_cards();
                    Ok(json!({"id": id}))
                })
            }
            "cards.clear" => {
                let Some(path) = str_param(&p, "worktree_path") else {
                    return Reply::Value(Err(RpcError::invalid_params("worktree_path required")));
                };
                self.with_change(|st| {
                    let cleared = st.cards.drop_worktree(&path, now);
                    if cleared {
                        st.publish_cards();
                    }
                    Ok(json!({"cleared": cleared}))
                })
            }
            "events.subscribe" => return self.subscribe(p),
            "message.snapshot" => {
                let st = self.lock();
                let pane = str_param(&p, "pane_id").or_else(|| str_param(&p, "pane_session_key"));
                let rows: Vec<Value> = st.messages.snapshot(pane.as_deref()).iter().map(|m| m.to_json()).collect();
                Ok(json!({"messages": rows, "seq": st.messages.seq()}))
            }
            // What happened since `after_seq`, for a client that was away; null
            // when the gap is not known (ahead of the hub: start over).
            "message.replay" => {
                let Some(after) = p.get("after_seq").and_then(Value::as_u64) else {
                    return Reply::Value(Err(RpcError::invalid_params("after_seq required")));
                };
                let st = self.lock();
                Ok(match st.messages.replay(after) {
                    None => json!({"replay": null, "seq": st.messages.seq()}),
                    Some(r) => json!({"replay": {"messages": r.messages.iter().map(|m| m.to_json()).collect::<Vec<_>>(),
                                                  "truncated": r.truncated}, "seq": st.messages.seq()}),
                })
            }
            "message.history" => {
                let Some(pane) = str_param(&p, "pane_session_key").or_else(|| str_param(&p, "pane_id")) else {
                    return Reply::Value(Err(RpcError::invalid_params("pane_session_key or pane_id required")));
                };
                let Some(before) = p.get("before_seq").and_then(Value::as_u64) else {
                    return Reply::Value(Err(RpcError::invalid_params("before_seq required")));
                };
                let limit = p.get("limit").and_then(Value::as_u64).unwrap_or(50).clamp(1, 200) as usize;
                let (rows, more) = self.lock().messages.history(&pane, before, limit);
                Ok(json!({"messages": rows.iter().map(|m| m.to_json()).collect::<Vec<_>>(), "has_more": more}))
            }
            "message.subscribe" => return self.subscribe_messages(p),
            // The command language: `{text, context: {desktop?, binding?}}` →
            // the reply and, when it changed, who the conversation talks to.
            "command.run" => {
                let Some(text) = str_param(&p, "text") else {
                    return Reply::Value(Err(RpcError::invalid_params("text required")));
                };
                let ctx = p.get("context").cloned().unwrap_or_default();
                let context = seahelm_core_command::Context {
                    desktop: ctx.get("desktop").and_then(Value::as_bool).unwrap_or(false),
                    binding: ctx.get("binding").and_then(seahelm_core_command::Binding::from_json),
                    first_mate_here: ctx.get("first_mate_here").and_then(Value::as_bool).unwrap_or(false),
                };
                let outcome = seahelm_core_command::run(&text, &context, &crate::command::CoreHost(&self));
                // The verb only, never what was said: chat text stays out of the log.
                let verb = if text.trim_start().starts_with('/') { text.split_whitespace().next().unwrap_or("/") } else { "(prose)" };
                eprintln!(
                    "seahelm-core: command.run {verb} desktop={} → {}{}",
                    context.desktop,
                    if outcome.reply.is_error { "error" } else { "ok" },
                    if outcome.binding.is_some() { ", binding changed" } else { "" }
                );
                Ok(outcome.to_json())
            }
            other => Err(RpcError::not_found(other)),
        };
        Reply::Value(result)
    }

    /// Run `f` under the lock and wake subscribers if it published anything.
    fn with_change<T>(&self, f: impl FnOnce(&mut State) -> T) -> T {
        let mut st = self.lock();
        let before = st.registry.seq();
        let out = f(&mut st);
        let moved = st.registry.seq() != before;
        drop(st);
        if moved {
            self.changed.notify_all();
        }
        out
    }

    /// `cards.answer {id, option | index}`: the queue moves on under the
    /// lock; the keys go to the pane after it is released. A raised card's
    /// answer goes to its owner as `card.answered`.
    fn answer_card(&self, p: &Value, now: Timestamp) -> RpcResult {
        let id = str_param(p, "id").ok_or_else(|| RpcError::invalid_params("id required"))?;
        let answer: Result<Answer, RpcError> = self.with_change(|st| {
            let card = st.cards.get(&id).cloned().ok_or_else(|| RpcError::invalid_params("no such card"))?;
            let label = match (str_param(p, "option"), p.get("index").and_then(Value::as_u64)) {
                (Some(o), _) => o,
                (None, Some(i)) => card.labels().get(i as usize).cloned().ok_or_else(|| RpcError::invalid_params("index out of range"))?,
                _ => return Err(RpcError::invalid_params("option or index required")),
            };
            let screen = st.panes.get(&card.pane).and_then(|s| s.snapshot.as_ref()).map(|s| s.viewport.clone());
            let answer = st.cards.answer(&id, &label, screen.as_deref(), now).map_err(RpcError::invalid_params)?;
            st.publish_cards();
            if let Answer::Raised { card, option } = &answer {
                st.registry.publish(json!({"type": "card.answered", "card": card.to_json(), "option": option, "via": via(p)}));
                if let (Some(fm), Some(payload)) = (&st.first_mate, &card.payload) {
                    fm.send(first_mate::Msg::Answered { payload: payload.clone(), option: Some(option.clone()) });
                }
            }
            Ok(answer)
        });
        match answer? {
            Answer::Raised { .. } => Ok(json!({"ok": true, "raised": true})),
            Answer::Keys { pane, inputs, confirm_review } => {
                let sent = press(&pane, &inputs);
                if confirm_review {
                    confirm_question_review(pane);
                }
                match sent {
                    Ok(()) => Ok(json!({"ok": true})),
                    Err(e) => Err(RpcError::internal(format!("the pane did not take the answer: {e}"))),
                }
            }
        }
    }

    /// `pane.wait_agent_status {pane_id, status, timeout}`: wait until the
    /// pane reaches the status (`done` means idle or exited).
    /// A call from one pane acting on another (`_meta.caller`, `pane_id`)
    /// is announced as `pane.presence {caller, pane_id, note}` before it
    /// runs, so a client can show who is at work on the pane — the macOS
    /// app's presence pill, which it showed for calls on its own socket —
    /// for as long as a wait waits.
    fn note_presence(&self, method: &str, p: &Value) {
        if !PRESENCE_METHODS.contains(&method) {
            return;
        }
        let (Some(caller), Some(target)) = (fm_policy::caller(p), str_param(p, "pane_id")) else { return };
        let note = p.pointer("/_meta/note").and_then(Value::as_str).unwrap_or_default();
        self.lock().registry.publish(json!({"type": "pane.presence", "caller": caller, "pane_id": target, "note": note}));
        self.changed.notify_all();
    }

    fn wait_status(&self, p: &Value) -> RpcResult {
        let hint = str_param(p, "pane_id").ok_or_else(|| RpcError::invalid_params("pane_id required"))?;
        let want = str_param(p, "status").unwrap_or_else(|| "done".into()).to_lowercase();
        // `timeout_ms` as the app and the `seahelm` CLI send it; First Mate's
        // CLI sends `timeout` in seconds.
        let timeout = match p.get("timeout").and_then(Value::as_f64) {
            Some(secs) if p.get("timeout_ms").is_none() => Duration::from_secs_f64(secs.max(0.0)),
            _ if p.get("timeout_ms").is_some() => crate::actions::wait_timeout(p),
            _ => Duration::from_secs(600),
        };
        let deadline = Instant::now() + timeout;
        let matches = |s: AgentStatus| match want.as_str() {
            "done" => matches!(s, AgentStatus::Idle | AgentStatus::Exited),
            w => s.as_str().eq_ignore_ascii_case(w),
        };
        let mut st = self.lock();
        loop {
            let id = st.registry.resolve(Some(&hint), "").ok_or_else(|| RpcError::pane_not_found(&hint))?;
            let status = st.registry.pane(&id).map(|p| p.status).unwrap_or_default();
            if matches(status) {
                return Ok(json!({"matched": true, "status": status.as_str()}));
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Ok(json!({"matched": false, "timed_out": true, "status": status.as_str()}));
            }
            st = self.changed.wait_timeout(st, left.min(Duration::from_millis(500))).unwrap_or_else(|e| e.into_inner()).0;
        }
    }

    /// Append what the core decides to `path`, one JSON line per event, for
    /// reading back afterwards (`seahelm-core log`, A/B against a client):
    /// status changes, notices, panes closing or moving, unseen
    /// completions. `pane.updated` (every refresh) is left out. Each line
    /// carries the wall-clock time. The file rolls over to `<path>.1` past
    /// 20 MB. Runs for the life of the core on a thread of its own.
    /// Worktree titles, every 15 s on a thread of its own: the session
    /// summary of the worktree's most recently prompted pane (Claude's
    /// transcript title, Codex's last prompt), as the app's
    /// `WorktreeTitleCache`. A transcript can run to tens of megabytes, so
    /// it is read with the lock released.
    pub fn spawn_titles(self: &Arc<Self>) {
        let core = Arc::clone(self);
        let _ = std::thread::Builder::new().name("seahelm-core-titles".into()).spawn(move || {
            let mut cache = hooks::titles::TitleCache::new();
            let home = crate::install::home();
            loop {
                // (worktree, session ref) for each worktree's latest-prompted pane.
                let wanted: Vec<(String, Value)> = {
                    let st = core.lock();
                    let mut best: HashMap<String, (f64, String)> = HashMap::new();
                    for p in st.registry.panes() {
                        let at = p.last_user_prompt_at.unwrap_or(0.0);
                        let e = best.entry(p.worktree_path.clone()).or_insert((f64::MIN, p.id.clone()));
                        if at > e.0 {
                            *e = (at, p.id.clone());
                        }
                    }
                    best.into_iter()
                        .filter_map(|(wt, (_, pane))| st.session_refs.get(&pane).map(|r| (wt, r.clone())))
                        .collect()
                };
                let now = wall_clock();
                let titles: HashMap<String, String> = wanted
                    .into_iter()
                    .filter_map(|(wt, r)| {
                        let r: hooks::session_ref::AgentSessionRef = serde_json::from_value(r).ok()?;
                        let title = match (r.agent.as_str(), r.kind) {
                            ("claude", hooks::session_ref::Kind::Id) => cache.claude(&home, &wt, &r.session_id, now),
                            ("codex", _) => hooks::titles::codex_prompt(&home, &r.session_id),
                            _ => None,
                        }?;
                        Some((wt, title))
                    })
                    .collect();
                core.lock().worktree_titles = titles;
                std::thread::sleep(Duration::from_secs(15));
            }
        });
    }

    pub fn spawn_event_log(self: &Arc<Self>, path: PathBuf) {
        const LOGGED: [&str; 8] = ["pane.status_changed", "pane.notice", "pane.closed", "pane.rehomed", "pane.unseen_changed", "pane.location", "agent.session", "worktree.discovered"];
        const ROLL_AT: u64 = 20 << 20;
        let core = Arc::clone(self);
        let _ = std::thread::Builder::new().name("seahelm-core-event-log".into()).spawn(move || {
            let mut after = core.lock().registry.seq();
            loop {
                let batch = {
                    let mut st = core.lock();
                    while st.registry.seq() <= after {
                        st = core.changed.wait_timeout(st, Duration::from_secs(60)).unwrap_or_else(|e| e.into_inner()).0;
                    }
                    let batch = st.registry.events().entries_after(after);
                    after = st.registry.seq().max(after);
                    batch
                };
                let lines: Vec<String> = batch
                    .into_iter()
                    .filter(|(_, ev)| ev.get("type").and_then(Value::as_str).is_some_and(|t| LOGGED.contains(&t)))
                    .filter_map(|(_, mut ev)| {
                        if let Some(o) = ev.as_object_mut() {
                            o.insert("logged_at".into(), json!(wall_clock()));
                        }
                        serde_json::to_string(&ev).ok()
                    })
                    .collect();
                if lines.is_empty() {
                    continue;
                }
                if std::fs::metadata(&path).map(|m| m.len() > ROLL_AT).unwrap_or(false) {
                    let _ = std::fs::rename(&path, path.with_extension("jsonl.1"));
                }
                if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
                    for line in lines {
                        let _ = writeln!(f, "{line}");
                    }
                }
            }
        });
    }

    /// `events.subscribe {types?, pane_id?, events_after?}`: replay what the
    /// ring still holds after `events_after`, then stream as it happens.
    fn subscribe(self: Arc<Self>, p: Value) -> Reply {
        let types: Option<HashSet<String>> =
            p.get("types").and_then(Value::as_array).map(|a| a.iter().filter_map(|t| t.as_str().map(str::to_string)).collect());
        let pane = str_param(&p, "pane_id");
        let mut after = p.get("events_after").and_then(Value::as_u64).unwrap_or_else(|| self.lock().registry.seq());
        let core = self;
        Reply::Stream(Box::new(move |w: &mut dyn Write| {
            let first = json!({"jsonrpc": "2.0", "id": null, "result": {"subscribed": true, "seq": after}});
            if rpc::write_line(w, &first).is_err() {
                return;
            }
            loop {
                let batch = {
                    let mut st = core.lock();
                    while st.registry.seq() <= after {
                        st = core.changed.wait_timeout(st, Duration::from_secs(15)).unwrap_or_else(|e| e.into_inner()).0;
                        if st.registry.seq() <= after {
                            break;
                        }
                    }
                    let batch = st.registry.events().entries_after(after);
                    after = st.registry.seq().max(after);
                    batch
                };
                if batch.is_empty() {
                    // Keep-alive, so a dead client is noticed by the write.
                    if rpc::write_line(w, &json!({"jsonrpc": "2.0", "method": "ping"})).is_err() {
                        return;
                    }
                    continue;
                }
                for (_, ev) in batch {
                    let ty = ev.get("type").and_then(Value::as_str).unwrap_or_default();
                    if types.as_ref().is_some_and(|t| !t.contains(ty)) {
                        continue;
                    }
                    if let Some(pane) = &pane {
                        let id = ev.get("pane_id").and_then(Value::as_str);
                        let key = ev.get("pane_session_key").and_then(Value::as_str);
                        if id != Some(pane) && key != Some(pane) {
                            continue;
                        }
                    }
                    let msg = json!({"jsonrpc": "2.0", "method": "event", "params": ev});
                    if rpc::write_line(w, &msg).is_err() {
                        return;
                    }
                }
            }
        }))
    }
}

/// What the actions and First Mate's thread ask of the core. Each takes the
/// lock briefly and never does IO under it.
impl Core {
    /// Start First Mate's thread (it idles until the config gives it First Mate).
    pub fn spawn_first_mate(self: &Arc<Self>) {
        let handle = first_mate::spawn(Arc::clone(self));
        self.lock().first_mate = Some(handle.clone());
        let _ = self.first_mate.set(handle);
    }

    /// The calls the core performs itself (`actions`).
    pub fn act(&self, method: &str, p: &Value) -> RpcResult {
        match method {
            "pane.read" => crate::actions::pane_read(self, p),
            "pane.run" => crate::actions::pane_run(self, p),
            "pane.send_text" => crate::actions::pane_send_text(self, p),
            "pane.send_keys" => crate::actions::pane_send_keys(self, p),
            "worktree.create" => crate::actions::worktree_create(self, p),
            "worktree.delete" => crate::actions::worktree_delete(self, p),
            "pane.new" => crate::actions::pane_new(self, p),
            "pane.close" => crate::actions::pane_close(self, p),
            other => Err(RpcError::not_found(other)),
        }
    }

    pub fn resolve_pane(&self, hint: &str) -> Option<String> {
        self.lock().registry.resolve(Some(hint), "")
    }

    pub fn panes_in_worktree(&self, worktree: &str) -> Vec<String> {
        self.lock().registry.pane_ids_in_worktree(worktree).to_vec()
    }

    pub fn register_pane(&self, r: Registration) {
        self.lock().register(r);
        self.changed.notify_all();
    }

    /// Forget a pane a client asked to close: its `pane.closed` says so.
    pub fn close_pane(&self, pane: &str) {
        let mut st = self.lock();
        if st.registry.pane(pane).is_some() {
            st.registry.mark_closing(pane);
            st.unregister(pane);
        }
        drop(st);
        self.changed.notify_all();
    }

    /// The pane's registration as `pane.list` shows it.
    pub fn pane_row(&self, pane: &str) -> Option<Value> {
        self.lock().registry.pane_json(pane)
    }

    /// Publish an event of the core's own (First Mate's audit lines).
    pub fn publish_event(&self, event: Value) {
        self.lock().registry.publish(event);
        self.changed.notify_all();
    }

    pub fn unregister_pane(&self, pane: &str) {
        let mut st = self.lock();
        if st.registry.pane(pane).is_some() {
            st.unregister(pane);
        }
    }

    /// First Mate's pane, registered under its own directory.
    pub fn ensure_first_mate_pane(&self, dir: &str) {
        let mut st = self.lock();
        if st.registry.pane(fm_policy::SESSION).is_none() {
            st.register(Registration {
                pane: fm_policy::SESSION.into(),
                alias: None,
                worktree_path: dir.into(),
                project: first_mate::pane::PROJECT.into(),
                branch: String::new(),
                agent_type: AgentType::Unknown,
                started_at: Some(now()),
            });
        }
    }

    /// Every pane but First Mate's, with the title its screen shows.
    pub fn pane_infos(&self) -> Vec<(seahelm_core_registry::PaneInfo, String)> {
        let st = self.lock();
        st.registry
            .panes()
            .filter(|p| p.id != fm_policy::SESSION)
            .map(|p| {
                let title = st.panes.get(&p.id).and_then(|s| s.snapshot.as_ref()).map(|s| s.title.clone()).unwrap_or_default();
                (p.clone(), title)
            })
            .collect()
    }

    pub fn messages_of(&self, pane: &str) -> Vec<seahelm_core_messages::Message> {
        self.lock().messages.snapshot(Some(pane))
    }

    pub fn first_mate(&self) -> Option<&crate::first_mate::Handle> {
        self.first_mate.get()
    }

    pub fn pane_status(&self, pane: &str) -> Option<AgentStatus> {
        self.lock().registry.pane(pane).map(|p| p.status)
    }

    pub fn pane_agent(&self, pane: &str) -> Option<AgentType> {
        self.lock().registry.pane(pane).map(|p| p.agent_type)
    }

    /// Panes in a worktree that are running or waiting on someone.
    pub fn busy_panes(&self, worktree: &str) -> u32 {
        let st = self.lock();
        st.registry.panes().filter(|p| p.worktree_path == worktree && matches!(p.status, AgentStatus::Running | AgentStatus::Waiting)).count() as u32
    }

    /// Worktrees clients list plus those with panes.
    pub fn live_worktrees(&self) -> HashSet<String> {
        let mut out: HashSet<String> = self.prs.listed().into_iter().collect();
        out.extend(self.lock().registry.panes().map(|p| p.worktree_path.clone()));
        out
    }

    /// Every known worktree with its PR, as last fetched.
    pub fn worktree_prs(&self) -> Vec<(String, pr::PrStatus)> {
        self.live_worktrees().into_iter().filter_map(|w| self.prs.status(&w).map(|p| (w, p))).collect()
    }

    /// The repos of the worktrees clients list (each worktree's main checkout).
    pub fn repos(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for w in self.prs.listed() {
            let common = first_mate::facts::git(std::path::Path::new(&w), &["rev-parse", "--path-format=absolute", "--git-common-dir"]);
            if let Some(repo) = common.and_then(|c| std::path::Path::new(c.trim()).parent().map(|p| p.to_string_lossy().into_owned())) {
                if !out.contains(&repo) {
                    out.push(repo);
                }
            }
        }
        out
    }

    pub fn raise_card(&self, r: Raise) -> Option<String> {
        let mut st = self.lock();
        let id = st.cards.raise(r, now());
        st.publish_cards();
        drop(st);
        self.changed.notify_all();
        id
    }

    pub fn drop_card_payload(&self, payload: &str) {
        let mut st = self.lock();
        let id = st.cards.list().iter().find(|c| c.payload.as_deref() == Some(payload)).map(|c| c.id.clone());
        if let Some(id) = id {
            st.cards.remove(&id, now());
            st.publish_cards();
            drop(st);
            self.changed.notify_all();
        }
    }

    pub fn clear_worktree_cards(&self, worktree: &str) {
        let mut st = self.lock();
        if st.cards.drop_worktree(worktree, now()) {
            st.publish_cards();
            drop(st);
            self.changed.notify_all();
        }
    }

    /// Cards whose payload passes `keep`, in the wire shape.
    pub fn cards_with_payloads(&self, keep: impl Fn(&str) -> bool) -> Vec<Value> {
        self.lock().cards.list().iter().filter(|c| c.payload.as_deref().is_some_and(&keep)).map(|c| c.to_json()).collect()
    }
}

impl Core {
    /// `message.subscribe {pane_id?, after_seq?}`: what came after
    /// `after_seq` (or `{"reset": true}` and nothing, when the client's
    /// numbering is ahead of the core's, and the names of rings that may
    /// have lost part of the gap), then each new row as it is appended.
    /// Separate from `events.subscribe`: a busy pane's tool rows must not
    /// push status events out of that ring.
    fn subscribe_messages(self: Arc<Self>, p: Value) -> Reply {
        let pane = str_param(&p, "pane_id").or_else(|| str_param(&p, "pane_session_key"));
        let after = p.get("after_seq").and_then(Value::as_u64);
        let core = self;
        Reply::Stream(Box::new(move |w: &mut dyn Write| {
            let matches = |m: &seahelm_core_messages::Message| pane.as_deref().is_none_or(|p| m.pane_session_key == p || m.pane_id == p);
            let (first, backlog, mut last) = {
                let st = core.lock();
                let now_seq = st.messages.seq();
                match after.map(|a| st.messages.replay(a)) {
                    None => (json!({"subscribed": true, "seq": now_seq}), Vec::new(), now_seq),
                    Some(None) => (json!({"subscribed": true, "seq": now_seq, "reset": true}), Vec::new(), now_seq),
                    Some(Some(r)) => (
                        json!({"subscribed": true, "seq": now_seq, "truncated": r.truncated}),
                        r.messages.into_iter().filter(|m| matches(m)).collect::<Vec<_>>(),
                        now_seq,
                    ),
                }
            };
            if rpc::write_line(w, &json!({"jsonrpc": "2.0", "id": null, "result": first})).is_err() {
                return;
            }
            let send = |w: &mut dyn Write, m: &seahelm_core_messages::Message| {
                rpc::write_line(w, &json!({"jsonrpc": "2.0", "method": "message", "params": m.to_json()})).is_ok()
            };
            for m in &backlog {
                if !send(w, m) {
                    return;
                }
            }
            loop {
                let batch = {
                    let mut st = core.lock();
                    if st.messages.seq() <= last {
                        st = core.changed.wait_timeout(st, Duration::from_secs(15)).unwrap_or_else(|e| e.into_inner()).0;
                    }
                    let batch = st.messages.events_after(last);
                    last = st.messages.seq().max(last);
                    batch
                };
                if batch.is_empty() {
                    if rpc::write_line(w, &json!({"jsonrpc": "2.0", "method": "ping"})).is_err() {
                        return;
                    }
                    continue;
                }
                for m in batch.iter().filter(|m| matches(m)) {
                    if !send(w, m) {
                        return;
                    }
                }
            }
        }))
    }
}

/// The core's pane handles: beside a scratch core's socket, else
/// `~/.config/seahelm/core-pane-handles.json`.
fn handles_path() -> PathBuf {
    match std::env::var_os("SEAHELM_CORE_SOCKET") {
        Some(sock) => PathBuf::from(format!("{}.handles.json", sock.to_string_lossy())),
        None => rpc::config_dir().join("core-pane-handles.json"),
    }
}

/// The core's message timelines: beside a socket given by the environment (a
/// scratch core), else `~/.config/seahelm/core-message-stream/` (the app keeps
/// its own in `message-stream/` while both run).
fn message_dir() -> PathBuf {
    match std::env::var_os("SEAHELM_CORE_SOCKET") {
        Some(sock) => PathBuf::from(format!("{}.messages", sock.to_string_lossy())),
        None => rpc::config_dir().join("core-message-stream"),
    }
}

impl Dispatch for Core {
    fn call(self: Arc<Self>, method: &str, params: Value) -> Reply {
        self.call_inner(method, params)
    }
}

impl State {
    fn authority(&self, agent: AgentType) -> Authority {
        self.manifests.authority(agent)
    }

    fn register(&mut self, r: Registration) {
        let (pane, worktree) = (r.pane.clone(), r.worktree_path.clone());
        let leaf = self.registry.pane_ids_in_worktree(&worktree).len();
        self.registry.register(r);
        self.aggregator.register_pane(&pane, &worktree, leaf);
        self.panes.entry(pane.clone()).or_insert_with(|| PaneScan { scanner: PaneScanner::for_pane(&pane), ..PaneScan::default() });
        // So a client that did not register it (the app, for a session the
        // web started) can show it.
        if let Some(v) = self.registry.pane_json(&pane) {
            self.registry.publish(json!({"type": "pane.registered", "pane_session_key": pane, "pane_id": v["pane_id"], "worktree_path": worktree, "pane": v}));
        }
    }

    fn unregister(&mut self, pane: &str) {
        if let Some(info) = self.registry.pane(pane) {
            let wt = info.worktree_path.clone();
            self.aggregator.unregister_pane(pane, &wt);
        }
        self.registry.unregister(pane);
        // Gone for good: its timeline goes too.
        self.messages.clear(pane);
        if self.cards.drop_pane(pane, now()) {
            self.publish_cards();
        }
        self.panes.remove(pane);
        self.synced.remove(pane);
    }

    /// Mirror a client's pane list (the app's `pane.list` entries): register
    /// what is new, re-file what moved, drop what the last sync listed and
    /// this one does not (`claim_synced`).
    fn sync(&mut self, panes: &[Value]) -> usize {
        let mut seen = HashSet::new();
        for p in panes {
            let Some(key) = str_param(p, "pane_session_key") else { continue };
            let Some(worktree) = str_param(p, "worktree_path") else { continue };
            seen.insert(key.clone());
            let branch = str_param(p, "branch").unwrap_or_default();
            let project = str_param(p, "project").unwrap_or_default();
            if self.registry.pane(&key).is_some() {
                self.registry.set_alias(&key, str_param(p, "pane_id"));
            }
            match self.registry.pane(&key).map(|i| i.worktree_path.clone()) {
                Some(old) if old == worktree => {
                    if !branch.is_empty() {
                        self.registry.set_branch(&key, &branch, &project);
                    }
                }
                Some(_) => {
                    self.registry.rehome(&key, &worktree, &branch, &project);
                }
                None => {
                    self.register(Registration {
                        pane: key.clone(),
                        alias: str_param(p, "pane_id"),
                        worktree_path: worktree,
                        project,
                        branch,
                        agent_type: AgentType::Unknown,
                        started_at: None,
                    });
                }
            }
        }
        let n = seen.len();
        for k in claim_synced(&mut self.synced, seen) {
            self.unregister(&k);
        }
        n
    }

    fn scan_one(&mut self, id: &str, snap: Snapshot, table: Option<&ProcessTable>, now: Timestamp) {
        let Some(info) = self.registry.pane(id) else { return };
        let current_agent = info.agent_type;
        let hook_status = self.registry.hook_status(id);
        let turn = self.registry.turn_started(id);
        let root = self.panes.get(id).and_then(|s| s.root_pid);
        let probe: Option<Probe> = match (table, root) {
            (Some(t), Some(pid)) => Some(process::probe(t, pid, &self.manifests)),
            (Some(_), None) => Some(Probe::miss()),
            _ => None,
        };
        let Some(scan) = self.panes.get_mut(id) else { return };
        let out = scan.scanner.observe(
            &ScanInput { snapshot: &snap, hook_status, hook_turn_started: turn, probe: probe.as_ref(), current_agent, now },
            &self.manifests,
        );
        let program_moved = snap.program_seq != scan.program_seq;
        scan.program_seq = snap.program_seq;
        let program = snap.program.clone();
        scan.snapshot = Some(snap);

        self.registry.update_detection(id, out.agent_type, out.command_line.clone());
        let mut outcomes = Vec::new();
        let manifests = &self.manifests;
        let authority_of = |a: AgentType| manifests.authority(a);
        if program_moved {
            let ev = NormalizedEvent { pane: id.into(), source: EventSource::Osc7501, kind: EventKind::ProgramStatus { record: program } };
            outcomes.extend(self.registry.ingest_with(ev, &authority_of, now));
        }
        if let Some(kind) = out.event {
            let ev = NormalizedEvent { pane: id.into(), source: EventSource::Scan, kind };
            outcomes.extend(self.registry.ingest_with(ev, &authority_of, now));
        }
        if let Some(kind) = out.question {
            let ev = NormalizedEvent { pane: id.into(), source: EventSource::Scan, kind };
            outcomes.extend(self.registry.ingest_with(ev, &authority_of, now));
        }
        for o in outcomes {
            self.settle(&o, now);
        }
    }

    /// After every outcome: the worktree rollup, then the completion
    /// decision the app makes in `deliverPaneStatusChange` /
    /// `deliverAgentCompletion` — mark the turn unseen when its worktree is
    /// not on screen in a frontmost client, and announce it (`pane.notice`)
    /// if the notification policy lets it through.
    fn settle(&mut self, o: &Outcome, now: Timestamp) {
        let pane_id = o.info.alias.clone().unwrap_or_else(|| o.info.id.clone());
        let config = self.manifests.message_config(o.info.agent_type);
        self.messages.ingest(o, &pane_id, &config, now);
        // Cards first: a pane whose question is on a card is not announced
        // as waiting on top of it.
        if self.cards.observe(o, now) {
            self.publish_cards();
        }
        if o.info.id == fm_policy::SESSION {
            if o.status_changed {
                if let Some(fm) = &self.first_mate {
                    fm.send(first_mate::Msg::Outcome { old: o.old_status, new: o.new_status });
                }
            }
            // First Mate is not a member of the fleet: no notices for it.
            return;
        }
        self.aggregator.update(&o.info.id, PaneUpdate::from_pane(&o.info), now);
        self.registry.settle_unseen(o);
        self.signals.note(o);
        if o.is_completion_signal {
            // The agent's own Stop is a finished turn whatever the rollup says.
            self.decide(&o.info.id, AgentStatus::Running, AgentStatus::Idle, true, notify::PROSE_ATTEMPTS, now);
        } else if o.status_changed {
            self.decide(&o.info.id, o.old_status, o.new_status, false, notify::PROSE_ATTEMPTS, now);
        }
    }

    fn decide(&mut self, pane: &str, old: AgentStatus, new: AgentStatus, agent_reported_end: bool, attempts_left: u32, now: Timestamp) {
        let Some(info) = self.registry.pane(pane).cloned() else { return };
        let on_screen = self.app_active && self.visible.contains(&info.worktree_path);
        let step = notify::completion_step(&CompletionInput {
            pane: Some(&info),
            old_status: old,
            new_status: new,
            agent_reported_end,
            attempts_left,
            worktree_on_screen: on_screen,
            has_pending_card: self.cards.has_pane(pane),
            completion_signals: self.signals.count(pane),
        });
        match step {
            CompletionStep::Ignore => {}
            CompletionStep::Retry { after, attempts_left, signals_seen } => self.retries.push(Retry {
                pane: pane.to_string(),
                old,
                new,
                agent_reported_end,
                attempts_left,
                signals_seen,
                at: now + after,
            }),
            CompletionStep::Proceed { mark_unseen, source } => {
                if mark_unseen {
                    self.registry.set_unseen(pane, true);
                }
                let siblings = self.registry.pane_ids_in_worktree(&info.worktree_path);
                let index = siblings.iter().position(|p| p == pane).unwrap_or(0);
                let mut req = NotifyRequest::for_pane(
                    &info,
                    old,
                    new,
                    &info.last_message,
                    index,
                    siblings.len(),
                    on_screen,
                    agent_reported_end,
                );
                req.source = source;
                if let Decision::Deliver(notice) = self.policy.notify(req, now) {
                    self.publish_notice(notice);
                }
            }
        }
    }

    /// Held completions whose wait is over, and notices the stability gate
    /// let through.
    fn timers(&mut self, now: Timestamp) {
        let (due, later): (Vec<Retry>, Vec<Retry>) = std::mem::take(&mut self.retries).into_iter().partition(|r| r.at <= now);
        self.retries = later;
        for r in due {
            let status_now = self.registry.pane(&r.pane).map(|p| p.status);
            if notify::retry_proceeds(status_now, r.signals_seen, self.signals.count(&r.pane)) {
                self.decide(&r.pane, r.old, r.new, r.agent_reported_end, r.attempts_left, now);
            }
        }
        for notice in self.policy.due(now) {
            self.publish_notice(notice);
        }
    }

    /// For a hook that names a transcript: the pane it is about, what clients
    /// call it, the transcript, and how far back a first read may go (to
    /// where the pane's timeline already reaches, else five minutes).
    fn transcript_request(&self, payload: &Value) -> Option<(String, String, String, Timestamp)> {
        let ev = hooks::event::parse(payload)?;
        let path = ev.session_path.clone()?;
        let pane = self.registry.resolve(ev.pane_id.as_deref(), &ev.cwd)?;
        let alias = self.registry.pane(&pane).and_then(|p| p.alias.clone()).unwrap_or_else(|| pane.clone());
        let since = self.messages.last_ts(&pane).unwrap_or(now() - 300.0);
        Some((pane, alias, path, since))
    }

    /// `cards.changed`: the whole list, so a renderer never has to merge.
    fn publish_cards(&mut self) {
        let cards = self.cards.to_json();
        self.registry.publish(json!({"type": "cards.changed", "cards": cards}));
    }

    fn publish_notice(&mut self, notice: Notice) {
        let alias = self.registry.pane(&notice.request.pane).and_then(|p| p.alias.clone());
        let Ok(mut v) = serde_json::to_value(&notice) else { return };
        if let Some(obj) = v.as_object_mut() {
            obj.insert("type".into(), json!("pane.notice"));
            obj.insert("pane_session_key".into(), json!(notice.request.pane));
            obj.insert("pane_id".into(), json!(alias.unwrap_or_else(|| notice.request.pane.clone())));
        }
        self.registry.publish(v);
    }

    /// One hook payload, end to end (the app's event sink, provider and
    /// `handleWebhookEvent`, in that order).
    fn hook(&mut self, payload: Value, now: Timestamp) {
        let Some(event) = hooks::event::parse(&payload) else { return };
        if let Some(scan) = event.pane_id.as_deref().and_then(|p| self.registry.resolve(Some(p), "")).and_then(|id| self.panes.get_mut(&id)) {
            // A hook means the screen is about to change: look at the next frame.
            scan.scanner.invalidate();
        }
        if let Some(busy) = hooks::sink::background_busy(&event) {
            self.registry.set_background_busy(&event.cwd, busy);
        }
        // A suggestion while the worktree's background work will resume the
        // agent anyway is noise (the inbound event only, as the app does).
        if hooks::sink::drops_suggest(&event, self.registry.is_background_busy(&event.cwd)) {
            return;
        }
        for ev in hooks::sink::expand(event) {
            // Late prose for a suggestion whose summary is tool chrome.
            if ev.event == hooks::event::WebhookEventType::AssistantResponse {
                if let (Some(text), Some(pane)) =
                    (ev.data.get("text").and_then(Value::as_str), self.registry.resolve(ev.pane_id.as_deref(), &ev.cwd))
                {
                    if self.cards.refresh_suggestion(&pane, &hooks::suggest::strip_sentinel(text)) {
                        self.publish_cards();
                    }
                }
            }
            let out = self.provider.handle(&ev, now, &mut hooks::provider::probe_worktree_root);
            if let Some(loc) = &out.pane_location {
                if let Some(pane) = self.registry.resolve(Some(&loc.pane), "") {
                    let entry = json!({"worktree": loc.worktree, "location": loc.location, "created_by_agent": loc.created_by_agent, "at": now});
                    // Pushed when it moves, so a client acts on it without polling
                    // `pane.locations`.
                    let moved = self.locations.get(&pane).map(|old| (&old["worktree"], &old["location"])) != Some((&entry["worktree"], &entry["location"]));
                    if moved {
                        let public = self.registry.pane(&pane).map(|i| i.public_id().to_string()).unwrap_or_else(|| pane.clone());
                        self.registry.publish(json!({
                            "type": "pane.location",
                            "pane_id": public,
                            "pane_session_key": pane,
                            "worktree": loc.worktree,
                            "location": loc.location,
                            "created_by_agent": loc.created_by_agent,
                        }));
                    }
                    self.locations.insert(pane, entry);
                }
            }
            if let Some(r) = &out.session_ref {
                // By pane when the hook named one, else the worktree's pane.
                let key = match &r.pane {
                    Some(p) => self.registry.resolve(Some(p), &r.worktree),
                    None => self.registry.pane_for_worktree(&r.worktree).map(|p| p.id.clone()),
                };
                if let (Some(key), Ok(v)) = (key, serde_json::to_value(&r.session_ref)) {
                    if self.session_refs.get(&key) != Some(&v) {
                        // Pushed, so the client that recreates the pane's session
                        // resumes the agent without asking.
                        self.registry.publish(json!({"type": "agent.session", "pane_session_key": key, "ref": v}));
                        self.session_refs.insert(key, v);
                        self.save_session_refs();
                    }
                }
            }
            if let Some((path, pane)) = &out.new_worktree {
                // An agent is working in a worktree nobody tracks yet: the
                // client that owns the fleet's layout picks it up.
                self.registry.publish(json!({"type": "worktree.discovered", "worktree_path": path, "pane_session_key": pane}));
            }
            let kind = hooks::decode::decode(&ev, now);
            let last_assistant_message = ev
                .data
                .get("last_assistant_message")
                .and_then(Value::as_str)
                .map(|m| hooks::suggest::strip_sentinel(m));
            let input = HookInput { pane_hint: ev.pane_id.clone(), cwd: ev.cwd.clone(), source: ev.source.clone(), kind, last_assistant_message };
            let live = |name: &str| seahelmd::client::connect(name).is_ok();
            let manifests = &self.manifests;
            let result = self.registry.ingest_hook(input, &live, &|a| manifests.authority(a), now);
            if result.fell_back_from_hint {
                eprintln!("seahelm-core: hook for {:?} fell back to {:?}", ev.pane_id, result.pane);
            }
            if let Some(pane) = &result.pane {
                if !self.panes.contains_key(pane) {
                    self.panes.insert(pane.clone(), PaneScan { scanner: PaneScanner::for_pane(pane), ..PaneScan::default() });
                }
            }
            if let Some(o) = result.outcome {
                self.settle(&o, now);
            }
        }
    }

    fn save_session_refs(&self) {
        if let Ok(text) = serde_json::to_string_pretty(&self.session_refs) {
            let tmp = self.session_refs_path.with_extension("json.tmp");
            if std::fs::write(&tmp, text).is_ok() {
                let _ = std::fs::rename(&tmp, &self.session_refs_path);
            }
        }
    }

    /// pane.list's entry: the registry's, with what the screen says added.
    fn pane_json(&self, id: &str) -> Option<Value> {
        let mut v = self.registry.pane_json(id)?;
        if let (Some(obj), Some(snap)) = (v.as_object_mut(), self.panes.get(id).and_then(|s| s.snapshot.as_ref())) {
            if !snap.title.is_empty() {
                obj.insert("title".into(), json!(snap.title));
            }
            obj.insert("pwd".into(), json!(snap.pwd));
        }
        Some(v)
    }

    fn explain(&self, id: &str, now: Timestamp) -> Value {
        let agent = self.registry.pane(id).map(|p| p.agent_type).unwrap_or_default();
        let authority = self.authority(agent);
        let mut v = self.registry.explain(id, authority, now);
        if let Some(snap) = self.panes.get(id).and_then(|s| s.snapshot.as_ref()) {
            if let (Some(obj), Value::Object(scan)) = (v.as_object_mut(), seahelm_core_scan::explain::explain(snap, agent, &self.manifests)) {
                for (k, val) in scan {
                    obj.entry(k).or_insert(val);
                }
            }
        }
        v
    }

    /// Per worktree: the dot (recency rule), the group (priority rule),
    /// running panes, unseen, last activity.
    fn worktrees_json(&self, now: Timestamp) -> Vec<Value> {
        let mut paths: Vec<String> = Vec::new();
        for p in self.registry.panes() {
            if !paths.contains(&p.worktree_path) {
                paths.push(p.worktree_path.clone());
            }
        }
        paths
            .into_iter()
            .map(|wt| {
                let panes: Vec<_> = self.registry.panes_in_worktree(&wt).collect();
                let group = seahelm_core_registry::rollup::grouping_status(panes.iter().copied());
                let dot = self.aggregator.status(&wt).map(|s| s.rolled_up_status()).unwrap_or(group);
                let running_since = panes
                    .iter()
                    .filter(|p| p.status == AgentStatus::Running && p.round_duration > 0.0)
                    .map(|p| now - p.round_duration)
                    .reduce(f64::min);
                // The row's title: the session summary, else the latest
                // prompt's first line; clients fall back to the worktree's name.
                let title = self.worktree_titles.get(&wt).cloned().or_else(|| {
                    panes
                        .iter()
                        .filter(|p| !p.last_user_prompt.trim().is_empty())
                        .max_by(|a, b| a.last_user_prompt_at.unwrap_or(0.0).total_cmp(&b.last_user_prompt_at.unwrap_or(0.0)))
                        .map(|p| one_line(&p.last_user_prompt, 80))
                });
                json!({
                    "worktree_path": wt,
                    "title": title,
                    "status": dot.as_str(),
                    "group_status": group.as_str(),
                    "panes": panes.len(),
                    "unseen": panes.iter().any(|p| p.unseen_completion),
                    "running_since": running_since,
                    "last_activity_at": self.aggregator.last_activity(&wt),
                })
            })
            .collect()
    }
}

/// How many trailing lines of `history` stand in for the screen of a daemon
/// too old to answer `Snapshot` (what the app reads for surface-less panes).
const LEGACY_LINES: usize = 60;

/// The pane's screen. A session started by a seahelmd older than `Snapshot`
/// answers it with an error until it is recreated; for those the screen is
/// the tail of `history`, read every third cycle (the full scrollback crosses
/// the socket each time), with a hash of it standing in for `generation`.
fn read_snapshot(id: &str, cycle: u64) -> Option<Snapshot> {
    match seahelmd::client::request(id, &Msg::Snapshot) {
        Ok(Msg::Text(json)) => return Snapshot::parse(&json).ok(),
        // Gone is gone; anything else (an old daemon hangs up on a request
        // it cannot decode) means a daemon from before `Snapshot`.
        Err(e) if seahelmd::client::is_gone(&e) => return None,
        _ => {}
    }
    let stagger = id.bytes().fold(0u64, |h, b| h.wrapping_mul(31).wrapping_add(b as u64));
    if (cycle + stagger) % 3 != 0 {
        return None;
    }
    let Ok(Msg::Text(history)) = seahelmd::client::request(id, &Msg::History) else { return None };
    let lines: Vec<&str> = history.trim_end_matches('\n').lines().collect();
    let viewport = lines[lines.len().saturating_sub(LEGACY_LINES)..].join("\n");
    let mut hash: u64 = 5381;
    for b in viewport.bytes() {
        hash = hash.wrapping_mul(33) ^ b as u64;
    }
    Some(Snapshot { started: Some(true), generation: hash, rows: LEGACY_LINES as u16, viewport, ..Snapshot::default() })
}

/// The session's root pid, from the daemon's `Info` line (`pid=`).
fn session_root_pid(name: &str) -> Option<u32> {
    match seahelmd::client::request(name, &Msg::Info) {
        Ok(Msg::Text(line)) => line.split('\t').find_map(|f| f.strip_prefix("pid=")).and_then(|p| p.parse().ok()),
        _ => None,
    }
}

/// Cards a client raises and answers itself; the core only carries them.
fn raised(kind: CardKind) -> bool {
    matches!(kind, CardKind::Report | CardKind::Approval | CardKind::Proposal)
}

/// Type into a pane's session: each input a write of its own, a Return
/// held back a beat after what came before it.
fn press(pane: &str, inputs: &[Input]) -> Result<()> {
    for (i, input) in inputs.iter().enumerate() {
        let bytes = match input {
            Input::Bytes(b) => b.clone(),
            Input::Submit => {
                if i > 0 {
                    std::thread::sleep(SUBMIT_DELAY);
                }
                "\r".to_string()
            }
        };
        seahelmd::client::request(pane, &Msg::Send(bytes.into_bytes()))?;
    }
    Ok(())
}

const SUBMIT_DELAY: Duration = Duration::from_millis(80);

/// Every answer of a multi-question ask is in and the dialog moves to
/// "Review your answers" with its cursor on Submit. Press Return once that
/// page is up, never blind: an early Return would pick a row.
fn confirm_question_review(pane: String) {
    let _ = std::thread::Builder::new().name("seahelm-core-review".into()).spawn(move || {
        for _ in 0..6 {
            std::thread::sleep(Duration::from_millis(400));
            let up = matches!(seahelmd::client::request(&pane, &Msg::Snapshot), Ok(Msg::Text(json))
                if Snapshot::parse(&json).is_ok_and(|s| s.viewport.contains("Ready to submit your answers?")));
            if up {
                let _ = seahelmd::client::request(&pane, &Msg::Send(b"\r".to_vec()));
                return;
            }
        }
        eprintln!("seahelm-core: review page never appeared for {pane}; left for the user");
    });
}

/// What a hook's bridge should print back to its agent: the suggestion
/// guidance at a session start, for an agent running in a seahelm pane
/// (hooks are installed for every session of the agent, seahelm's or not)
/// whose hooks can take added context.
fn hook_stdout(method: &str, p: &Value) -> Option<String> {
    if method != "hook" {
        return None;
    }
    let event = p.get("hook_event_name").and_then(Value::as_str)?;
    if event != "SessionStart" && event != "sessionStart" {
        return None;
    }
    str_param(p, "seahelm_pane_id").filter(|s| !s.is_empty())?;
    hooks::suggest::session_start_output(p.get("seahelm_source").and_then(Value::as_str)?)
}

fn str_param(p: &Value, key: &str) -> Option<String> {
    p.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string)
}

fn strings(p: &Value, key: &str) -> Vec<String> {
    p.get(key).and_then(Value::as_array).into_iter().flatten().filter_map(|v| v.as_str().map(str::to_string)).collect()
}

fn registration(p: &Value) -> Option<Registration> {
    Some(Registration {
        pane: str_param(p, "pane")?,
        alias: str_param(p, "alias"),
        worktree_path: str_param(p, "worktree_path")?,
        project: str_param(p, "project").unwrap_or_default(),
        branch: str_param(p, "branch").unwrap_or_default(),
        agent_type: p.get("agent_type").and_then(|v| serde_json::from_value(v.clone()).ok()).unwrap_or_default(),
        started_at: p.get("started_at").and_then(Value::as_f64),
    })
}

/// Seconds since the epoch, for the event log.
fn wall_clock() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// Who a call says it is for (`_meta.via`: `web:Safari on iPhone`,
/// `telegram:@name`). Recorded, never trusted for anything.
pub fn via(p: &Value) -> Value {
    p.get("_meta").and_then(|m| m.get("via")).filter(|v| v.is_string()).cloned().unwrap_or(Value::Null)
}

/// The first line of `text`, at most `max` characters.
fn one_line(text: &str, max: usize) -> String {
    let line = text.trim().lines().next().unwrap_or("").trim();
    if line.chars().count() > max {
        line.chars().take(max - 1).collect::<String>() + "…"
    } else {
        line.to_string()
    }
}

/// The app's `pane.sync` claims every pane it lists; returns those it
/// claimed last time and no longer lists, which the sync unregisters.
fn claim_synced(synced: &mut HashSet<String>, seen: HashSet<String>) -> Vec<String> {
    let mut gone: Vec<String> = synced.difference(&seen).cloned().collect();
    gone.sort();
    *synced = seen;
    gone
}

#[cfg(test)]
mod sync_tests {
    use super::*;

    fn set(keys: &[&str]) -> HashSet<String> {
        keys.iter().map(|k| k.to_string()).collect()
    }

    #[test]
    fn a_pane_the_app_stops_listing_is_dropped() {
        let mut synced = set(&["a", "b"]);
        assert_eq!(claim_synced(&mut synced, set(&["a"])), vec!["b".to_string()]);
        assert_eq!(synced, set(&["a"]));
    }

    /// A pane a hook registered first (a fork's Claude reports before the
    /// app's next sync) is still the app's once the app lists it, and goes
    /// when the app closes it.
    #[test]
    fn a_pane_registered_elsewhere_is_claimed_once_listed() {
        let mut synced = set(&["a"]);
        assert!(claim_synced(&mut synced, set(&["a", "fork"])).is_empty());
        assert_eq!(claim_synced(&mut synced, set(&["a"])), vec!["fork".to_string()]);
    }

    /// A pane the app never listed (another client's, or a hook from outside
    /// any pane) is not the app's to drop.
    #[test]
    fn a_pane_the_app_never_listed_is_left_alone() {
        let mut synced = set(&["a"]);
        assert!(claim_synced(&mut synced, set(&["a"])).is_empty());
        assert!(!synced.contains("gpui-x"));
    }
}

#[cfg(test)]
mod hook_stdout_tests {
    use super::*;

    #[test]
    fn a_seahelm_pane_starting_a_session_is_told_about_suggestions() {
        let p = json!({"hook_event_name": "SessionStart", "seahelm_pane_id": "seahelm-x", "seahelm_source": "claude-code"});
        assert!(hook_stdout("hook", &p).unwrap().contains("additionalContext"));
        let cursor = json!({"hook_event_name": "sessionStart", "seahelm_pane_id": "seahelm-x", "seahelm_source": "cursor"});
        assert!(hook_stdout("hook", &cursor).unwrap().contains("additional_context"));
    }

    #[test]
    fn nothing_is_printed_otherwise() {
        // Outside seahelm: the hooks are global, the guidance is not.
        assert_eq!(hook_stdout("hook", &json!({"hook_event_name": "SessionStart", "seahelm_source": "claude-code"})), None);
        // Any other event: Stop's stdout would read as a decision.
        assert_eq!(hook_stdout("hook", &json!({"hook_event_name": "Stop", "seahelm_pane_id": "p", "seahelm_source": "claude-code"})), None);
        // An agent whose hooks take no context, or an unknown one.
        assert_eq!(hook_stdout("hook", &json!({"hook_event_name": "SessionStart", "seahelm_pane_id": "p", "seahelm_source": "opencode"})), None);
        assert_eq!(hook_stdout("hook", &json!({"hook_event_name": "SessionStart", "seahelm_pane_id": "p"})), None);
        assert_eq!(hook_stdout("suggest", &json!({"hook_event_name": "SessionStart", "seahelm_pane_id": "p", "seahelm_source": "claude-code"})), None);
    }
}
