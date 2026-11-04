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

use crate::rpc::{self, Dispatch, Reply, RpcError, RpcResult};

pub struct Core {
    state: Mutex<State>,
    /// Signalled whenever the registry's sequence moves.
    changed: Condvar,
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
    /// Panes registered by `pane.sync` (shadow mode), so a sync removes only
    /// what it added.
    synced: HashSet<String>,
    /// Worktrees a client shows, and whether that client is frontmost:
    /// "on screen" for unseen completion.
    visible: HashSet<String>,
    app_active: bool,
    /// The newest location each pane's agent reported (`pane.location`).
    locations: HashMap<String, Value>,
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
                locations: HashMap::new(),
                session_refs,
                session_refs_path,
                cycle: 0,
                policy: NotificationPolicy::new(),
                signals: CompletionSignals::new(),
                retries: Vec::new(),
            }),
            changed: Condvar::new(),
        }))
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
        let result: RpcResult = match method {
            "core.ping" => Ok(json!({"ok": true, "version": env!("CARGO_PKG_VERSION")})),
            "hook" | "suggest" => {
                let mut st = self.lock();
                let before = st.registry.seq();
                st.hook(p, now);
                let moved = st.registry.seq() != before;
                drop(st);
                if moved {
                    self.changed.notify_all();
                }
                Ok(json!({}))
            }
            "worktrees.set" => {
                let paths: Vec<String> = strings(&p, "paths");
                let mut st = self.lock();
                st.provider.set_worktrees(&paths, now);
                st.registry.reorder(&paths);
                Ok(json!({"worktrees": paths.len()}))
            }
            "pane.register" => {
                let Some(r) = registration(&p) else {
                    return Reply::Value(Err(RpcError::invalid_params("pane and worktree_path required")));
                };
                let mut st = self.lock();
                st.register(r);
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
                let mut st = self.lock();
                let n = st.sync(&panes);
                Ok(json!({"panes": n}))
            }
            "client.visible" => {
                let mut st = self.lock();
                st.visible = strings(&p, "worktrees").into_iter().collect();
                st.app_active = p.get("app_active").and_then(Value::as_bool).unwrap_or(true);
                if st.app_active {
                    let shown: Vec<String> = st.visible.iter().cloned().collect();
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
                let st = self.lock();
                let panes: Vec<Value> = st.registry.panes().filter_map(|p| st.pane_json(&p.id)).collect();
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
                let st = self.lock();
                Ok(json!({"worktrees": st.worktrees_json(now)}))
            }
            "pane.locations" => {
                let st = self.lock();
                Ok(json!({"locations": st.locations}))
            }
            "agent.sessions" => {
                let st = self.lock();
                Ok(json!({"agent_sessions": st.session_refs}))
            }
            "pane.wait_agent_status" | "wait.agent_status" => self.wait_status(&p),
            "usage.summary" => Ok(crate::usage::summary(now)),
            "events.subscribe" => return self.subscribe(p),
            other => Err(RpcError::not_found(other)),
        };
        Reply::Value(result)
    }

    /// `pane.wait_agent_status {pane_id, status, timeout}`: wait until the
    /// pane reaches the status (`done` means idle or exited).
    fn wait_status(&self, p: &Value) -> RpcResult {
        let hint = str_param(p, "pane_id").ok_or_else(|| RpcError::invalid_params("pane_id required"))?;
        let want = str_param(p, "status").unwrap_or_else(|| "done".into()).to_lowercase();
        let timeout = p.get("timeout").and_then(Value::as_f64).unwrap_or(600.0);
        let deadline = Instant::now() + Duration::from_secs_f64(timeout.max(0.0));
        let matches = |s: AgentStatus| match want.as_str() {
            "done" => matches!(s, AgentStatus::Idle | AgentStatus::Exited),
            w => s.as_str().eq_ignore_ascii_case(w),
        };
        let mut st = self.lock();
        loop {
            let id = st.registry.resolve(Some(&hint), "").ok_or_else(|| RpcError::invalid_params("unknown pane"))?;
            let status = st.registry.pane(&id).map(|p| p.status).unwrap_or_default();
            if matches(status) {
                return Ok(json!({"matched": true, "status": status.as_str()}));
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Ok(json!({"matched": false, "status": status.as_str()}));
            }
            st = self.changed.wait_timeout(st, left.min(Duration::from_millis(500))).unwrap_or_else(|e| e.into_inner()).0;
        }
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
    }

    fn unregister(&mut self, pane: &str) {
        if let Some(info) = self.registry.pane(pane) {
            let wt = info.worktree_path.clone();
            self.aggregator.unregister_pane(pane, &wt);
        }
        self.registry.unregister(pane);
        self.panes.remove(pane);
        self.synced.remove(pane);
    }

    /// Mirror a client's pane list (the app's `pane.list` entries): register
    /// what is new, re-file what moved, drop what this sync added and is gone.
    fn sync(&mut self, panes: &[Value]) -> usize {
        let mut seen = HashSet::new();
        for p in panes {
            let Some(key) = str_param(p, "pane_session_key") else { continue };
            let Some(worktree) = str_param(p, "worktree_path") else { continue };
            seen.insert(key.clone());
            let branch = str_param(p, "branch").unwrap_or_default();
            let project = str_param(p, "project").unwrap_or_default();
            match self.registry.pane(&key).map(|i| i.worktree_path.clone()) {
                Some(old) if old == worktree => {}
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
                    self.synced.insert(key);
                }
            }
        }
        let gone: Vec<String> = self.synced.iter().filter(|k| !seen.contains(*k)).cloned().collect();
        for k in gone {
            self.unregister(&k);
        }
        seen.len()
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
            has_pending_card: false,
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
            let out = self.provider.handle(&ev, now, &mut hooks::provider::probe_worktree_root);
            if let Some(loc) = &out.pane_location {
                if let Some(pane) = self.registry.resolve(Some(&loc.pane), "") {
                    self.locations.insert(
                        pane,
                        json!({"worktree": loc.worktree, "location": loc.location, "created_by_agent": loc.created_by_agent, "at": now}),
                    );
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
                        self.session_refs.insert(key, v);
                        self.save_session_refs();
                    }
                }
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
                json!({
                    "worktree_path": wt,
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
