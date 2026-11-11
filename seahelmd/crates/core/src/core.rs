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
use seahelm_core_registry::cards::{Answer, CardKind, CardState, Cards, Input, Raise};
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

use crate::first_mate::lang::Text;
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
    /// The observation log's thread (`first_mate::observations::spawn`).
    observer: std::sync::OnceLock<first_mate::observations::Handle>,
    /// Where each transcript was read to; its own lock, so reading one never
    /// holds `state`.
    transcripts: Mutex<seahelm_core_messages::Tail>,
    /// Stable pane handles (`#n`) for the command language.
    pub(crate) handles: Arc<Mutex<seahelm_core_command::Handles>>,
    /// Per worktree: its repo root and branch, and when they were read.
    pub(crate) git_cache: Mutex<HashMap<String, (String, String, Instant)>>,
    /// The worktrees the core found itself (`discovery::spawn`), canonical.
    discovered: Mutex<Vec<String>>,
    /// What the user said to First Mate this turn (`autopilot.say`), until
    /// the turn ends: a note First Mate writes meanwhile cites it.
    user_turn: Mutex<Option<String>>,
    /// Discovery has finished a scan: the fleet is known, not just what a
    /// client happened to list in the first seconds after start.
    fleet_known: std::sync::atomic::AtomicBool,
    /// First Mate's audit log, written to directly when First Mate is not
    /// running (a refused card answer is logged either way).
    audit_path: PathBuf,
    /// Client pids already written down as running inside a pane: once per
    /// process, not once per answer.
    audited_clients: Mutex<HashSet<u32>>,
    /// When the user is there (`first_mate::presence`): the activity
    /// profile behind the daily brief. Its own lock, never taken with `state`.
    presence: Mutex<first_mate::presence::Tracker>,
}

struct CursorWorker {
    sender: std::sync::mpsc::Sender<(String, String, bool, Value, Timestamp)>,
    cancelled: Arc<std::sync::atomic::AtomicBool>,
    checkpoint: PathBuf,
    checkpoint_gate: Arc<Mutex<()>>,
}

struct State {
    cursor_workers: HashMap<String, CursorWorker>,
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
    /// Names the user gave panes (`pane.rename`), by session name. Shown
    /// before any title the terminal or agent gives, by every client.
    custom_titles: HashMap<String, String>,
    custom_titles_path: PathBuf,
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
    /// Where agents' `git worktree add/remove` go, as evidence.
    observer: Option<first_mate::observations::Handle>,
    /// Every pane's message timeline (`message.*`).
    messages: seahelm_core_messages::Hub,
    /// The pending row itself is the source of truth for a card's resolution,
    /// including after its originating pane has been unregistered.
    pending_card_rows: HashMap<String, seahelm_core_messages::Message>,
    /// Startup reconciliation waits for scans/replays before closing cards
    /// left pending by the previous core process.
    card_history_reconcile_at: Option<Timestamp>,
    /// The same stable handles used by pane.list and the command language.
    handles: Arc<Mutex<seahelm_core_command::Handles>>,
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

struct TranscriptRequest {
    pane: String,
    alias: String,
    source: TranscriptSource,
    since: Timestamp,
}

enum TranscriptSource {
    File(String),
    Cursor { cwd: String, chat_id: String, session_start: bool },
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
        let dir = rpc::config_dir();
        let messages = seahelm_core_messages::Hub::new(Some(seahelm_core_messages::hub::Store::open(&message_dir(), 2000)), 80);
        let handles = seahelm_core_command::Handles::open(&handles_path(), Some(&dir.join("pane-handles.json")));
        Ok(Self::assemble(manifests, &dir, messages, handles, first_mate::pane::dir().join("audit.jsonl")))
    }

    /// A core whose files all live under `dir`, for tests: nothing under
    /// the user's own `~/.config/seahelm` is read or written.
    #[cfg(test)]
    pub fn for_test(dir: &std::path::Path) -> Arc<Self> {
        let messages = seahelm_core_messages::Hub::new(None, 80);
        let handles = seahelm_core_command::Handles::open(&dir.join("handles.json"), None);
        Self::assemble(ManifestStore::bundled(), dir, messages, handles, dir.join("audit.jsonl"))
    }

    fn assemble(
        manifests: ManifestStore,
        dir: &std::path::Path,
        messages: seahelm_core_messages::Hub,
        handles: seahelm_core_command::Handles,
        audit_path: PathBuf,
    ) -> Arc<Self> {
        let handles = Arc::new(Mutex::new(handles));
        let mut pending_card_rows = HashMap::new();
        let mut max_card_id = 0;
        for row in messages.snapshot(Some(fm_policy::SESSION)) {
            if row.kind != seahelm_core_messages::Kind::Card { continue; }
            let Some(id) = row.card_id.clone() else { continue };
            if let Some(number) = id.strip_prefix("c-").and_then(|value| value.parse::<u64>().ok()) {
                max_card_id = max_card_id.max(number);
            }
            if row.state.as_deref() == Some("pending") {
                pending_card_rows.insert(id, row);
            } else {
                pending_card_rows.remove(&id);
            }
        }
        let mut cards = Cards::new();
        cards.reserve_ids_through(max_card_id);
        let session_refs_path = dir.join("core-agent-sessions.json");
        let session_refs = std::fs::read_to_string(&session_refs_path)
            .ok()
            .and_then(|t| serde_json::from_str::<HashMap<String, Value>>(&t).ok())
            .unwrap_or_default();
        let custom_titles_path = dir.join("core-pane-titles.json");
        let custom_titles = std::fs::read_to_string(&custom_titles_path)
            .ok()
            .and_then(|t| serde_json::from_str::<HashMap<String, String>>(&t).ok())
            .unwrap_or_default();
        Arc::new(Self {
            state: Mutex::new(State {
                cursor_workers: HashMap::new(),
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
                custom_titles,
                custom_titles_path,
                cycle: 0,
                policy: NotificationPolicy::new(),
                signals: CompletionSignals::new(),
                retries: Vec::new(),
                cards,
                first_mate: None,
                observer: None,
                messages,
                pending_card_rows,
                card_history_reconcile_at: Some(now() + 30.0),
                handles: handles.clone(),
            }),
            changed: Condvar::new(),
            prs: PrStore::new(Box::new(pr::Live)),
            first_mate: std::sync::OnceLock::new(),
            observer: std::sync::OnceLock::new(),
            transcripts: Mutex::new(seahelm_core_messages::Tail::default()),

            handles,
            git_cache: Mutex::new(HashMap::new()),
            discovered: Mutex::new(Vec::new()),
            user_turn: Mutex::new(None),
            fleet_known: std::sync::atomic::AtomicBool::new(false),
            presence: Mutex::new(first_mate::presence::Tracker::open(Some(audit_path.with_file_name(first_mate::presence::FILE_NAME)))),
            audit_path,
            audited_clients: Mutex::new(HashSet::new()),
        })
    }

    /// One PR refresh over every live worktree (`live_worktrees`: listed,
    /// panes, discovered). Runs on the PR thread.
    pub fn pr_cycle(&self, now: Instant) {
        let mut worktrees: Vec<String> = self.live_worktrees().into_iter().collect();
        worktrees.sort();
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
        let before_messages = st.messages.seq();
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
        let moved = st.registry.seq() != before || st.messages.seq() != before_messages;
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
                fm_policy::Class::Open | fm_policy::Class::Card => {}
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
                            let f = self.measure_worktree(path, None);
                            params["_facts"] = json!(f.summary());
                            // For the habits: the answer is evidence for the one these facts match.
                            params["_facts_json"] = serde_json::to_value(&f).unwrap_or(Value::Null);
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
        } else if matches!(method, "autopilot.propose" | "habits.propose") {
            return Reply::Value(Err(first_mate::refused("only First Mate proposes")));
        }
        self.note_presence(method, &p);
        let caller = fm_policy::caller(&p);
        let params = matches!(method, "worktree.create" | "worktree.delete").then(|| p.clone());
        let reply = self.clone().dispatch(method, p, now);
        if let (Some(params), Reply::Value(Ok(r))) = (params, &reply) {
            use first_mate::observations::By;
            let (by, pane) = match caller {
                _ if gated => (By::FirstMate, None),
                // Called from a pane whose agent is running: the agent
                // (`seahelm worktree …`); from a bare shell, the user typing it.
                Some(c) if self.resolve_pane(&c).and_then(|k| self.pane_agent(&k)).is_some_and(|a| a.is_ai_agent()) => (By::Agent, Some(c)),
                Some(c) => (By::User, Some(c)),
                None => (By::User, None),
            };
            self.note_performed(method, &params, r, by, gated.then_some("auto"), None, pane.as_deref());
        }
        if gated && method == "worktree.create" && matches!(&reply, Reply::Value(Err(_))) {
            if let Some(fm) = self.first_mate.get() { fm.send(first_mate::Msg::CreateFailed); }
        }
        if gated {
            if let (Some(fm), Reply::Value(Ok(r))) = (self.first_mate.get(), &reply) {
                fm.send(first_mate::Msg::DidRun { method: method.into(), result: r.clone() });
            }
        }
        reply
    }

    fn queue_cursor_prose(self: &Arc<Self>, pane: String, alias: String, cwd: String, chat: String, start: bool, payload: Value, at: Timestamp) {
        let mut state = self.lock();
        let worker = state.cursor_workers.entry(pane.clone()).or_insert_with(|| {
            let (sender, receiver) = std::sync::mpsc::channel::<(String, String, bool, Value, Timestamp)>();
            let core = Arc::downgrade(self);
            let checkpoint = self.audit_path.parent().unwrap_or(std::path::Path::new(".")).join("cursor-checkpoints").join(hooks::titles::md5_hex(&pane));
            let cancelled = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let cancel = cancelled.clone();
            let worker_checkpoint = checkpoint.clone();
            let checkpoint_gate = Arc::new(Mutex::new(()));
            let gate = checkpoint_gate.clone();
            std::thread::spawn(move || {
                let checkpoint = worker_checkpoint;
                let mut tail = seahelm_core_messages::CursorTail::default();
                tail.restore(&checkpoint);
                for (cwd, chat, start, payload, at) in receiver {
                    if cancel.load(std::sync::atomic::Ordering::Acquire) { break; }
                    let Some(core) = core.upgrade() else { break };
                    let entries = tail.new_prose(&hooks::titles::cursor_chats_root(&hooks::home_dir()), &cwd, &chat, start);
                    let mut state = core.lock();
                    if cancel.load(std::sync::atomic::Ordering::Acquire) || state.registry.pane(&pane).is_none() { break; }
                    let before = state.messages.seq();
                    state.cursor_hook(&pane, &alias, entries, payload, at);
                    let prompts = user_prompts(&state, before, at);
                    let active = state.app_active;
                    drop(state);
                    {
                        let _guard = gate.lock().unwrap_or_else(|e| e.into_inner());
                        if !cancel.load(std::sync::atomic::Ordering::Acquire) { tail.persist(&checkpoint); }
                    }
                    core.prompts_seen(&prompts, active, at);
                    core.changed.notify_all();
                }
            });
            CursorWorker { sender, cancelled, checkpoint, checkpoint_gate }
        });
        let _ = worker.sender.send((cwd, chat, start, payload, at));
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
                let stdout = hook_stdout(method, &p).map(|output| {
                    let memory = str_param(&p, "seahelm_pane_id").and_then(|pane| self.resolve_pane(&pane)).and_then(|pane| self.pane_row(&pane))
                        .and_then(|row| row["worktree_path"].as_str().map(first_mate::routing::main_repo))
                        .or_else(|| str_param(&p,"cwd").map(|cwd| first_mate::routing::main_repo(&cwd)))
                        .map(|repo| self.memory_store().context(&repo)).unwrap_or_default();
                    hooks::suggest::append_context(&output, &memory)
                });
                // The prose the agent wrote since its last hook, read from its
                // transcript without the lock, and put on the timeline before
                // this hook's own rows: above the tool call it introduces.
                let wanted = self.lock().transcript_request(&p);
                if let Some(TranscriptRequest { pane, alias, source: TranscriptSource::Cursor { cwd, chat_id, session_start }, .. }) = &wanted {
                    self.queue_cursor_prose(pane.clone(), alias.clone(), cwd.clone(), chat_id.clone(), *session_start, p, now);
                    return Reply::Value(Ok(match stdout { Some(out) => json!({"stdout": out}), None => json!({}) }));
                }
                let prose = wanted.map(|request| {
                    let entries = match request.source {
                        TranscriptSource::File(path) => self.transcripts.lock().unwrap_or_else(|e| e.into_inner()).new_prose(&path, request.since),
                        TranscriptSource::Cursor { .. } => unreachable!(),
                    };
                    let (pane, alias) = (request.pane, request.alias);
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
                let prompts = if st.messages.seq() != before_messages { user_prompts(&st, before_messages, now) } else { Vec::new() };
                let at_desk = st.app_active;
                drop(st);
                self.prompts_seen(&prompts, at_desk, now);
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
                // The user did something at the desk: a client came to the
                // front, or shows something else while in front. A client
                // not heard from since the core started (a reconnect) is not
                // a transition.
                let moved = active && st.clients.get(&client).is_some_and(|(w, a)| !*a || *w != shows);
                let desktop = !client.starts_with("web");
                st.clients.insert(client, (shows.clone(), active));
                st.app_active = st.clients.values().any(|(_, a)| *a);
                st.visible = st.clients.values().filter(|(_, a)| *a).flat_map(|(w, _)| w.iter().cloned()).collect();
                if active {
                    let shown: Vec<String> = shows.into_iter().collect();
                    if let Some(fm) = self.first_mate.get() { fm.send(first_mate::Msg::ResearchSeen { worktrees: shown.clone() }); }
                    for wt in shown {
                        st.registry.mark_worktree_seen(&wt);
                    }
                }
                drop(st);
                if moved {
                    let channel = if desktop { first_mate::presence::Channel::Desktop } else { first_mate::presence::Channel::Web };
                    self.presence_signal(now, Some(channel));
                }
                Ok(json!({}))
            }
            // The user is using a client right now (keys or the mouse in its
            // window; never what was typed). The app sends it at most once a
            // minute (`first_mate::presence`).
            "client.activity" => {
                let client = str_param(&p, "client").unwrap_or_else(|| "default".into());
                let channel = if client.starts_with("web") { first_mate::presence::Channel::Web } else { first_mate::presence::Channel::Desktop };
                self.presence_signal(now, Some(channel));
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
                // Nor keep the name the user gave the pane it used to be.
                if st.custom_titles.remove(&key).is_some() {
                    st.save_custom_titles();
                }
                Ok(json!({"forgot": forgot}))
            }
            // The user names a pane; an empty title gives it back its own.
            "pane.rename" => {
                let hint = str_param(&p, "pane_id").or_else(|| str_param(&p, "pane_session_key"));
                let mut st = self.lock();
                let Some(id) = hint.and_then(|h| st.registry.resolve(Some(&h), "")) else {
                    return Reply::Value(Err(RpcError::invalid_params("unknown pane")));
                };
                let title = crate::pane_title::custom_title(&str_param(&p, "title").unwrap_or_default());
                let changed = match &title {
                    Some(t) => st.custom_titles.insert(id.clone(), t.clone()).as_ref() != Some(t),
                    None => st.custom_titles.remove(&id).is_some(),
                };
                if changed {
                    st.save_custom_titles();
                    let mut ev = json!({"type": "pane.renamed", "pane_session_key": id, "custom_title": title});
                    if let Some(pane) = st.pane_json(&id) {
                        ev["pane_id"] = pane["pane_id"].clone();
                        ev["worktree_path"] = pane["worktree_path"].clone();
                        if let Some(d) = pane.get("display_title") {
                            ev["display_title"] = d.clone();
                        }
                    }
                    st.registry.publish(ev);
                    drop(st);
                    self.changed.notify_all();
                }
                Ok(json!({"pane_session_key": id, "custom_title": title}))
            }
            "pane.wait_agent_status" | "wait.agent_status" => self.wait_status(&p),
            "pane.wait_for_output" | "wait.output" => crate::actions::wait_output(&self, &p),
            "usage.summary" => Ok(crate::usage::summary(now)),
            "cards.list" => Ok(json!({"cards": self.lock().cards.to_json()})),
            "pane.read" | "pane.run" | "pane.send_text" | "pane.send_keys" | "worktree.create" | "worktree.delete" | "pane.new" | "pane.close" => self.act(method, &p),
            "worktree.options" => Ok(crate::actions::worktree_options(&self)),
            // Read-only: no RPC raises a habit's level (docs/first-mate-autonomy.md, D1).
            "task-source.add" | "task-source.list" | "task-source.remove" | "task-source.test" => first_mate::task_sources::rpc(method, &p),
            "memory.note" | "memory.show" | "memory.undo" | "memory.confirm" => first_mate::memory::rpc(&self, method, &p),

            "schedule.add" | "schedule.list" | "schedule.remove" | "schedule.run_now" | "research.summary" => {
                match self.first_mate.get() {
                    Some(fm) => fm.research(method, p),
                    None => Err(first_mate::refused("First Mate is not running")),
                }
            }
            "habits.list" => Ok(first_mate::learning::rpc(method, &p).unwrap_or_default()),
            // When the user is there, as the brief's timing reads it (read-only).
            "presence.state" => Ok(self.presence().to_json(now, crate::usage::local_offset(now))),
            // The inventory (docs/first-mate-autonomy.md, D6): `preview` only
            // measures and groups; otherwise First Mate raises one card per
            // group. Nothing is deleted or granted until the user answers one.
            "habits.inventory" => {
                if p.get("preview").and_then(Value::as_bool) == Some(true) {
                    Ok(first_mate::learning::inventory_preview(&self))
                } else {
                    match self.first_mate.get() {
                        Some(fm) => fm.inventory(),
                        None => Err(first_mate::refused("First Mate is not running")),
                    }
                }
            }
            // seahelm-web's activation page: First Mate on or off, and its agent.
            "autopilot.configure" => {
                let enabled = p.get("enabled").and_then(Value::as_bool);
                let agent = str_param(&p, "agent");
                let path = rpc::config_dir().join("config.json");
                match first_mate::configure(&path, enabled, agent.as_deref()) {
                    Ok(()) => {
                        if let Some(fm) = self.first_mate.get() {
                            fm.send(first_mate::Msg::ConfigChanged);
                        }
                        Ok(json!({"ok": true}))
                    }
                    Err(e) => Err(RpcError::invalid_params(e)),
                }
            }
            "autopilot.state" => Ok(match self.first_mate.get() {
                Some(fm) => fm.state(),
                None => json!({"enabled": false, "owner": "core"}),
            }),
            "habits.propose" => match self.first_mate.get() {
                Some(fm) => fm.propose_habit(p.get("habit").cloned().unwrap_or(p)),
                None => Err(first_mate::refused("First Mate is not running")),
            },
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
                    if !st.cards.dismiss(&id, card_via(&p), now) {
                        return Ok(json!({"ok": false}));
                    }
                    st.publish_cards();
                    // A raised card's owner learns it was declined.
                    if let Some(c) = card.filter(|c| raised(c.kind)) {
                        st.registry.publish(json!({"type": "card.answered", "card": c.to_json(), "option": null}));
                        if let (Some(fm), Some(payload)) = (&st.first_mate, &c.payload) {
                            fm.send(first_mate::Msg::Answered { payload: payload.clone(), option: None, via: via(&p).as_str().map(str::to_string) });
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
                    first_mate: false,
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
            let answer = st.cards.answer_via(&id, &label, screen.as_deref(), card_via(p), now).map_err(RpcError::invalid_params)?;
            st.publish_cards();
            if let Answer::Raised { card, option } = &answer {
                st.registry.publish(json!({"type": "card.answered", "card": card.to_json(), "option": option, "via": via(p)}));
                if let (Some(fm), Some(payload)) = (&st.first_mate, &card.payload) {
                    let via = via(p).as_str().map(str::to_string);
                    fm.send(first_mate::Msg::Answered { payload: payload.clone(), option: Some(option.clone()), via });
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
    /// Also starts the observation log, which records whether or not First
    /// Mate is on and creates First Mate's directory for it — the directory
    /// only; First Mate itself waits for `autopilot_enabled`
    /// (`first_mate::observations`).
    pub fn spawn_first_mate(self: &Arc<Self>) {
        let observer = first_mate::observations::spawn(Arc::clone(self));
        self.lock().observer = Some(observer.clone());
        let _ = self.observer.set(observer);
        let handle = first_mate::spawn(Arc::clone(self));
        self.lock().first_mate = Some(handle.clone());
        let _ = self.first_mate.set(handle);
    }

    pub fn observe(&self, m: first_mate::observations::Msg) {
        if let Some(o) = self.observer.get() {
            o.send(m);
        }
    }

    /// A core-performed `worktree.create` / `worktree.delete` went through:
    /// tell the observation log who did it.
    #[allow(clippy::too_many_arguments)]
    pub fn note_performed(&self, method: &str, params: &Value, result: &Value, by: first_mate::observations::By, how: Option<&str>, card: Option<&str>, pane: Option<&str>) {
        if !matches!(method, "worktree.create" | "worktree.delete") {
            return;
        }
        self.observe(first_mate::observations::Msg::Performed {
            method: method.into(),
            params: params.clone(),
            result: result.clone(),
            by,
            how: how.map(str::to_string),
            card: card.map(str::to_string),
            pane: pane.map(str::to_string),
        });
    }


    /// The calls the core performs itself (`actions`).
    pub fn act(&self, method: &str, p: &Value) -> RpcResult {
        if matches!(method, "pane.run" | "pane.send_text" | "pane.send_keys") {
            // The prompt this makes in the pane is not the user's typing.
            if let Some(key) = str_param(p, "pane_id").and_then(|h| self.resolve_pane(&h)) {
                let text = str_param(p, "command").or_else(|| str_param(p, "text")).unwrap_or_default();
                self.presence.lock().unwrap_or_else(|e| e.into_inner()).typed_into(&key, &text, now());
            }
        }
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

    /// One line in First Mate's conversation, written by the core rather
    /// than typed into its session, so it starts no turn: a `note` row.
    pub fn first_mate_line(&self, text: &str) {
        let text = text.replace('\n', " ");
        let mut st = self.lock();
        if st.registry.pane(fm_policy::SESSION).is_none() {
            return;
        }
        let row = seahelm_core_messages::Message::new(fm_policy::SESSION, fm_policy::SESSION, seahelm_core_messages::Kind::Note, now()).with_text(text);
        st.messages.append(vec![row]);
        drop(st);
        self.changed.notify_all();
    }

    /// The daily brief in First Mate's conversation: a `brief` row, its
    /// lines kept (`first_mate::brief`).
    pub fn first_mate_brief(&self, text: &str) {
        let mut st = self.lock();
        if st.registry.pane(fm_policy::SESSION).is_none() {
            return;
        }
        let row = seahelm_core_messages::Message::new(fm_policy::SESSION, fm_policy::SESSION, seahelm_core_messages::Kind::Brief, now()).with_text(text.to_string());
        st.messages.append(vec![row]);
        drop(st);
        self.changed.notify_all();
    }

    /// One moment the user did something (`first_mate::presence`).
    pub fn presence_signal(&self, at: f64, channel: Option<first_mate::presence::Channel>) {
        let offset = crate::usage::local_offset(at);
        self.presence.lock().unwrap_or_else(|e| e.into_inner()).record(at, offset, channel);
    }

    /// Prompts that showed up in panes: the user's, unless something typed
    /// into that pane a moment ago. At the desk when a desktop client is in
    /// front; otherwise where is not known.
    fn prompts_seen(&self, prompts: &[(String, String)], at_desk: bool, now: f64) {
        if prompts.is_empty() {
            return;
        }
        let projects: HashMap<String, String> = self.pane_infos().into_iter().map(|(p, _)| (p.id, p.project)).collect();
        let mut t = self.presence.lock().unwrap_or_else(|e| e.into_inner());
        for (pane, text) in prompts {
            if !t.is_echo(pane, text, now) {
                t.profile.prompts.push((now, projects.get(pane).cloned().unwrap_or_default(), text.chars().take(1000).collect()));
            }
        }
        let excess = t.profile.prompts.len().saturating_sub(200);
        t.profile.prompts.drain(..excess);
        if prompts.iter().all(|(pane, text)| t.is_echo(pane, text, now)) {
            return;
        }
        let offset = crate::usage::local_offset(now);
        t.record(now, offset, at_desk.then_some(first_mate::presence::Channel::Desktop));
    }

    /// What First Mate reads to time the brief: the profile, and whether a
    /// desktop client is in front.
    #[cfg(test)]
    pub fn set_test_first_mate(&self, handle: first_mate::Handle) {
        self.lock().first_mate = Some(handle.clone());
        let _ = self.first_mate.set(handle);
    }

    pub fn presence_last_seen(&self) -> f64 {
        self.presence.lock().unwrap_or_else(|e| e.into_inner()).profile.last_seen
    }

    pub fn presence(&self) -> first_mate::presence::Snapshot {
        let desktop_in_front = self.lock().clients.iter().any(|(name, (_, active))| *active && !name.starts_with("web"));
        let profile = self.presence.lock().unwrap_or_else(|e| e.into_inner()).profile.clone();
        first_mate::presence::Snapshot { profile, desktop_in_front }
    }

    pub fn has_card_payload(&self, payload: &str) -> bool {
        self.lock().cards.list().iter().any(|c| c.payload.as_deref() == Some(payload))
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

    /// A pane as the user knows it: `#7 · feat-x` (its handle and its
    /// worktree's name), from any id a client or First Mate uses for it.
    /// None for a pane the core does not know.
    pub fn pane_label(&self, pane_ref: &str) -> Option<String> {
        let st = self.lock();
        let id = st.registry.resolve(Some(pane_ref), "")?;
        let p = st.registry.pane(&id)?;
        let wt = std::path::Path::new(&p.worktree_path).file_name().and_then(|n| n.to_str()).unwrap_or(&p.worktree_path).to_string();
        let handle = self.handles.lock().unwrap_or_else(|e| e.into_inner()).handle(&id);
        Some(format!("#{handle} · {wt}"))
    }

    pub fn pane_agent(&self, pane: &str) -> Option<AgentType> {
        self.lock().registry.pane(pane).map(|p| p.agent_type)
    }

    /// Panes in a worktree that are running or waiting on someone.
    pub fn busy_panes(&self, worktree: &str) -> u32 {
        let st = self.lock();
        st.registry.panes().filter(|p| p.worktree_path == worktree && matches!(p.status, AgentStatus::Running | AgentStatus::Waiting)).count() as u32
    }

    /// The latest moment anything happened in the worktree's panes (a
    /// prompt, a reply, an agent start), Unix seconds.
    pub fn last_pane_activity(&self, worktree: &str) -> Option<f64> {
        let st = self.lock();
        st.registry
            .panes()
            .filter(|p| p.worktree_path == worktree)
            .flat_map(|p| [p.last_user_prompt_at, p.last_assistant_message_at, p.started_at])
            .flatten()
            .fold(None, |a: Option<f64>, t| Some(a.map_or(t, |a| a.max(t))))
    }

    /// The worktree's facts with what the core knows beyond git: its PR
    /// (`pr`, else the PR store's last answer), busy panes, pane activity.
    /// Blocking: git, and maybe a fetch of the PR's head.
    pub fn measure_worktree(&self, worktree: &str, pr: Option<&pr::PrStatus>) -> first_mate::facts::Facts {
        self.measure_worktree_with(worktree, pr, true)
    }

    /// `measure_worktree`, saying whether a PR head missing locally may be
    /// fetched. The observation log's periodic measurements pass false, so
    /// keeping it fresh never touches the network.
    pub fn measure_worktree_with(&self, worktree: &str, pr: Option<&pr::PrStatus>, fetch_pr_head: bool) -> first_mate::facts::Facts {
        use first_mate::facts::{Context, Facts, PrInfo};
        let known = if pr.is_some() { None } else { self.prs.known(worktree) };
        let info = match (pr, &known) {
            (Some(p), _) => PrInfo::Some(p),
            (None, Some(Some(p))) => PrInfo::Some(p),
            (None, Some(None)) => PrInfo::None,
            (None, None) => PrInfo::Unknown,
        };
        let mut ctx = Context::new(info, now());
        ctx.busy_panes = self.busy_panes(worktree);
        ctx.last_pane_activity = self.last_pane_activity(worktree);
        ctx.fetch_pr_head = fetch_pr_head;
        Facts::measure(std::path::Path::new(worktree), &ctx)
    }

    /// Worktrees clients list plus those with panes.
    pub fn client_worktrees(&self) -> HashSet<String> {
        let mut out: HashSet<String> = self.prs.listed().into_iter().collect();
        out.extend(self.lock().registry.panes().map(|p| p.worktree_path.clone()));
        out
    }

    /// Every worktree the core knows: `client_worktrees` plus those it found
    /// itself (`discovery`), so the fleet is known with every client closed.
    /// A discovered worktree a client already lists under another spelling
    /// (a symlinked path) is not added twice; the client's spelling wins.
    pub fn live_worktrees(&self) -> HashSet<String> {
        let mut out = self.client_worktrees();
        let discovered = self.discovered.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if discovered.is_empty() {
            return out;
        }
        let spelled: HashSet<String> = out.iter().map(|w| crate::discovery::canon(w)).collect();
        out.extend(discovered.into_iter().filter(|d| !spelled.contains(d)));
        out
    }

    /// The discovery thread's latest scan.
    pub fn set_discovered(&self, worktrees: Vec<String>) {
        *self.discovered.lock().unwrap_or_else(|e| e.into_inner()) = worktrees;
        self.fleet_known.store(true, std::sync::atomic::Ordering::Release);
    }

    /// Whether discovery has scanned once since start. Before that the core
    /// knows only what a client listed in its first seconds, and anything
    /// that judges the whole fleet (the inventory) would judge an empty one.
    pub fn set_user_turn(&self, text: Option<String>) {
        *self.user_turn.lock().unwrap_or_else(|e| e.into_inner()) = text;
    }

    pub fn user_turn(&self) -> Option<String> {
        self.user_turn.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn fleet_known(&self) -> bool {
        self.fleet_known.load(std::sync::atomic::Ordering::Acquire)
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

    pub fn memory_store(&self) -> first_mate::memory::Store {
        first_mate::memory::Store { dir: self.audit_path.parent().unwrap_or(std::path::Path::new(".")).join("memory") }
    }

    pub fn known_prs(&self) -> Vec<Value> { self.prs.routing_list() }

    pub fn raise_card(&self, r: Raise) -> Option<String> {
        let mut r = r;
        r.pane.clear();
        r.first_mate = true;
        let mut st = self.lock();
        let id = st.cards.raise(r, now());
        st.publish_cards();
        drop(st);
        self.changed.notify_all();
        id
    }

    pub fn drop_card_payload(&self, payload: &str) {
        self.resolve_card_payload(payload, CardState::Gone);
    }

    pub fn expire_card_payload(&self, payload: &str) {
        self.resolve_card_payload(payload, CardState::Expired);
    }

    fn resolve_card_payload(&self, payload: &str, state: CardState) {
        let mut st = self.lock();
        let id = st.cards.list().iter().find(|c| c.payload.as_deref() == Some(payload)).map(|c| c.id.clone());
        if let Some(id) = id {
            st.cards.resolve(&id, state, None, None, now());
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
    /// In-process calls: the core's own, trusted.
    fn call(self: Arc<Self>, method: &str, params: Value) -> Reply {
        self.call_inner(method, params)
    }

    /// Calls off the socket. Answering for the user is for the clients the
    /// user answers through, never for a process in a pane (`peer.rs`).
    fn call_from(self: Arc<Self>, peer: &rpc::Peer, method: &str, params: Value) -> Reply {
        if method == "research.summary" && (!fm_policy::is_first_mate(&params) || !crate::peer::first_mate_peer(peer)) {
            return Reply::Value(Err(first_mate::refused("research.summary requires First Mate's real session")));
        }
        let pid = peer.pid;
        self.call_checked(method, params, pid, || crate::peer::identify(peer))
    }
}

/// Raised-card payloads only the core mints (First Mate's approvals,
/// proposals and habit cards): a card raised over the socket may not carry
/// one, or the user's answer to it would reach First Mate as the answer to
/// the real card.
const CORE_PAYLOADS: [&str; 5] = ["habit.", "autopilot-", "proposal-", "task-start-", "research.stop:"];

impl Core {
    /// A socket call, after the peer check for the guarded methods. The
    /// verdict is only worked out for those (it reads the process table).
    fn call_checked(self: Arc<Self>, method: &str, params: Value, pid: Option<u32>, verdict: impl FnOnce() -> crate::peer::Verdict) -> Reply {
        if crate::peer::guarded_call(method, &params) {
            let verdict = verdict();
            let mate_note = crate::peer::first_mate_memory(method, pid);
            if let Err(e) = if mate_note { Ok(()) } else { self.admit(&verdict, pid, method, &params) } {
                return Reply::Value(Err(e));
            }
        }
        if let Some(channel) = presence_of(method, &params) {
            self.presence_signal(now(), Some(channel));
        }
        self.call_inner(method, params)
    }

    fn admit(&self, verdict: &crate::peer::Verdict, pid: Option<u32>, method: &str, p: &Value) -> std::result::Result<(), RpcError> {
        use crate::peer::Verdict;
        let pid_n = pid;
        let pid = pid.map(|p| p.to_string()).unwrap_or_else(|| "?".into());
        match verdict {
            Verdict::Client { client, in_pane: Some(why) } => {
                // Allowed: the app relaunched from a pane is still the app.
                // Written down once per process, so a binary dressed up as a
                // client shows without every answer adding a line.
                let first = pid_n.is_none_or(|n| self.audited_clients.lock().unwrap_or_else(|e| e.into_inner()).insert(n));
                if first {
                    let en = format!("{method} from {} (pid {pid}), which runs inside a pane: {why} (logged once per process)", client.as_str());
                    self.security(Text::new(en, ""), false);
                }
            }
            Verdict::Client { .. } | Verdict::Outside => {}
            Verdict::OwnShell { pane } if !self.typed_into_recently(pane) => {}
            Verdict::OwnShell { pane } => {
                let why = format!("something other than the user's keyboard typed into pane {pane} within the last {:.0} s", first_mate::budget::tuning::PROGRAMMATIC_ECHO);
                self.security(
                    Text::new(format!("Refused {method} from pid {pid}: {why}"), format!("已拒绝 pid {pid} 的 {method}：{why}")),
                    true,
                );
                return Err(RpcError::forbidden(format!("{method} refused: {why}. Run it again yourself in a moment, or outside seahelm")));
            }
            Verdict::InPane(why) | Verdict::Unknown(why) => {
                if method.starts_with("task-source.") {
                    self.security(Text::new("Refused task source access from a pane or unidentified caller", "已拒绝窗格内进程或身份未知的调用方访问任务来源"), true);
                    return Err(RpcError::forbidden(first_mate::UserConfig::load().language.pick("Only the user may manage task sources", "只有你本人能管理任务来源")));
                }
                if method.starts_with("memory.") {
                    let text = first_mate::lang::memory_refused(method);
                    self.security(text.clone(), true);
                    return Err(RpcError::forbidden(text.get(first_mate::UserConfig::load().language)));
                }
                if crate::peer::starts_inventory(method, p) {
                    self.security(
                        Text::new(
                            format!("Refused starting First Mate's inventory from pid {pid}: {why}. Only the user asks for it, through a seahelm client or their own terminal."),
                            format!("已拒绝 pid {pid} 发起 First Mate 盘点：{why}。只有你本人能通过 seahelm 客户端或自己的终端发起。"),
                        ),
                        true,
                    );
                    return Err(RpcError::forbidden(format!(
                        "{method} refused: only the user starts the inventory, through a seahelm client; this caller is inside a seahelm pane or could not be identified ({why}). `preview: true` is read-only and allowed"
                    )));
                }
                if crate::peer::speaks_as_user(method) {
                    self.security(
                        Text::new(
                            format!("Refused {} from pid {pid}: {why}. Only the user speaks to First Mate as the user, through the app, the web or Telegram.", describe_speech(method)),
                            format!("已拒绝 pid {pid} 以你的名义对 First Mate 说话：{why}。只有你本人能通过 app、网页或 Telegram 这样做。"),
                        ),
                        true,
                    );
                    return Err(RpcError::forbidden(format!(
                        "{method} refused: only the user speaks to First Mate as the user, through a seahelm client; this caller is inside a seahelm pane or could not be identified ({why})"
                    )));
                }
                if method.starts_with("schedule.") {
                    self.security(
                        Text::new(format!("Refused {method} from pid {pid}: {why}"), format!("已拒绝 pid {pid} 的 {method}：{why}")),
                        true,
                    );
                    return Err(RpcError::forbidden(format!(
                        "{method} refused: only the user manages schedules (their own shell, in or outside seahelm); this caller is an agent or could not be identified ({why})"
                    )));
                }
                let what = describe_guarded(method, p, &self.lock().cards);
                self.security(
                    Text::new(
                        format!("Refused {what} from pid {pid}: {why}. Only the user answers cards, through the app, the web or Telegram."),
                        format!("已拒绝 pid {pid} 的卡片操作（{what}）：{why}。只有你本人能通过 app、网页或 Telegram 回答卡片。"),
                    ),
                    true,
                );
                return Err(RpcError::forbidden(format!(
                    "{method} refused: only the user answers cards, through a seahelm client; this caller is inside a seahelm pane or could not be identified ({why})"
                )));
            }
        }
        if method == "cards.raise" {
            let payload = str_param(p, "payload").unwrap_or_default();
            let taken = !payload.is_empty() && self.lock().cards.list().iter().any(|c| c.payload.as_deref() == Some(payload.as_str()));
            if taken || CORE_PAYLOADS.iter().any(|pre| payload.starts_with(pre)) {
                self.security(
                    Text::new(
                        format!("Refused a raised card carrying payload {payload} (pid {pid}): that payload is the core's"),
                        format!("已拒绝 pid {pid} 发起的一张卡片：它带的 payload {payload} 属于 core"),
                    ),
                    true,
                );
                return Err(RpcError::forbidden("cards.raise refused: that payload belongs to a card the core raised"));
            }
        }
        Ok(())
    }

    /// Whether something other than the user's keyboard typed into `pane`
    /// within `PROGRAMMATIC_ECHO` (an agent's `pane.run` into the user's
    /// shell would otherwise pass as the user).
    fn typed_into_recently(&self, pane: &str) -> bool {
        let key = self.resolve_pane(pane).unwrap_or_else(|| pane.to_string());
        self.presence.lock().unwrap_or_else(|e| e.into_inner()).typed_within(&key, first_mate::budget::tuning::PROGRAMMATIC_ECHO, now())
    }

    /// An audit line (and with `note`, a line in First Mate's conversation)
    /// about who was refused or what was put back.
    pub fn security(&self, text: Text, note: bool) {
        eprintln!("seahelm-core: security: {}", text.en);
        match self.first_mate.get() {
            Some(fm) => fm.send(first_mate::Msg::Security { text, note }),
            None => first_mate::audit_directly(&self.audit_path, &text.en),
        }
    }
}

/// A call that is the user doing something, and where: card answers,
/// words to First Mate and command lines (only the user's clients get past
/// the peer check), and typing into a pane from a chat. None otherwise.
fn presence_of(method: &str, p: &Value) -> Option<first_mate::presence::Channel> {
    let via = p.get("_meta").and_then(|m| m.get("via")).and_then(Value::as_str);
    match method {
        "cards.answer" | "cards.dismiss" | "autopilot.answer" | "autopilot.say" | "command.run" => Some(first_mate::presence::Channel::from_via(via)),
        // From the desk, typing into a pane goes to seahelmd, not here; a
        // call that says where it came from is a chat or the web.
        "pane.run" | "pane.send_text" | "pane.send_keys" if via.is_some() => Some(first_mate::presence::Channel::from_via(via)),
        _ => None,
    }
}

/// Prompts just appended (after `after`, recent, not First Mate's, not
/// seahelm's own `[seahelm …]` lines), as (pane, text).
fn user_prompts(st: &State, after: u64, now: Timestamp) -> Vec<(String, String)> {
    let Some(r) = st.messages.replay(after) else { return Vec::new() };
    r.messages
        .iter()
        .filter(|m| m.kind == seahelm_core_messages::Kind::User && m.pane_session_key != fm_policy::SESSION)
        .filter(|m| (now - m.ts).abs() <= 120.0)
        .map(|m| (m.pane_session_key.clone(), m.text.clone().unwrap_or_default()))
        .filter(|(_, t)| !t.trim_start().starts_with("[seahelm"))
        .collect()
}

/// What a refused call would have said, for the refusal line. The words
/// themselves stay out of the log (as for `command.run`'s own logging).
fn describe_speech(method: &str) -> &'static str {
    match method {
        "autopilot.say" => "speaking to First Mate as the user",
        _ => "a command line in the user's name (its prose would reach First Mate as the user's)",
    }
}

/// "an answer to card c3 (First Mate: allow …)", for the refusal line.
fn describe_guarded(method: &str, p: &Value, cards: &seahelm_core_registry::cards::Cards) -> String {
    let id = str_param(p, "id").or_else(|| str_param(p, "card"));
    let card = id.as_deref().and_then(|id| cards.list().iter().find(|c| c.id == id || c.payload.as_deref() == Some(id)).cloned());
    let what = match method {
        "cards.answer" | "autopilot.answer" => "an answer to",
        "cards.dismiss" => "dismissing",
        "cards.clear" => return format!("clearing the cards of {}", str_param(p, "worktree_path").unwrap_or_default()),
        _ => return "raising a card".into(),
    };
    match card {
        Some(c) => format!("{what} card {} ({})", c.id, c.message.chars().take(80).collect::<String>()),
        None => format!("{what} card {}", id.unwrap_or_default()),
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

    fn cursor_hook(&mut self, pane: &str, alias: &str, entries: Vec<seahelm_core_messages::transcript::Entry>, payload: Value, at: Timestamp) {
        let rows = entries.into_iter().map(|entry| seahelm_core_messages::Message::new(alias, pane, seahelm_core_messages::Kind::Assistant, at).with_text(entry.text)).collect();
        self.messages.append(rows);
        self.hook(payload, at);
    }

    fn unregister(&mut self, pane: &str) {
        if let Some(worker) = self.cursor_workers.remove(pane) {
            worker.cancelled.store(true, std::sync::atomic::Ordering::Release);
            let _guard = worker.checkpoint_gate.lock().unwrap_or_else(|e| e.into_inner());
            let _ = std::fs::remove_file(worker.checkpoint);
        }
        if let Some(info) = self.registry.pane(pane) {
            let wt = info.worktree_path.clone();
            self.aggregator.unregister_pane(pane, &wt);
        }
        // Resolve cards while the pane and its handle are still registered.
        if self.cards.drop_pane(pane, now()) {
            self.publish_cards();
        }
        self.registry.unregister(pane);
        // Gone for good: its timeline goes too.
        self.messages.clear(pane);
        if pane == fm_policy::SESSION {
            self.pending_card_rows.clear();
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
    /// An agent starting `git worktree add/remove`: a claim for the
    /// observation log, which records it as the agent's if the worktree then
    /// appears or vanishes. A subagent's call counts for its pane too.
    fn observe_worktree_commands(&self, ev: &hooks::WebhookEvent) {
        use first_mate::observations::{Msg as Obs, Verb};
        let Some(observer) = &self.observer else { return };
        let home = std::env::var("HOME").unwrap_or_default();
        let found = [
            (Verb::Create, hooks::location::created_worktree(ev.event, &ev.data, &ev.cwd, &home)),
            (Verb::Remove, hooks::location::removed_worktree(ev.event, &ev.data, &ev.cwd, &home)),
        ];
        for (verb, path) in found {
            let Some(path) = path else { continue };
            let pane = self.registry.resolve(ev.pane_id.as_deref(), &ev.cwd).unwrap_or_default();
            observer.send(Obs::AgentCommand { verb, path, pane });
        }
    }

    fn timers(&mut self, now: Timestamp) {
        if self.cards.sweep_absent(now) {
            self.publish_cards();
        }
        if self.card_history_reconcile_at.is_some_and(|at| at <= now)
            && self.registry.pane(fm_policy::SESSION).is_some()
        {
            self.card_history_reconcile_at = None;
            self.reconcile_orphan_card_rows(now);
        }
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
    fn transcript_request(&self, payload: &Value) -> Option<TranscriptRequest> {
        let ev = hooks::event::parse(payload)?;
        let pane = self.registry.resolve(ev.pane_id.as_deref(), &ev.cwd)?;
        let alias = self.registry.pane(&pane).and_then(|p| p.alias.clone()).unwrap_or_else(|| pane.clone());
        let since = self.messages.last_ts(&pane).unwrap_or(now() - 300.0);
        if ev.source == "cursor" && ev.is_subagent() { return None; }
        let source = if ev.source == "cursor" {
            TranscriptSource::Cursor {
                cwd: ev.cwd,
                chat_id: ev.session_id,
                session_start: ev.event == hooks::event::WebhookEventType::SessionStart,
            }
        } else {
            TranscriptSource::File(ev.session_path?)
        };
        Some(TranscriptRequest { pane, alias, source, since })
    }

    /// `cards.changed`: the whole list, so a renderer never has to merge.
    fn publish_cards(&mut self) {
        let changes = self.cards.take_changes();
        let mut rows = Vec::with_capacity(changes.len());
        let mut pending_rows = self.pending_card_rows.clone();
        for change in changes {
            if self.registry.pane(fm_policy::SESSION).is_none() {
                if change.state != CardState::Pending {
                    pending_rows.remove(&change.card.id);
                }
                continue;
            }
            let source = if change.state == CardState::Pending {
                let source = self.card_source(&change.card);
                let mut pending = seahelm_core_messages::Message::new(
                    fm_policy::SESSION,
                    fm_policy::SESSION,
                    seahelm_core_messages::Kind::Card,
                    change.at,
                )
                .with_text(change.card.message.lines().next().unwrap_or_default().to_string());
                pending.card_id = Some(change.card.id.clone());
                pending.card_kind = Some(change.card.kind.as_str().to_string());
                pending.source = Some(source.clone());
                pending.options = Some(change.card.labels());
                pending.state = Some(CardState::Pending.as_str().to_string());
                pending_rows.insert(change.card.id.clone(), pending);
                source
            } else {
                // Copy the source from the pending row: pane resolution may
                // now point at a different pane in the same worktree.
                let Some(source) = pending_rows.remove(&change.card.id).and_then(|pending| pending.source) else {
                    // Do not write a resolution with no corresponding pending row.
                    continue;
                };
                source
            };
            let text = change.card.message.lines().next().unwrap_or_default().to_string();
            let mut row = seahelm_core_messages::Message::new(
                fm_policy::SESSION,
                fm_policy::SESSION,
                seahelm_core_messages::Kind::Card,
                change.at,
            )
            .with_text(text);
            row.card_id = Some(change.card.id.clone());
            row.card_kind = Some(change.card.kind.as_str().to_string());
            row.source = Some(source);
            row.options = Some(change.card.labels());
            row.state = Some(change.state.as_str().to_string());
            row.option = change.option;
            row.via = change.via;
            rows.push(row);
        }
        for row in self.messages.append(rows) {
            let Some(id) = row.card_id.clone() else { continue };
            if row.state.as_deref() == Some(CardState::Pending.as_str()) {
                pending_rows.insert(id, row);
            } else {
                pending_rows.remove(&id);
            }
        }
        self.pending_card_rows = pending_rows;
        let cards = self.cards.to_json();
        self.registry.publish(json!({"type": "cards.changed", "cards": cards}));
    }

    fn reconcile_orphan_card_rows(&mut self, now: Timestamp) {
        let orphaned: Vec<String> = self.pending_card_rows.keys()
            .filter(|id| self.cards.get(id).is_none())
            .cloned()
            .collect();
        let rows = orphaned.into_iter().filter_map(|id| {
            let mut row = self.pending_card_rows.remove(&id)?;
            row.seq = 0;
            row.ts = now;
            row.state = Some(CardState::Gone.as_str().to_string());
            row.option = None;
            row.via = None;
            Some(row)
        }).collect();
        self.messages.append(rows);
    }

    fn card_source(&self, card: &seahelm_core_registry::cards::Card) -> seahelm_core_messages::event::CardSource {
        if card.first_mate || card.project == first_mate::pane::PROJECT {
            return seahelm_core_messages::event::CardSource { pane: fm_policy::SESSION.into(), label: "First Mate".into() };
        }

        let pane = self
            .registry
            .resolve((!card.pane.is_empty()).then_some(card.pane.as_str()), "")
            .or_else(|| self.registry.pane_for_worktree(&card.worktree_path).map(|p| p.id.clone()));
        if let Some(id) = pane {
            let worktree = self.registry.pane(&id).map(|p| p.worktree_path.as_str()).unwrap_or(&card.worktree_path);
            let name = std::path::Path::new(worktree).file_name().and_then(|n| n.to_str()).unwrap_or(worktree);
            let handle = self.handles.lock().unwrap_or_else(|e| e.into_inner()).handle(&id);
            let label = self.card_source_label(&id, handle, name);
            return seahelm_core_messages::event::CardSource { pane: id, label };
        }

        // Worktree-level client cards can outlive their pane.
        let name = std::path::Path::new(&card.worktree_path).file_name().and_then(|n| n.to_str()).unwrap_or(&card.worktree_path);
        if card.pane.is_empty() {
            return seahelm_core_messages::event::CardSource { pane: String::new(), label: name.into() };
        }
        let handle = self.handles.lock().unwrap_or_else(|e| e.into_inner()).handle(&card.pane);
        seahelm_core_messages::event::CardSource { pane: card.pane.clone(), label: self.card_source_label(&card.pane, handle, name) }
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
                    if self.cards.refresh_suggestion(&pane, &hooks::suggest::strip_sentinel(text), now) {
                        self.publish_cards();
                    }
                }
            }
            self.observe_worktree_commands(&ev);
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

    fn save_custom_titles(&self) {
        if let Ok(text) = serde_json::to_string_pretty(&self.custom_titles) {
            let tmp = self.custom_titles_path.with_extension("json.tmp");
            if std::fs::write(&tmp, text).is_ok() {
                let _ = std::fs::rename(&tmp, &self.custom_titles_path);
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

    /// pane.list's entry: the registry's, with what the screen says added —
    /// the terminal's title, and `display_title`, what the Mac's pane header
    /// calls the pane (seahelm-web and Telegram name panes by it). A name the
    /// user gave the pane is `custom_title`, and is the `display_title`.
    fn pane_json(&self, id: &str) -> Option<Value> {
        let mut v = self.registry.pane_json(id)?;
        let custom = self.custom_titles.get(id);
        if let (Some(obj), Some(snap)) = (v.as_object_mut(), self.panes.get(id).and_then(|s| s.snapshot.as_ref())) {
            if !snap.title.is_empty() {
                obj.insert("title".into(), json!(snap.title));
            }
            obj.insert("pwd".into(), json!(snap.pwd));
        }
        if let (Some(obj), Some(shown)) = (v.as_object_mut(), self.pane_display_title(id)) {
            obj.insert("display_title".into(), json!(shown));
        }
        if let (Some(obj), Some(t)) = (v.as_object_mut(), custom) {
            obj.insert("custom_title".into(), json!(t));
        }
        Some(v)
    }

    /// What a pane is called on every surface: the user's name for it, else
    /// the terminal's own title when it says more than the path.
    fn pane_display_title(&self, id: &str) -> Option<String> {
        if let Some(t) = self.custom_titles.get(id) {
            return Some(t.clone());
        }
        let worktree = self.registry.pane(id).map(|p| p.worktree_path.clone()).unwrap_or_default();
        let snap = self.panes.get(id).and_then(|s| s.snapshot.as_ref())?;
        let home = std::env::var("HOME").unwrap_or_default();
        crate::pane_title::display_osc_title(&snap.title, &worktree, &snap.pwd, &home)
    }

    /// `#n · title · worktree` — the title left out when there is none or it
    /// only repeats the worktree's name.
    fn card_source_label(&self, id: &str, handle: impl std::fmt::Display, worktree: &str) -> String {
        let title = self.pane_display_title(id).map(|t| t.trim().to_string()).unwrap_or_default();
        if title.is_empty() || title.eq_ignore_ascii_case(worktree) {
            format!("#{handle} · {worktree}")
        } else {
            format!("#{handle} · {title} · {worktree}")
        }
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

/// The channel explicitly identified for a card decision in `_meta.via`.
fn card_via(p: &Value) -> Option<String> {
    let raw = p.get("_meta").and_then(|m| m.get("via")).and_then(Value::as_str);
    let v = raw.filter(|v| !v.is_empty())?;
    Some(if v.starts_with("telegram") {
        "telegram".into()
    } else if v.starts_with("web") || v.starts_with("share") {
        "web".into()
    } else if v.starts_with("island") {
        "island".into()
    } else {
        v.split(':').next().unwrap_or(v).to_string()
    })
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
    fn unregistered_session_start_uses_cwd_memory_and_empty_memory_has_no_header() {
        let tmp=tempfile::tempdir().unwrap(); let repo=tmp.path().join("repo"); std::fs::create_dir(&repo).unwrap();
        assert!(std::process::Command::new("git").arg("-C").arg(&repo).args(["init","-b","main"]).output().unwrap().status.success());
        let core=Core::for_test(tmp.path());
        let main=first_mate::routing::main_repo(repo.to_str().unwrap());
        core.memory_store().note(&main,"goal: hook-only secret phrase","user").unwrap();
        for source in ["claude-code","codex","cursor"] {
            let p=json!({"hook_event_name":"SessionStart","seahelm_pane_id":"not-registered","seahelm_source":source,"cwd":repo});
            let Reply::Value(Ok(reply))=core.clone().dispatch("hook",p,now()) else { panic!() };
            let context=reply["stdout"].as_str().unwrap();
            assert!(context.contains("hook-only secret phrase")); assert_eq!(context.matches("[seahelm project memory]").count(),1);
        }
        let empty=tmp.path().join("empty"); std::fs::create_dir(&empty).unwrap();
        let Reply::Value(Ok(reply))=core.clone().dispatch("hook",json!({"hook_event_name":"SessionStart","seahelm_pane_id":"also-unregistered","seahelm_source":"codex","cwd":empty}),now()) else {panic!()};
        assert!(!reply["stdout"].as_str().unwrap().contains("[seahelm project memory]"));
        let pointer=core.memory_store().pointer(&main);
        assert!(!pointer.contains("hook-only secret phrase")); assert!(pointer.contains("SessionStart"));
        assert!(core.memory_store().pointer("/nonexistent/empty").is_empty());
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

#[cfg(test)]
mod peer_gate_tests {
    use super::*;
    use crate::peer::{Client, Verdict};

    fn value(r: Reply) -> RpcResult {
        match r {
            Reply::Value(v) => v,
            Reply::Stream(_) => panic!("a stream"),
        }
    }

    fn app() -> Verdict {
        Verdict::Client { client: Client::MacApp, in_pane: None }
    }

    fn agent() -> Verdict {
        Verdict::InPane("it runs under seahelmd session seahelm-task-x (pid 100)".into())
    }

    /// A raised approval card, as the app raises its reports.
    fn raise(core: &Arc<Core>, payload: &str) -> String {
        let p = json!({"kind": "approval", "worktree_path": "/w/x", "message": "Ship it?", "options": ["Yes", "No"], "payload": payload});
        let r = value(core.clone().call_checked("cards.raise", p, Some(1), app)).unwrap();
        r["id"].as_str().unwrap().to_string()
    }

    fn audit(dir: &std::path::Path) -> String {
        std::fs::read_to_string(dir.join("audit.jsonl")).unwrap_or_default()
    }

    #[cfg(unix)]
    #[test]
    fn real_pid_first_mate_can_note_but_cannot_undo_or_confirm() {
        use std::io::{Write, BufRead};
        use std::process::{Command, Stdio};
        struct ChildGuard(std::process::Child);
        impl Drop for ChildGuard { fn drop(&mut self) { let _=self.0.kill(); let _=self.0.wait(); } }
        let tmp=tempfile::tempdir().unwrap();
        // This is a blocking test stub, not a seahelmd/core process or live session.
        let exe=tmp.path().join("seahelmd");
        let mut cc=Command::new("cc").args(["-x","c","-o"]).arg(&exe).arg("-").stdin(Stdio::piped()).spawn().unwrap();
        cc.stdin.take().unwrap().write_all(b"#include <stdio.h>\nint main(void){puts(\"ready\");fflush(stdout);getchar();return 0;}\n").unwrap();
        assert!(cc.wait().unwrap().success());
        let mut child=ChildGuard(Command::new(&exe).args(["__serve",fm_policy::SESSION,"--"]).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap());
        let mut ready=String::new(); std::io::BufReader::new(child.0.stdout.take().unwrap()).read_line(&mut ready).unwrap(); assert_eq!(ready.trim(),"ready");
        let pid=child.0.id();
        assert!(crate::peer::first_mate_memory("memory.note",Some(pid)));
        assert!(!crate::peer::first_mate_memory("memory.undo",Some(pid)));
        assert!(!crate::peer::first_mate_memory("memory.confirm",Some(pid)));
        let core=Core::for_test(tmp.path());
        let repo=tmp.path().join("repo");
        for text in ["goal: old","don'ts: never deploy"] {
            let p=json!({"repo":repo,"text":text,"_meta":{"caller":fm_policy::SESSION}});
            assert!(value(core.clone().call_checked("memory.note",p,Some(pid),agent)).is_ok());
        }
        let err=value(core.clone().call_checked("memory.undo",json!({"repo":repo,"_meta":{"caller":fm_policy::SESSION}}),Some(pid),agent)).unwrap_err();
        assert_eq!(err.code,rpc::FORBIDDEN);
        assert!(core.memory_store().context(repo.to_str().unwrap()).contains("never deploy"));
        // An outside terminal's request still restores the previous revision.
        assert!(value(core.clone().call_checked("memory.undo",json!({"repo":repo}),Some(std::process::id()),|| Verdict::Outside)).is_ok());
        assert!(core.memory_store().context(repo.to_str().unwrap()).contains("old"));
        assert!(!core.memory_store().context(repo.to_str().unwrap()).contains("never deploy"));
        let err=value(core.clone().call_checked("memory.confirm",json!({"repo":repo,"digest":"forged","_meta":{"caller":fm_policy::SESSION}}),Some(pid),agent)).unwrap_err();
        assert_eq!(err.code,rpc::FORBIDDEN); assert!(err.message.contains("undo and confirmation require the user") || err.message.contains("撤销及确认外部编辑仅限"));
        let err=value(core.clone().call_checked("memory.note",json!({"repo":repo,"text":"evil","_meta":{"caller":fm_policy::SESSION}}),Some(std::process::id()),agent)).unwrap_err();
        assert_eq!(err.code,rpc::FORBIDDEN); assert!(!err.message.contains("answers cards"));
    }

    #[test]
    fn task_source_commands_refuse_agents_and_unidentified_peers() {
        let tmp=tempfile::tempdir().unwrap();let core=Core::for_test(tmp.path());
        for method in ["task-source.add","task-source.list","task-source.remove","task-source.test"] {
            assert_eq!(value(core.clone().call_checked(method,json!({}),Some(1),agent)).unwrap_err().code,-32003);
            assert_eq!(value(core.clone().call_checked(method,json!({}),None,||Verdict::Unknown("unreadable".into()))).unwrap_err().code,-32003);
        }
    }

    #[test]
    fn memory_writes_and_confirmations_use_the_kernel_peer() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        for method in ["memory.note", "memory.undo", "memory.confirm"] {
            let e = value(core.clone().call_checked(method, json!({"repo":"/nonexistent", "_meta":{"caller":fm_policy::SESSION}}), None, agent)).unwrap_err();
            assert_eq!(e.code, rpc::FORBIDDEN, "{method}");
        }
    }

    #[test]
    fn the_users_own_shell_may_but_not_right_after_something_typed_into_it() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let id = raise(&core, "report-own-shell");
        let own = || Verdict::OwnShell { pane: "seahelm-task-x".into() };
        // The user typing in their own pane: allowed.
        assert!(value(core.clone().call_checked("cards.dismiss", json!({"id": id}), Some(1), own)).is_ok());
        // Right after an agent typed into that pane: refused, with why.
        core.presence.lock().unwrap().typed_into("seahelm-task-x", "seahelm schedule add …", now());
        let e = value(core.clone().call_checked("schedule.add", json!({"name": "x"}), Some(1), own)).unwrap_err();
        assert_eq!(e.code, rpc::FORBIDDEN);
        assert!(e.message.contains("typed into pane seahelm-task-x"), "{}", e.message);
        // A refused schedule call no longer talks about answering cards.
        let e = value(core.clone().call_checked("schedule.add", json!({"name": "x"}), Some(1), agent)).unwrap_err();
        assert!(e.message.contains("manages schedules") && !e.message.contains("answers cards"), "{}", e.message);
    }

    #[test]
    fn an_agent_cannot_answer_or_dismiss_a_card() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let id = raise(&core, "report-1");
        for (method, p) in [
            ("cards.answer", json!({"id": id, "index": 0})),
            // `_meta.caller` is the caller's word, and changes nothing.
            ("cards.answer", json!({"id": id, "option": "Yes", "_meta": {"caller": "web"}})),
            ("cards.dismiss", json!({"id": id})),
            ("cards.clear", json!({"worktree_path": "/w/x"})),
            ("autopilot.answer", json!({"card": "report-1", "option": "Yes"})),
            ("cards.raise", json!({"kind": "report", "message": "m", "options": ["ok"]})),
        ] {
            let e = value(core.clone().call_checked(method, p, Some(4242), agent)).unwrap_err();
            assert_eq!(e.code, rpc::FORBIDDEN, "{method}");
            assert!(e.message.contains("only the user answers cards") && e.message.contains("seahelm-task-x"), "{method}: {}", e.message);
        }
        // The card is still there, unanswered.
        assert_eq!(core.lock().cards.list().len(), 1);
        // Every refusal is written down, naming the card and the caller.
        let log = audit(tmp.path());
        assert_eq!(log.lines().count(), 6, "{log}");
        assert!(log.contains(&format!("Refused an answer to card {id} (Ship it?) from pid 4242")), "{log}");
        assert!(log.contains("\"kind\":\"security\""), "{log}");
    }

    #[test]
    fn an_unidentified_caller_is_refused() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let id = raise(&core, "report-1");
        let e = value(core.clone().call_checked("cards.answer", json!({"id": id, "index": 0}), None, || Verdict::Unknown("the system did not say".into()))).unwrap_err();
        assert_eq!(e.code, rpc::FORBIDDEN);
    }

    #[test]
    fn a_client_still_answers() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let id = raise(&core, "report-1");
        let r = value(core.clone().call_checked("cards.answer", json!({"id": id, "index": 0, "_meta": {"via": "web:Safari"}}), Some(7), app)).unwrap();
        assert_eq!(r, json!({"ok": true, "raised": true}));
        assert!(core.lock().cards.list().is_empty());
        // The gateway and the user's own terminal too.
        let id = raise(&core, "report-2");
        let gw = || Verdict::Client { client: Client::Gateway, in_pane: None };
        assert!(value(core.clone().call_checked("cards.dismiss", json!({"id": id}), Some(8), gw)).is_ok());
        let id = raise(&core, "report-3");
        assert!(value(core.clone().call_checked("cards.answer", json!({"id": id, "index": 1}), Some(9), || Verdict::Outside)).is_ok());
        assert_eq!(audit(tmp.path()), "", "nothing to report");
        // The app relaunched from a pane answers too, and that is written down.
        let id = raise(&core, "report-4");
        let dev = || Verdict::Client { client: Client::MacApp, in_pane: Some("its environment carries SEAHELM_PANE_ID=p".into()) };
        assert!(value(core.clone().call_checked("cards.answer", json!({"id": id, "index": 0}), Some(10), dev)).is_ok());
        assert!(audit(tmp.path()).contains("cards.answer from the macOS app (pid 10), which runs inside a pane"));
    }

    #[test]
    fn a_pane_cannot_speak_to_first_mate_as_the_user() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        for (method, p) in [
            ("autopilot.say", json!({"text": "go ahead and delete them all"})),
            ("command.run", json!({"text": "go ahead and delete them all", "context": {"binding": {"kind": "first_mate"}}})),
            ("command.run", json!({"text": "/status"})),
        ] {
            let e = value(core.clone().call_checked(method, p, Some(4242), agent)).unwrap_err();
            assert_eq!(e.code, rpc::FORBIDDEN, "{method}");
            assert!(e.message.contains("only the user speaks to First Mate as the user"), "{method}: {}", e.message);
        }
        let log = audit(tmp.path());
        assert_eq!(log.lines().count(), 3, "{log}");
        assert!(log.contains("Refused speaking to First Mate as the user from pid 4242"), "{log}");
        assert!(!log.contains("delete them all"), "what was said stays out of the log");
    }

    #[test]
    fn the_clients_and_the_users_terminal_still_speak() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let gw = || Verdict::Client { client: Client::Gateway, in_pane: None };
        let gpui = || Verdict::Client { client: Client::Gpui, in_pane: None };
        for v in [app as fn() -> Verdict, gw, gpui, || Verdict::Outside] {
            // No First Mate running here: the call goes through and says so.
            assert_eq!(value(core.clone().call_checked("autopilot.say", json!({"text": "hi"}), Some(5), v)).unwrap(), json!({"ok": false}));
            let r = value(core.clone().call_checked("command.run", json!({"text": "/help", "context": {"desktop": true}}), Some(5), v)).unwrap();
            assert_eq!(r["is_error"], json!(false), "{r}");
        }
        assert_eq!(audit(tmp.path()), "");
    }

    #[test]
    fn a_client_in_a_pane_is_logged_once_per_process() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let dev = || Verdict::Client { client: Client::MacApp, in_pane: Some("its environment carries SEAHELM_PANE_ID=p".into()) };
        for _ in 0..3 {
            let id = raise(&core, "");
            assert!(value(core.clone().call_checked("cards.answer", json!({"id": id, "index": 0}), Some(10), dev)).is_ok());
            assert!(value(core.clone().call_checked("autopilot.say", json!({"text": "hi"}), Some(10), dev)).is_ok());
        }
        assert_eq!(audit(tmp.path()).lines().count(), 1, "{}", audit(tmp.path()));
        // Another process is another line.
        assert!(value(core.clone().call_checked("autopilot.say", json!({"text": "hi"}), Some(11), dev)).is_ok());
        assert_eq!(audit(tmp.path()).lines().count(), 2);
    }

    #[test]
    fn a_pane_cannot_start_the_inventory_but_may_preview_it() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        for p in [json!({}), json!({"preview": false})] {
            let e = value(core.clone().call_checked("habits.inventory", p.clone(), Some(4242), agent)).unwrap_err();
            assert_eq!(e.code, rpc::FORBIDDEN, "{p}");
            assert!(e.message.contains("only the user starts the inventory"), "{}", e.message);
            let e = value(core.clone().call_checked("habits.inventory", p, Some(4243), || Verdict::Unknown("the system did not say".into()))).unwrap_err();
            assert_eq!(e.code, rpc::FORBIDDEN);
        }
        let log = audit(tmp.path());
        assert_eq!(log.lines().count(), 4, "{log}");
        assert!(log.contains("Refused starting First Mate's inventory from pid 4242"), "{log}");
        // The preview only reads: a pane may look.
        let r = value(core.clone().call_checked("habits.inventory", json!({"preview": true}), Some(4242), agent)).unwrap();
        assert!(r["groups"].is_array(), "{r}");
        assert_eq!(audit(tmp.path()).lines().count(), 4, "nothing more to report");
        // A client gets through the check (and, with no First Mate here, is told so).
        let e = value(core.clone().call_checked("habits.inventory", json!({}), Some(7), app)).unwrap_err();
        assert_eq!(e.code, first_mate::REFUSED);
        assert!(e.message.contains("not running"), "{}", e.message);
        assert_eq!(audit(tmp.path()).lines().count(), 4);
    }

    #[test]
    fn a_raised_card_cannot_wear_the_cores_payload() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        raise(&core, "report-1");
        for payload in ["habit.promote:_global/delete-merged-clean:auto:n-1", "habit.sweep:x", "autopilot-0000abcd", "proposal-1", "research.stop:news", "report-1"] {
            let p = json!({"kind": "approval", "message": "Tidy whitespace?", "options": ["Yes", "No"], "payload": payload});
            let e = value(core.clone().call_checked("cards.raise", p, Some(1), app)).unwrap_err();
            assert_eq!(e.code, rpc::FORBIDDEN, "{payload}");
        }
        assert_eq!(core.lock().cards.list().len(), 1);
    }

    #[test]
    fn research_summary_rejects_spoofed_meta_without_an_identifiable_peer() {
        let tmp = tempfile::tempdir().unwrap(); let core = Core::for_test(tmp.path());
        let peer = rpc::Peer { pid: None, foreign_user: false };
        let p = json!({"name": "news", "summary": "spoofed", "_meta": {"caller": "seahelm-first-mate"}});
        let error = value(core.call_from(&peer, "research.summary", p)).unwrap_err();
        assert!(error.message.contains("real session"));
    }

    #[test]
    fn in_process_calls_are_the_cores_own() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let id = raise(&core, "report-1");
        assert!(value(core.clone().call("cards.answer", json!({"id": id, "index": 0}))).is_ok());
    }

    /// Over a real socket: the core sees this test process for what it is.
    /// Run from a seahelm pane (development), it is refused; anywhere else
    /// (CI, a plain terminal), it answers.
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn over_the_socket_the_kernel_decides() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let id = raise(&core, "report-1");
        let sock = tmp.path().join("core.sock");
        let listener = rpc::bind(&sock).unwrap();
        let dispatch: Arc<dyn Dispatch> = core.clone();
        std::thread::spawn(move || rpc::serve(listener, dispatch));
        let in_pane = crate::peer::PANE_ENV.iter().any(|k| std::env::var(k).is_ok_and(|v| !v.is_empty()));
        let r = rpc::call(&sock, "cards.answer", json!({"id": id, "index": 0, "_meta": {"caller": "", "via": "web:x"}}));
        if in_pane {
            let e = r.unwrap_err().to_string();
            assert!(e.contains("-32003") && e.contains("only the user answers cards"), "{e}");
            assert_eq!(core.lock().cards.list().len(), 1);
        } else {
            assert!(r.is_ok(), "{r:?}");
        }
        // Reading is anyone's.
        assert!(rpc::call(&sock, "cards.list", json!({})).is_ok());
    }
}

#[cfg(test)]
mod presence_tests {
    use super::*;
    use crate::first_mate::presence::Channel;
    use crate::peer::{Client, Verdict};

    fn app() -> Verdict {
        Verdict::Client { client: Client::MacApp, in_pane: None }
    }

    fn visible(core: &Arc<Core>, client: &str, worktrees: &[&str], active: bool) {
        let _ = core.clone().call("client.visible", json!({"client": client, "worktrees": worktrees, "app_active": active}));
    }

    #[test]
    fn a_client_coming_to_the_front_is_the_user_but_a_reconnect_is_not() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        // First report since the core started (a reconnect after a restart): no signal.
        visible(&core, "macos", &["/w/a"], true);
        assert_eq!(core.presence().profile.last_seen, 0.0);
        assert!(core.presence().desktop_in_front);
        // The same again: nothing moved.
        visible(&core, "macos", &["/w/a"], true);
        assert_eq!(core.presence().profile.last_seen, 0.0);
        // Another worktree selected while in front: the user.
        visible(&core, "macos", &["/w/b"], true);
        let p = core.presence();
        assert!(p.profile.last_seen > 0.0);
        assert!(p.profile.seen_on(Channel::Desktop) > 0.0);
        assert!(p.profile.last_arrival.is_some(), "the first signal ever is an arrival");
        // Leaving, then coming back: also the user. Leaving alone is not.
        visible(&core, "macos", &["/w/b"], false);
        assert!(!core.presence().desktop_in_front);
        // A web client in front is not a desktop.
        visible(&core, "web", &[], true);
        assert!(!core.presence().desktop_in_front);
        // The profile is on disk beside the audit log.
        assert!(tmp.path().join(crate::first_mate::presence::FILE_NAME).exists());
    }

    #[test]
    fn activity_in_a_client_window_is_the_user() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let _ = core.clone().call("client.activity", json!({"client": "macos"}));
        assert!(core.presence().profile.seen_on(Channel::Desktop) > 0.0);
        assert!(core.presence().active(seahelm_core_types::now()));
    }

    #[test]
    fn answers_and_words_carry_their_channel() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let _ = core.clone().call_checked("cards.dismiss", json!({"id": "nope", "_meta": {"via": "telegram:@me"}}), Some(1), app);
        assert!(core.presence().profile.seen_on(Channel::Telegram) > 0.0);
        assert_eq!(core.presence().profile.seen_on(Channel::Web), 0.0);
        let _ = core.clone().call_checked("pane.send_keys", json!({"pane_id": "x", "keys": ["escape"], "_meta": {"via": "web:Safari"}}), Some(1), app);
        assert!(core.presence().profile.seen_on(Channel::Web) > 0.0);
        // Reads are not the user doing anything.
        let before = core.presence().profile.last_seen;
        let _ = core.clone().call_checked("cards.list", json!({}), Some(1), app);
        let _ = core.clone().call_checked("pane.run", json!({"pane_id": "x", "command": "ls"}), Some(1), app);
        assert_eq!(core.presence().profile.last_seen, before, "a pane.run that says nothing of where is an agent or the desk's own path");
    }

    #[test]
    fn a_prompt_right_after_something_typed_it_is_not_the_user() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let now = seahelm_core_types::now();
        let prompt = |pane: &str, text: &str| vec![(pane.to_string(), text.to_string())];
        core.presence.lock().unwrap().typed_into("seahelm-a", "fix the CI", now);
        core.prompts_seen(&prompt("seahelm-a", "fix the CI"), true, now + 5.0);
        assert_eq!(core.presence().profile.last_seen, 0.0, "First Mate's or an agent's own prompt");
        core.prompts_seen(&prompt("seahelm-a", "fix the CI"), true, now + 600.0);
        assert_eq!(core.presence().profile.last_seen, 0.0, "submitted late by a busy agent: still not the user");
        core.prompts_seen(&prompt("seahelm-b", "what about this?"), false, now + 6.0);
        let p = core.presence().profile;
        assert_eq!(p.last_seen, now + 6.0);
        assert_eq!(p.seen_on(Channel::Desktop), 0.0, "no client in front: where is unknown");
        core.prompts_seen(&prompt("seahelm-b", "and this"), true, now + 7.0);
        assert_eq!(core.presence().profile.seen_on(Channel::Desktop), now + 7.0);
    }
}

#[cfg(test)]
mod card_timeline_tests {
    use super::*;

    fn registration() -> Registration {
        Registration {
            pane: "seahelm-pane-1".into(),
            alias: Some("client-pane-1".into()),
            worktree_path: "/workspace/saas-mono".into(),
            project: "saas-mono".into(),
            branch: "main".into(),
            agent_type: AgentType::ClaudeCode,
            started_at: None,
        }
    }

    #[test]
    fn cursor_store_prose_precedes_the_tool_hook_in_sequence() {
        let dir = tempfile::tempdir().unwrap();
        let core = Core::for_test(dir.path());
        let mut state = core.lock();
        state.register(registration());
        for (i, text) in ["Inspect the file.", "Now fix the problem."].iter().enumerate() {
            let payload = json!({"source":"cursor", "session_id":"chat", "event":"tool_use_start", "cwd":"/workspace/saas-mono", "seahelm_pane_id":"seahelm-pane-1", "data":{"tool_name":"Shell", "tool_input":{"command":format!("command-{i}")}}});
            state.cursor_hook("seahelm-pane-1", "client-pane-1", vec![seahelm_core_messages::transcript::Entry { thinking:false, text:text.to_string(), timestamp:None }], payload, 100.0 + i as f64 * 10.0);
        }
        let rows = state.messages.snapshot(Some("seahelm-pane-1"));
        let relevant: Vec<_> = rows.iter().filter(|row| matches!(row.kind, seahelm_core_messages::Kind::Assistant | seahelm_core_messages::Kind::Tool)).collect();
        assert_eq!(relevant.iter().map(|row| row.kind).collect::<Vec<_>>(), [seahelm_core_messages::Kind::Assistant, seahelm_core_messages::Kind::Tool, seahelm_core_messages::Kind::Assistant, seahelm_core_messages::Kind::Tool]);
        assert!(relevant.windows(2).all(|pair| pair[0].seq < pair[1].seq));
    }

    #[test]
    fn unregister_stops_cursor_worker_and_deletes_checkpoint() {
        let dir = tempfile::tempdir().unwrap();
        let core = Core::for_test(dir.path());
        let (sender, receiver) = std::sync::mpsc::channel();
        let cancelled = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let checkpoint = dir.path().join("checkpoint");
        std::fs::write(&checkpoint, "saved").unwrap();
        {
            let mut state = core.lock();
            state.register(registration());
            state.cursor_workers.insert("seahelm-pane-1".into(), CursorWorker { sender, cancelled:cancelled.clone(), checkpoint:checkpoint.clone(), checkpoint_gate:Arc::new(Mutex::new(())) });
        }
        core.close_pane("seahelm-pane-1");
        assert!(core.lock().cursor_workers.is_empty());
        assert!(cancelled.load(std::sync::atomic::Ordering::Acquire));
        assert!(!checkpoint.exists());
        assert!(matches!(receiver.recv_timeout(Duration::from_millis(100)), Err(std::sync::mpsc::RecvTimeoutError::Disconnected)));
    }

    fn second_registration() -> Registration {
        Registration {
            pane: "seahelm-pane-2".into(),
            alias: Some("client-pane-2".into()),
            ..registration()
        }
    }

    fn first_mate_registration() -> Registration {
        Registration {
            pane: fm_policy::SESSION.into(),
            alias: Some("first-mate".into()),
            worktree_path: "/workspace/first-mate".into(),
            project: "First Mate".into(),
            branch: "main".into(),
            agent_type: AgentType::ClaudeCode,
            started_at: None,
        }
    }

    fn card(kind: CardKind, message: &str) -> Raise {
        Raise {
            kind: Some(kind),
            pane: "seahelm-pane-1".into(),
            worktree_path: "/workspace/saas-mono".into(),
            message: message.into(),
            options: vec!["Review".into(), "Dismiss".into()],
            ..Raise::default()
        }
    }

    fn card_rows(st: &State) -> Vec<Value> {
        st.messages
            .snapshot(Some(fm_policy::SESSION))
            .into_iter()
            .filter(|m| m.kind == seahelm_core_messages::Kind::Card)
            .map(|m| m.to_json())
            .collect()
    }

    #[test]
    fn card_rows_name_the_pane_by_its_title() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let mut st = core.lock();
        st.register(registration());
        st.register(first_mate_registration());
        st.custom_titles.insert("seahelm-pane-1".into(), "修登录".into());

        st.cards.raise(card(CardKind::Report, "Check these files"), 1.0).unwrap();
        st.publish_cards();
        assert_eq!(card_rows(&st)[0]["source"]["label"], "#1 · 修登录 · saas-mono");

        // A title that only repeats the worktree is not said twice.
        st.custom_titles.insert("seahelm-pane-1".into(), "saas-mono".into());
        st.cards.raise(card(CardKind::Report, "Another"), 2.0).unwrap();
        st.publish_cards();
        assert_eq!(card_rows(&st).last().unwrap()["source"]["label"], "#1 · saas-mono");
    }

    #[test]
    fn card_rows_record_raise_and_each_resolution_by_card_id() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let mut st = core.lock();
        st.register(registration());
        st.register(first_mate_registration());

        let id = st.cards.raise(card(CardKind::Report, "Check these files\nMore detail"), 1.0).unwrap();
        st.publish_cards();
        let rows = card_rows(&st);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["card_id"], id);
        assert_eq!(rows[0]["card_kind"], "report");
        assert_eq!(rows[0]["state"], "pending");
        assert_eq!(rows[0]["text"], "Check these files");
        assert_eq!(rows[0]["options"], json!(["Review", "Dismiss"]));
        assert_eq!(rows[0]["source"], json!({"pane": "seahelm-pane-1", "label": "#1 · saas-mono"}));

        assert!(matches!(st.cards.answer_via(&id, "Review", None, Some("web".into()), 2.0), Ok(Answer::Raised { .. })));
        st.publish_cards();
        let rows = card_rows(&st);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["card_id"], rows[1]["card_id"]);
        assert_eq!(rows[1]["state"], "answered");
        assert_eq!(rows[1]["option"], "Review");
        assert_eq!(rows[1]["via"], "web");

        let mut dismissal = card(CardKind::Approval, "Approve this");
        dismissal.pane.clear();
        let dismissed = st.cards.raise(dismissal, 3.0).unwrap();
        st.publish_cards();
        assert!(st.cards.dismiss(&dismissed, card_via(&json!({})), 4.0));
        st.publish_cards();
        assert_eq!(card_rows(&st).last().unwrap()["state"], "dismissed");
        assert!(card_rows(&st).last().unwrap().get("via").is_none());

        let expired = st.cards.raise(card(CardKind::Proposal, "Try this"), 5.0).unwrap();
        st.publish_cards();
        assert!(st.cards.resolve(&expired, CardState::Expired, None, None, 6.0));
        st.publish_cards();
        assert_eq!(card_rows(&st).last().unwrap()["state"], "expired");

        let gone = st.cards.raise(card(CardKind::Question, "Choose this"), 7.0).unwrap();
        st.publish_cards();
        assert!(st.cards.remove(&gone, 8.0));
        st.publish_cards();
        assert_eq!(card_rows(&st).last().unwrap()["state"], "gone");
        drop(st);

        let fm_id = core.raise_card(Raise {
            kind: Some(CardKind::Proposal),
            message: "First Mate recommends this".into(),
            options: vec!["Go".into(), "Later".into()],
            payload: Some("expire-in-test".into()),
            ..Raise::default()
        }).unwrap();
        {
            let mut st = core.lock();
            let card = st.cards.get(&fm_id).unwrap();
            assert!(card.pane.is_empty());
            assert!(card.first_mate);
            assert!(!st.cards.drop_pane(fm_policy::SESSION, 8.5));
            assert!(st.cards.get(&fm_id).is_some());
        }
        core.expire_card_payload("expire-in-test");
        let fm_rows: Vec<_> = core.messages_of(fm_policy::SESSION).into_iter().filter(|m| m.card_id.as_deref() == Some(&fm_id)).collect();
        assert_eq!(fm_rows.iter().map(|m| m.state.as_deref().unwrap()).collect::<Vec<_>>(), ["pending", "expired"]);
        assert_eq!(fm_rows[0].source.as_ref().unwrap().label, "First Mate");
    }

    #[test]
    fn a_resolution_keeps_the_pending_source_after_its_pane_is_unregistered() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let mut st = core.lock();
        st.register(registration());
        st.register(second_registration());
        st.register(first_mate_registration());
        let id = st.cards.raise(card(CardKind::Question, "Allow this command"), 1.0).unwrap();
        st.publish_cards();
        let pending_source = card_rows(&st)[0]["source"].clone();
        assert_eq!(pending_source["label"], "#1 · saas-mono");
        st.unregister("seahelm-pane-1");
        let rows = card_rows(&st);
        assert_eq!(rows.iter().map(|row| row["state"].as_str().unwrap()).collect::<Vec<_>>(), ["pending", "gone"]);
        assert_eq!(rows[1]["card_id"], id);
        assert_eq!(rows[1]["source"], pending_source);
    }

    #[test]
    fn cards_clear_records_gone_and_card_rows_require_first_mate_registration() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        core.register_pane(first_mate_registration());
        let id = core.raise_card(Raise {
            kind: Some(CardKind::Proposal),
            worktree_path: "/workspace/first-mate".into(),
            message: "A First Mate proposal".into(),
            options: vec!["Go".into()],
            payload: Some("clear-test".into()),
            ..Raise::default()
        }).unwrap();
        let pending = core.messages_of(fm_policy::SESSION);
        let pending = pending.iter().find(|row| row.card_id.as_deref() == Some(&id)).unwrap();
        assert_eq!(pending.state.as_deref(), Some("pending"));
        assert!(matches!(core.clone().call("cards.clear", json!({"worktree_path": "/workspace/first-mate"})), Reply::Value(Ok(_))));
        let rows: Vec<_> = core.messages_of(fm_policy::SESSION).into_iter().filter(|row| row.card_id.as_deref() == Some(&id)).collect();
        assert_eq!(rows.iter().map(|row| row.state.as_deref().unwrap()).collect::<Vec<_>>(), ["pending", "gone"]);
        assert!(rows[1].via.is_none());
    }

    #[test]
    fn cards_without_first_mate_registration_are_available_live_but_not_recorded() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let id = core.raise_card(Raise {
            kind: Some(CardKind::Proposal),
            message: "A First Mate proposal".into(),
            options: vec!["Go".into()],
            payload: Some("not-recorded".into()),
            ..Raise::default()
        }).unwrap();
        assert!(core.messages_of(fm_policy::SESSION).is_empty());
        assert!(core.lock().cards.get(&id).is_some());
    }

    #[test]
    fn startup_marks_stale_pending_rows_gone_after_the_reconcile_delay() {
        let tmp = tempfile::tempdir().unwrap();
        let message_dir = tmp.path().join("messages");
        let mut persisted = seahelm_core_messages::Hub::new(
            Some(seahelm_core_messages::hub::Store::open(&message_dir, 2000)),
            80,
        );
        let mut old = seahelm_core_messages::Message::new(
            fm_policy::SESSION,
            fm_policy::SESSION,
            seahelm_core_messages::Kind::Card,
            1.0,
        ).with_text("Old approval");
        old.card_id = Some("c-1".into());
        old.card_kind = Some("approval".into());
        old.source = Some(seahelm_core_messages::event::CardSource {
            pane: "seahelm-pane-1".into(),
            label: "#1 · saas-mono".into(),
        });
        old.options = Some(vec!["Allow".into(), "Deny".into()]);
        old.state = Some("pending".into());
        persisted.append(vec![old]);
        drop(persisted);

        let messages = seahelm_core_messages::Hub::new(
            Some(seahelm_core_messages::hub::Store::open(&message_dir, 2000)),
            80,
        );
        let handles = seahelm_core_command::Handles::open(&tmp.path().join("handles.json"), None);
        let core = Core::assemble(
            ManifestStore::bundled(),
            tmp.path(),
            messages,
            handles,
            tmp.path().join("audit.jsonl"),
        );
        let mut st = core.lock();
        st.card_history_reconcile_at = Some(30.0);

        st.timers(30.0);
        assert_eq!(card_rows(&st).len(), 1, "wait until First Mate's pane is registered");

        st.register(first_mate_registration());
        let live = st.cards.raise(Raise {
            kind: Some(CardKind::Proposal),
            worktree_path: "/workspace/first-mate".into(),
            project: "First Mate".into(),
            message: "Live after restart".into(),
            options: vec!["Go".into()],
            first_mate: true,
            ..Raise::default()
        }, 20.0).unwrap();
        assert_eq!(live, "c-2", "card IDs continue past persisted timeline rows");
        st.publish_cards();
        assert!(card_rows(&st).iter().all(|row| row["card_id"] != "c-1" || row["state"] == "pending"));

        st.timers(30.0);
        let rows = card_rows(&st);
        let old_rows: Vec<_> = rows.iter().filter(|row| row["card_id"] == "c-1").collect();
        assert_eq!(old_rows.iter().map(|row| row["state"].as_str().unwrap()).collect::<Vec<_>>(), ["pending", "gone"]);
        assert_eq!(old_rows[1]["source"], json!({"pane": "seahelm-pane-1", "label": "#1 · saas-mono"}));
        assert_eq!(rows.iter().filter(|row| row["card_id"] == live && row["state"] == "pending").count(), 1);
        assert!(!rows.iter().any(|row| row["card_id"] == live && row["state"] == "gone"));
    }

    fn outcome(info: seahelm_core_registry::PaneInfo, kind: EventKind, status: AgentStatus) -> Outcome {
        let pane = info.id.clone();
        Outcome {
            info,
            status_changed: false,
            old_status: status,
            new_status: status,
            hold_seconds: 0.0,
            is_completion_signal: false,
            event: NormalizedEvent { pane, source: EventSource::Hook("claude-code".into()), kind },
            seq: 0,
        }
    }

    #[test]
    fn a_user_prompt_withdraws_the_suggestion_from_the_timeline() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let mut st = core.lock();
        st.register(registration());
        st.register(first_mate_registration());
        let info = st.registry.pane("seahelm-pane-1").unwrap().clone();
        st.settle(&outcome(info.clone(), EventKind::Suggest { options: vec!["Run tests".into()] }, AgentStatus::Idle), 1.0);
        let pending = card_rows(&st);
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0]["state"], "pending");
        let id = pending[0]["card_id"].as_str().unwrap().to_string();

        st.settle(&outcome(info, EventKind::UserPrompt { text: "Do this next".into() }, AgentStatus::Running), 2.0);
        let rows = card_rows(&st);
        assert_eq!(rows.iter().filter(|r| r["card_id"] == id).map(|r| r["state"].as_str().unwrap()).collect::<Vec<_>>(), ["pending", "gone"]);
        assert!(!st.cards.list().iter().any(|c| c.id == id));
    }

    #[test]
    fn running_edge_withdraws_previous_suggestions_from_all_clients_and_history() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let mut st = core.lock();
        st.register(registration());
        st.register(first_mate_registration());
        let info = st.registry.pane("seahelm-pane-1").unwrap().clone();
        st.settle(&outcome(info.clone(), EventKind::Suggest { options: vec!["Next".into()] }, AgentStatus::Idle), 1.0);
        let id = st.cards.list()[0].id.clone();
        let mut start = outcome(info, EventKind::ProgramStatus { record: Some(seahelm_core_types::ProgramStatus {
                state: seahelm_core_types::ProgramState::Working, kind: None, progress: None,
                app: "codex".into(), title: String::new(), msg: String::new(),
            }) }, AgentStatus::Running);
        start.event.source = EventSource::Osc7501;
        start.old_status = AgentStatus::Idle;
        start.status_changed = true;
        st.settle(&start, 2.0);
        assert!(st.cards.list().is_empty());
        assert!(!st.pending_card_rows.contains_key(&id));
        let rows = card_rows(&st);
        assert_eq!(rows.iter().filter(|r| r["card_id"] == id).map(|r| r["state"].as_str().unwrap()).collect::<Vec<_>>(), ["pending", "gone"]);
    }

    #[test]
    fn scanned_choice_text_update_keeps_id_and_appends_pending_update_row() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let mut st = core.lock();
        st.register(registration());
        st.register(first_mate_registration());
        let info = st.registry.pane("seahelm-pane-1").unwrap().clone();
        let question = |prompt: &str| {
            let mut o = outcome(info.clone(), EventKind::Question {
                prompt: prompt.into(),
                options: vec!["Yes".into(), "No".into()],
                followups: vec![],
                flags: seahelm_core_types::QuestionFlags::default(),
            }, AgentStatus::Waiting);
            o.event.source = EventSource::Scan;
            o
        };
        st.settle(&question("Continue with the current operation?"), 1.0);
        let first = card_rows(&st);
        let id = first[0]["card_id"].as_str().unwrap().to_string();
        st.settle(&question("Continue with the updated operation?"), 2.0);

        let rows: Vec<_> = card_rows(&st).into_iter().filter(|row| row["card_id"] == id).collect();
        assert_eq!(rows.iter().map(|row| row["state"].as_str().unwrap()).collect::<Vec<_>>(), ["pending", "pending"]);
        assert_eq!(rows[0]["text"], "Continue with the current operation?");
        assert_eq!(rows[1]["text"], "Continue with the updated operation?");
    }

    #[test]
    fn suggestion_refresh_appends_updated_pending_text_under_the_same_id() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        let mut st = core.lock();
        st.register(registration());
        st.register(first_mate_registration());
        let info = st.registry.pane("seahelm-pane-1").unwrap().clone();
        st.settle(&outcome(info, EventKind::Suggest { options: vec!["Run tests".into()] }, AgentStatus::Idle), 1.0);
        let id = card_rows(&st)[0]["card_id"].as_str().unwrap().to_string();
        assert!(st.cards.refresh_suggestion("seahelm-pane-1", "The tests are ready.", 2.0));
        st.publish_cards();

        let rows: Vec<_> = card_rows(&st).into_iter().filter(|row| row["card_id"] == id).collect();
        assert_eq!(rows.iter().map(|row| row["state"].as_str().unwrap()).collect::<Vec<_>>(), ["pending", "pending"]);
        assert_eq!(rows[1]["text"], "The tests are ready.");
    }
}

#[cfg(test)]
mod pane_rename_tests {
    use super::*;
    use crate::peer::{Client, Verdict};

    fn call(core: &Arc<Core>, method: &str, p: Value) -> RpcResult {
        match core.clone().call_checked(method, p, Some(1), || Verdict::Client { client: Client::MacApp, in_pane: None }) {
            Reply::Value(v) => v,
            Reply::Stream(_) => panic!("a stream"),
        }
    }

    fn listed(core: &Arc<Core>) -> Value {
        call(core, "pane.list", json!({})).unwrap()["panes"][0].clone()
    }

    #[test]
    fn a_name_is_shown_kept_cleared_and_forgotten() {
        let tmp = tempfile::tempdir().unwrap();
        let core = Core::for_test(tmp.path());
        call(&core, "pane.register", json!({"pane": "seahelm-repo-a", "worktree_path": "/w/repo"})).unwrap();

        let r = call(&core, "pane.rename", json!({"pane_id": "seahelm-repo-a", "title": "  修登录\n bug "})).unwrap();
        assert_eq!(r["custom_title"], "修登录 bug");
        let p = listed(&core);
        assert_eq!(p["custom_title"], "修登录 bug");
        assert_eq!(p["display_title"], "修登录 bug");
        let seq = core.lock().registry.seq();
        assert!(core.lock().registry.events().events_after(seq - 1).iter().any(|e| e["type"] == "pane.renamed" && e["custom_title"] == "修登录 bug"));

        // A restarted core still knows it.
        let core = Core::for_test(tmp.path());
        call(&core, "pane.register", json!({"pane": "seahelm-repo-a", "worktree_path": "/w/repo"})).unwrap();
        assert_eq!(listed(&core)["custom_title"], "修登录 bug");

        // An empty title gives the pane its own back.
        assert!(call(&core, "pane.rename", json!({"pane_id": "seahelm-repo-a", "title": ""})).unwrap()["custom_title"].is_null());
        assert!(listed(&core).get("custom_title").is_none());

        // A pane closed for good does not pass its name to the next one.
        call(&core, "pane.rename", json!({"pane_id": "seahelm-repo-a", "title": "x"})).unwrap();
        call(&core, "agent.forget", json!({"pane_session_key": "seahelm-repo-a"})).unwrap();
        assert!(listed(&core).get("custom_title").is_none());

        assert!(call(&core, "pane.rename", json!({"pane_id": "nope", "title": "x"})).is_err());
    }
}
