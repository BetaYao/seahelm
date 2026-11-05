//! What happened, recorded as evidence for First Mate's habits later
//! (docs/first-mate-autonomy.md, "The learning loop" › "Observations"):
//! worktrees removed and created, and by whom, and how the user answered
//! First Mate's cards. Nothing acts on it yet.
//!
//! `first-mate/observations.jsonl`, append-only, one JSON object per line:
//! `{id, at, kind, repo, worktree, branch, by, …kind's own fields}`.
//! Trimmed by age (`RETENTION_DAYS`) when opened, never by size: it is the
//! evidence a habit cites.
//!
//! A removal carries the core's *last measurement* of the worktree before
//! it vanished (`Core::measure_worktree_with`, serialized `Facts`): the
//! observer re-measures every live worktree on a slow cadence
//! (`FACTS_EVERY`, and when one first appears) on a thread of its own, so
//! no RPC ever waits on git, and no app change is needed to know what was
//! in a worktree the user deleted from the app. These measurements never
//! fetch a PR head: keeping the log fresh must not go to the network.
//!
//! Recording does not follow First Mate's on/off switch: it runs whenever
//! the core runs. The point of the log is that by the time the user turns
//! First Mate on there is already evidence of how they clean up, so its
//! first habits are drawn from what they did rather than from nothing.
//! That includes someone who has never turned First Mate on, so the core
//! creates First Mate's directory at start (`ensure_dir`) — the directory
//! only, which starts nothing: First Mate itself still runs only on
//! `autopilot_enabled`.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use super::engine::iso8601;
use super::facts;
use crate::core::Core;

pub const FILE_NAME: &str = "observations.jsonl";
pub const RETENTION_DAYS: f64 = 90.0;
/// How often a live worktree is re-measured.
pub const FACTS_EVERY: f64 = 10.0 * 60.0;
/// How long a claim on a worktree ("First Mate deleted it", "an agent ran
/// `git worktree add` for it") waits for the worktree to change.
pub const CLAIM_WINDOW: f64 = 30.0 * 60.0;
/// A worktree first seen whose `.git` is younger than this counts as
/// created now; older ones are the fleet as it already was.
pub const NEWBORN: f64 = 10.0 * 60.0;
const TICK: Duration = Duration::from_secs(20);
/// Measurements per tick at most, so a big fleet is measured over a few
/// ticks instead of one long stall.
const PROBES_PER_TICK: usize = 10;

pub mod kind {
    pub const WORKTREE_REMOVED: &str = "worktree.removed";
    pub const WORKTREE_CREATED: &str = "worktree.created";
    /// One of First Mate's cards (approval or proposal) answered or dismissed.
    pub const CARD_ANSWERED: &str = "card.answered";
    /// One of First Mate's cards withdrawn unanswered after
    /// `budget::tuning::CARD_EXPIRY` (phase 5).
    pub const CARD_EXPIRED: &str = "card.expired";
}

/// Who did it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum By {
    User,
    /// An agent in a pane (its hook showed `git worktree add/remove`, or it
    /// called the core with its pane as caller).
    Agent,
    /// First Mate's gated call, run on its own (`auto`) or after the user
    /// said yes to its card.
    FirstMate,
}

impl By {
    pub fn as_str(self) -> &'static str {
        match self {
            By::User => "user",
            By::Agent => "agent",
            By::FirstMate => "first_mate",
        }
    }
}

/// One line of the log.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Record {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub at: String,
    pub kind: String,
    #[serde(default)]
    pub repo: String,
    #[serde(default)]
    pub worktree: String,
    #[serde(default)]
    pub branch: String,
    #[serde(default)]
    pub by: String,
    /// The kind's own fields (`facts`, `prompt`, `option`, …).
    #[serde(flatten)]
    pub fields: Map<String, Value>,
}

impl Record {
    pub fn new(kind: &str, by: By) -> Self {
        Record { kind: kind.into(), by: by.as_str().into(), ..Record::default() }
    }

    pub fn with(mut self, key: &str, value: Value) -> Self {
        self.fields.insert(key.into(), value);
        self
    }
}

/// The log file. Ids are `obs-<unix ms>`, bumped past the last one written,
/// so they stay unique and in order across restarts without a counter file
/// and are never reused once a line is trimmed away.
pub struct Log {
    path: PathBuf,
    last_id: Mutex<u64>,
}

impl Log {
    /// Open the log, dropping lines older than `RETENTION_DAYS`.
    pub fn open(path: PathBuf, now: f64) -> Self {
        let cutoff = iso8601(now - RETENTION_DAYS * 86_400.0);
        let text = std::fs::read_to_string(&path).unwrap_or_default();
        let mut last_id = 0;
        let mut kept = Vec::new();
        let mut dropped = false;
        for line in text.lines().filter(|l| !l.trim().is_empty()) {
            let Ok(r) = serde_json::from_str::<Record>(line) else {
                dropped = true;
                continue;
            };
            last_id = last_id.max(id_number(&r.id));
            // Every `at` is written by `iso8601`, so the text orders as time does.
            if r.at.as_str() < cutoff.as_str() {
                dropped = true;
            } else {
                kept.push(line);
            }
        }
        if dropped {
            let tmp = path.with_extension("jsonl.tmp");
            let body: String = kept.iter().map(|l| format!("{l}\n")).collect();
            if std::fs::write(&tmp, body).is_ok() {
                let _ = std::fs::rename(&tmp, &path);
            }
        }
        Log { path, last_id: Mutex::new(last_id) }
    }

    /// Stamp `record` with an id and the time, and append it.
    pub fn append(&self, now: f64, mut record: Record) -> Record {
        let mut last = self.last_id.lock().unwrap_or_else(|e| e.into_inner());
        let id = ((now * 1000.0) as u64).max(*last + 1);
        *last = id;
        record.id = format!("obs-{id}");
        record.at = iso8601(now);
        if let Ok(line) = serde_json::to_string(&record) {
            if let Some(dir) = self.path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&self.path) {
                let _ = f.write_all(format!("{line}\n").as_bytes());
            }
        }
        record
    }

    /// The last `n` records, oldest first. For habits (phase 3) to read.
    #[allow(dead_code)]
    pub fn recent(&self, n: usize) -> Vec<Record> {
        let all = self.read_all();
        all[all.len().saturating_sub(n)..].to_vec()
    }

    /// Records at or after `since` (unix seconds), oldest first.
    #[allow(dead_code)]
    pub fn since(&self, since: f64) -> Vec<Record> {
        let from = iso8601(since);
        self.read_all().into_iter().filter(|r| r.at.as_str() >= from.as_str()).collect()
    }

    #[allow(dead_code)]
    fn read_all(&self) -> Vec<Record> {
        let _g = self.last_id.lock().unwrap_or_else(|e| e.into_inner());
        std::fs::read_to_string(&self.path).unwrap_or_default().lines().filter_map(|l| serde_json::from_str(l).ok()).collect()
    }
}

/// Every record in the log at `path`, oldest first, without trimming or
/// writing: for readers on other threads (the habits), so they never race
/// the observer's appends.
pub fn read_records(path: &Path) -> Vec<Record> {
    std::fs::read_to_string(path).unwrap_or_default().lines().filter_map(|l| serde_json::from_str(l).ok()).collect()
}

fn id_number(id: &str) -> u64 {
    id.strip_prefix("obs-").and_then(|n| n.parse().ok()).unwrap_or(0)
}


// MARK: attribution

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Verb {
    Create,
    Remove,
}

/// Someone said they are about to create or remove a worktree.
#[derive(Clone, Debug)]
struct Claim {
    path: String,
    verb: Verb,
    by: By,
    at: f64,
    /// Extra fields for the record (`prompt`, `pane`, `card`, `how`).
    fields: Map<String, Value>,
}

/// Claims waiting for their worktree to change. When it does, the strongest
/// claim names the actor: First Mate over an agent, an agent over nobody
/// (the user).
#[derive(Default)]
pub struct Claims {
    claims: Vec<Claim>,
}

impl Claims {
    pub fn claim(&mut self, path: &str, verb: Verb, by: By, now: f64, fields: Map<String, Value>) {
        self.claims.push(Claim { path: norm(path), verb, by, at: now, fields });
    }

    /// Who changed `path`, with their fields; `User` when nobody claimed it.
    /// Matching claims are used up; stale ones are dropped.
    pub fn take(&mut self, path: &str, verb: Verb, now: f64) -> (By, Map<String, Value>) {
        self.claims.retain(|c| now - c.at <= CLAIM_WINDOW);
        let key = norm(path);
        let rank = |b: By| match b {
            By::FirstMate => 2,
            By::Agent => 1,
            By::User => 0,
        };
        let mut best: Option<Claim> = None;
        self.claims.retain(|c| {
            if c.verb != verb || c.path != key {
                return true;
            }
            if best.as_ref().is_none_or(|b| rank(c.by) > rank(b.by) || (rank(c.by) == rank(b.by) && c.fields.len() > b.fields.len())) {
                best = Some(c.clone());
            }
            false
        });
        best.map(|c| (c.by, c.fields)).unwrap_or((By::User, Map::new()))
    }

    pub fn has(&self, path: &str, verb: Verb, now: f64) -> bool {
        let key = norm(path);
        self.claims.iter().any(|c| c.verb == verb && c.path == key && now - c.at <= CLAIM_WINDOW)
    }
}

/// A path to compare by: canonical when it exists, else its parent made
/// canonical (a removed worktree's directory is gone, its parent usually
/// not), else as written without a trailing slash.
pub fn norm(path: &str) -> String {
    let p = Path::new(path.trim_end_matches('/'));
    if let Ok(c) = p.canonicalize() {
        return c.to_string_lossy().into_owned();
    }
    if let (Some(parent), Some(name)) = (p.parent(), p.file_name()) {
        if let Ok(c) = parent.canonicalize() {
            return c.join(name).to_string_lossy().into_owned();
        }
    }
    p.to_string_lossy().into_owned()
}

// MARK: watching worktrees

/// A live worktree as last measured.
#[derive(Clone, Debug, PartialEq)]
pub struct Known {
    pub repo: String,
    pub branch: String,
    /// The last measurement: `Facts`, serialized.
    pub facts: Option<Value>,
    /// When `facts` was taken (unix seconds); 0 before the first time.
    pub measured_at: f64,
}

/// What one look at the fleet found.
#[derive(Debug, Default, PartialEq)]
pub struct Scan {
    /// Worktrees first seen this time, now in `known`.
    pub appeared: Vec<String>,
    /// Worktrees gone from disk, with what was last known of them.
    pub gone: Vec<(String, Known)>,
}

/// The worktrees the core has seen, and which of them vanished. Pure: the
/// disk and git are the caller's closures, so it is tested without either.
#[derive(Default)]
pub struct Watch {
    pub known: HashMap<String, Known>,
    /// Missing at the last look, not yet reported: a worktree must be
    /// missing twice in a row, so a claim sent just after the removal
    /// (First Mate's call returning) still arrives in time, and a volume
    /// that blinks does not read as a deletion.
    missing: HashSet<String>,
    /// Live paths that are not worktrees (no repo, the main checkout).
    ignored: HashSet<String>,
}

impl Watch {
    /// `live`: the worktrees clients list and panes sit in. `present`: the
    /// directory is there and still a checkout. `info`: its repo and branch,
    /// None for anything not a linked worktree.
    pub fn scan(
        &mut self,
        live: &HashSet<String>,
        present: impl Fn(&str) -> bool,
        mut info: impl FnMut(&str) -> Option<(String, String)>,
    ) -> Scan {
        let mut scan = Scan::default();
        self.ignored.retain(|p| live.contains(p));
        let mut fresh: Vec<&String> = live.iter().filter(|p| !self.known.contains_key(*p) && !self.ignored.contains(*p)).collect();
        fresh.sort();
        for path in fresh {
            if !present(path) {
                continue;
            }
            match info(path) {
                Some((repo, branch)) => {
                    self.known.insert(path.clone(), Known { repo, branch, facts: None, measured_at: 0.0 });
                    scan.appeared.push(path.clone());
                }
                None => {
                    self.ignored.insert(path.clone());
                }
            }
        }
        let mut paths: Vec<String> = self.known.keys().cloned().collect();
        paths.sort();
        for path in paths {
            if present(&path) {
                self.missing.remove(&path);
                // Still on disk but nobody lists it: dropped from the fleet,
                // not removed. Forget it quietly.
                if !live.contains(&path) {
                    self.known.remove(&path);
                }
                continue;
            }
            // The repo is gone too: the volume dropped out or the repo moved.
            // Not a removal; keep watching.
            if !present(&self.known[&path].repo) {
                self.missing.remove(&path);
                continue;
            }
            if self.missing.insert(path.clone()) {
                continue;
            }
            self.missing.remove(&path);
            if let Some(k) = self.known.remove(&path) {
                scan.gone.push((path, k));
            }
        }
        scan
    }

    /// Up to `max` worktrees due a measurement, never-measured and oldest first.
    pub fn due(&self, now: f64, max: usize) -> Vec<String> {
        let mut due: Vec<(&String, f64)> = self.known.iter().filter(|(_, k)| now - k.measured_at >= FACTS_EVERY).map(|(p, k)| (p, k.measured_at)).collect();
        due.sort_by(|a, b| a.1.total_cmp(&b.1).then_with(|| a.0.cmp(b.0)));
        due.into_iter().take(max).map(|(p, _)| p.clone()).collect()
    }

    pub fn measured(&mut self, path: &str, facts: Value, now: f64) {
        if let Some(k) = self.known.get_mut(path) {
            k.facts = Some(facts);
            k.measured_at = now;
        }
    }

    /// Forget `path`, returning what was known: First Mate's removal is
    /// recorded at once, so the scan must not report it again.
    pub fn take(&mut self, path: &str) -> Option<(String, Known)> {
        let key = self.known.keys().find(|k| *k == path || norm(k) == norm(path)).cloned()?;
        self.missing.remove(&key);
        self.known.remove(&key).map(|k| (key, k))
    }
}

/// The record for a worktree that vanished.
pub fn removed_record(path: &str, known: &Known, by: By, fields: Map<String, Value>) -> Record {
    let mut r = Record::new(kind::WORKTREE_REMOVED, by);
    r.repo = known.repo.clone();
    r.worktree = path.into();
    r.branch = known.branch.clone();
    r.fields = fields;
    r.fields.insert("facts".into(), known.facts.clone().unwrap_or(Value::Null));
    r
}

// MARK: the observer thread

/// What the rest of the core tells the observer.
pub enum Msg {
    /// A core-performed `worktree.create` / `worktree.delete` succeeded.
    /// `how`: `auto`, `approved` or `picked` for First Mate's.
    Performed { method: String, params: Value, result: Value, by: By, how: Option<String>, card: Option<String>, pane: Option<String> },
    /// A pane's agent started `git worktree add/remove` on `path`.
    AgentCommand { verb: Verb, path: String, pane: String },
    /// One of First Mate's cards was answered (`option` None: dismissed).
    /// `habit`: the habit it was about (`<key>/<id>`), for habit cards and
    /// delete approvals a habit matched.
    CardAnswered {
        card_kind: &'static str,
        card: String,
        option: Option<String>,
        via: Option<String>,
        summary: String,
        action: Option<String>,
        worktree: String,
        repo: String,
        habit: Option<String>,
    },
    /// One of First Mate's cards expired unanswered and was withdrawn.
    /// `habit`: the habits it counted as ignored (`<key>/<id>`, comma-joined).
    CardExpired { card_kind: &'static str, card: String, summary: String, worktree: String, repo: String, habit: Option<String> },
}

#[derive(Clone)]
pub struct Handle(Sender<Msg>);

impl Handle {
    pub fn send(&self, m: Msg) {
        let _ = self.0.send(m);
    }
}

/// First Mate's directory, made if missing, so the log has somewhere to go
/// before First Mate has ever run. Making it starts nothing.
pub fn ensure_dir(dir: &Path) -> bool {
    std::fs::create_dir_all(dir).is_ok()
}

/// Start the observer, creating First Mate's directory for its log.
pub fn spawn(core: Arc<Core>) -> Handle {
    let (tx, rx) = mpsc::channel();
    let dir = super::pane::dir();
    if !ensure_dir(&dir) {
        eprintln!("seahelm-core: cannot create {}: observations are off", dir.display());
    }
    let obs = Observer { core: Some(core), dir, log: None, watch: Watch::default(), claims: Claims::default() };
    let _ = std::thread::Builder::new().name("seahelm-core-observations".into()).spawn(move || obs.run(rx));
    Handle(tx)
}

struct Observer {
    /// None only in tests.
    core: Option<Arc<Core>>,
    dir: PathBuf,
    log: Option<Log>,
    watch: Watch,
    claims: Claims,
}

impl Observer {
    fn run(mut self, rx: Receiver<Msg>) {
        let mut last_tick: Option<std::time::Instant> = None;
        loop {
            let wait = last_tick.map(|t| TICK.saturating_sub(t.elapsed())).unwrap_or_default();
            match rx.recv_timeout(wait) {
                Ok(m) => self.handle(m, seahelm_core_types::now()),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            if last_tick.is_none_or(|t| t.elapsed() >= TICK) {
                last_tick = Some(std::time::Instant::now());
                self.tick(seahelm_core_types::now());
            }
        }
    }

    /// The log, opened (and trimmed) on first use. The directory is made at
    /// start (`ensure_dir`); if that failed nothing is written.
    fn log(&mut self, now: f64) -> Option<&Log> {
        if self.log.is_none() && self.dir.is_dir() {
            self.log = Some(Log::open(self.dir.join(FILE_NAME), now));
        }
        self.log.as_ref()
    }

    fn write(&mut self, now: f64, r: Record) {
        if let Some(log) = self.log(now) {
            log.append(now, r);
        }
    }

    fn handle(&mut self, m: Msg, now: f64) {
        match m {
            Msg::Performed { method, params, result, by, how, card, pane } => {
                let mut fields = Map::new();
                if let Some(h) = how {
                    fields.insert("how".into(), json!(h));
                }
                if let Some(c) = card {
                    fields.insert("card".into(), json!(c));
                }
                if let Some(p) = pane {
                    fields.insert("pane".into(), json!(p));
                }
                let path = result.get("worktree_path").and_then(Value::as_str).unwrap_or_default().to_string();
                if path.is_empty() {
                    return;
                }
                match method.as_str() {
                    "worktree.create" => {
                        if let Some(p) = params.get("prompt").and_then(Value::as_str) {
                            fields.insert("prompt".into(), json!(p));
                        }
                        self.claims.claim(&path, Verb::Create, by, now, fields);
                    }
                    "worktree.delete" if result.get("deleted").and_then(Value::as_bool) == Some(true) => {
                        // Recorded now, with the last measurement, rather than
                        // left for the scan to find.
                        let (key, known) = self.watch.take(&path).unwrap_or_else(|| {
                            (path.clone(), Known { repo: String::new(), branch: String::new(), facts: None, measured_at: 0.0 })
                        });
                        let r = removed_record(&key, &known, by, fields);
                        self.write(now, r);
                    }
                    _ => {}
                }
            }
            Msg::AgentCommand { verb, path, pane } => {
                let mut fields = Map::new();
                fields.insert("pane".into(), json!(pane));
                self.claims.claim(&path, verb, By::Agent, now, fields);
            }
            Msg::CardAnswered { card_kind, card, option, via, summary, action, worktree, repo, habit } => {
                let mut r = Record::new(kind::CARD_ANSWERED, By::User)
                    .with("card_kind", json!(card_kind))
                    .with("card", json!(card))
                    .with("option", json!(option))
                    .with("summary", json!(summary));
                if let Some(a) = action {
                    r = r.with("action", json!(a));
                }
                if let Some(h) = habit {
                    r = r.with("habit", json!(h));
                }
                // Where the user answered: the island, the web, Telegram… when the
                // client said so.
                r = r.with("via", json!(via));
                r.worktree = worktree;
                r.repo = repo;
                if let Some(k) = self.watch.known.get(&r.worktree) {
                    r.branch = k.branch.clone();
                    if r.repo.is_empty() {
                        r.repo = k.repo.clone();
                    }
                }
                self.write(now, r);
            }
            Msg::CardExpired { card_kind, card, summary, worktree, repo, habit } => {
                // Nobody answered: `by` is the user, who let it go.
                let mut r = Record::new(kind::CARD_EXPIRED, By::User).with("card_kind", json!(card_kind)).with("card", json!(card)).with("summary", json!(summary));
                if let Some(h) = habit {
                    r = r.with("habit", json!(h));
                }
                r.worktree = worktree;
                r.repo = repo;
                self.write(now, r);
            }
        }
    }

    fn tick(&mut self, now: f64) {
        if !self.dir.is_dir() {
            return;
        }
        let Some(core) = self.core.clone() else { return };
        let fm_dir = self.dir.to_string_lossy().into_owned();
        let live: HashSet<String> = core.live_worktrees().into_iter().filter(|w| *w != fm_dir).collect();
        let scan = self.watch.scan(&live, is_checkout, worktree_info);
        self.apply(scan, now, worktree_born);
        for path in self.watch.due(now, PROBES_PER_TICK) {
            let f = core.measure_worktree_with(&path, None, false);
            self.watch.measured(&path, serde_json::to_value(&f).unwrap_or(Value::Null), now);
        }
    }

    /// Write what a scan found. `born`: when a worktree was made, if known.
    fn apply(&mut self, scan: Scan, now: f64, born: impl Fn(&str) -> Option<f64>) {
        for (path, known) in scan.gone {
            let (by, fields) = self.claims.take(&path, Verb::Remove, now);
            let r = removed_record(&path, &known, by, fields);
            self.write(now, r);
        }
        for path in scan.appeared {
            let claimed = self.claims.has(&path, Verb::Create, now);
            let newborn = born(&path).is_some_and(|t| now - t <= NEWBORN);
            if !claimed && !newborn {
                continue;
            }
            let (by, fields) = self.claims.take(&path, Verb::Create, now);
            let Some(k) = self.watch.known.get(&path) else { continue };
            let mut r = Record::new(kind::WORKTREE_CREATED, by);
            r.repo = k.repo.clone();
            r.worktree = path.clone();
            r.branch = k.branch.clone();
            r.fields = fields;
            self.write(now, r);
        }
    }
}

/// The directory is there and is a checkout (`.git` file or directory).
fn is_checkout(path: &str) -> bool {
    Path::new(path).join(".git").exists()
}

/// A linked worktree's repo (its main checkout) and branch; None for the
/// main checkout itself and anything that is not a checkout.
pub fn worktree_info(path: &str) -> Option<(String, String)> {
    let wt = Path::new(path);
    let common = facts::git(wt, &["rev-parse", "--path-format=absolute", "--git-common-dir"])?;
    let repo = Path::new(common.trim()).parent()?.to_string_lossy().into_owned();
    if norm(&repo) == norm(path) {
        return None;
    }
    let branch = facts::git(wt, &["rev-parse", "--abbrev-ref", "HEAD"]).map(|b| b.trim().to_string()).unwrap_or_default();
    Some((repo, branch))
}

/// When a linked worktree was made: its `.git` file is written by
/// `git worktree add` and not touched after.
fn worktree_born(path: &str) -> Option<f64> {
    let m = std::fs::metadata(Path::new(path).join(".git")).ok()?;
    let t = m.created().or_else(|_| m.modified()).ok()?;
    t.duration_since(std::time::UNIX_EPOCH).ok().map(|d| d.as_secs_f64())
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: f64 = 86_400.0;
    const NOW: f64 = 1_793_000_000.0;

    fn observer(dir: &Path) -> Observer {
        Observer { core: None, dir: dir.to_path_buf(), log: None, watch: Watch::default(), claims: Claims::default() }
    }

    fn live(paths: &[&str]) -> HashSet<String> {
        paths.iter().map(|p| p.to_string()).collect()
    }

    fn info(p: &str) -> Option<(String, String)> {
        (p != "/r/repo").then(|| ("/r/repo".to_string(), format!("b/{}", Path::new(p).file_name().unwrap().to_string_lossy())))
    }

    #[test]
    fn appends_with_ids_and_reads_back() {
        let tmp = tempfile::tempdir().unwrap();
        let log = Log::open(tmp.path().join(FILE_NAME), NOW);
        let a = log.append(NOW, Record::new(kind::WORKTREE_CREATED, By::User).with("prompt", json!("fix it")));
        let b = log.append(NOW, Record::new(kind::WORKTREE_REMOVED, By::Agent));
        let c = log.append(NOW + 60.0, Record::new(kind::CARD_ANSWERED, By::User));
        assert!(a.id.starts_with("obs-"));
        // Same millisecond still gets distinct, increasing ids.
        assert!(id_number(&b.id) > id_number(&a.id) && id_number(&c.id) > id_number(&b.id));
        assert_eq!(a.at, "2026-10-26T07:33:20Z");

        let line = std::fs::read_to_string(tmp.path().join(FILE_NAME)).unwrap().lines().next().unwrap().to_string();
        let v: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(v["kind"], "worktree.created");
        assert_eq!(v["by"], "user");
        assert_eq!(v["prompt"], "fix it");

        assert_eq!(log.recent(2).iter().map(|r| r.id.clone()).collect::<Vec<_>>(), vec![b.id.clone(), c.id.clone()]);
        assert_eq!(log.since(NOW + 1.0), vec![c.clone()]);
        assert_eq!(log.recent(10)[0].fields["prompt"], "fix it");

        // A reopened log keeps counting past the last id.
        let again = Log::open(tmp.path().join(FILE_NAME), NOW + 60.0);
        let d = again.append(NOW, Record::new(kind::CARD_EXPIRED, By::User));
        assert!(id_number(&d.id) > id_number(&c.id));
    }

    #[test]
    fn trims_by_age_on_open() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join(FILE_NAME);
        let log = Log::open(path.clone(), NOW - 100.0 * DAY);
        let old = log.append(NOW - 100.0 * DAY, Record::new(kind::WORKTREE_REMOVED, By::User));
        let kept = log.append(NOW - 10.0 * DAY, Record::new(kind::WORKTREE_REMOVED, By::User));
        std::fs::OpenOptions::new().append(true).open(&path).unwrap().write_all(b"not json\n").unwrap();

        let log = Log::open(path.clone(), NOW);
        assert_eq!(log.recent(10), vec![kept.clone()]);
        assert_eq!(std::fs::read_to_string(&path).unwrap().lines().count(), 1);
        // The trimmed id is never handed out again.
        let next = log.append(NOW - 200.0 * DAY, Record::new(kind::WORKTREE_CREATED, By::User));
        assert!(id_number(&next.id) > id_number(&old.id).max(id_number(&kept.id)));
    }

    #[test]
    fn a_worktree_gone_twice_is_removed_with_its_last_facts() {
        let mut w = Watch::default();
        let on_disk = std::cell::RefCell::new(live(&["/r/repo", "/r/wt-a", "/r/wt-b"]));
        let present = |p: &str| on_disk.borrow().contains(p);

        let s = w.scan(&live(&["/r/repo", "/r/wt-a", "/r/wt-b"]), present, info);
        assert_eq!(s.appeared, vec!["/r/wt-a", "/r/wt-b"]);
        assert!(!w.known.contains_key("/r/repo"), "the main checkout is not watched");
        assert_eq!(w.due(NOW, 10), vec!["/r/wt-a", "/r/wt-b"]);
        w.measured("/r/wt-a", json!({"unpushed": 0, "changed": 0}), NOW);
        assert_eq!(w.due(NOW + 60.0, 10), vec!["/r/wt-b"]);
        assert_eq!(w.due(NOW + FACTS_EVERY, 1), vec!["/r/wt-b"], "never-measured first");

        // Removed: the app drops it from its list and the directory goes.
        on_disk.borrow_mut().remove("/r/wt-a");
        let lv = live(&["/r/repo", "/r/wt-b"]);
        assert_eq!(w.scan(&lv, present, info), Scan::default(), "missing once is not yet a removal");
        let s = w.scan(&lv, present, info);
        assert_eq!(s.gone.len(), 1);
        assert_eq!(s.gone[0].0, "/r/wt-a");
        assert_eq!(s.gone[0].1.facts, Some(json!({"unpushed": 0, "changed": 0})));
        assert_eq!(s.gone[0].1.branch, "b/wt-a");
        assert!(w.scan(&lv, present, info).gone.is_empty(), "reported once");
    }

    #[test]
    fn dropped_from_the_list_or_a_lost_volume_is_not_a_removal() {
        let mut w = Watch::default();
        let on_disk = std::cell::RefCell::new(live(&["/r/repo", "/r/wt-a", "/r/wt-b"]));
        let present = |p: &str| on_disk.borrow().contains(p);
        w.scan(&live(&["/r/wt-a", "/r/wt-b"]), present, info);

        // wt-a untracked by the app but still on disk: forgotten, not removed.
        for _ in 0..3 {
            assert!(w.scan(&live(&["/r/wt-b"]), present, info).gone.is_empty());
        }
        assert!(!w.known.contains_key("/r/wt-a"));

        // The volume drops out: worktree and repo both missing.
        on_disk.borrow_mut().clear();
        for _ in 0..3 {
            assert!(w.scan(&live(&[]), present, info).gone.is_empty());
        }
        assert!(w.known.contains_key("/r/wt-b"));
    }

    #[test]
    fn missing_then_back_is_not_a_removal() {
        let mut w = Watch::default();
        let on_disk = std::cell::RefCell::new(live(&["/r/repo", "/r/wt-a"]));
        let present = |p: &str| on_disk.borrow().contains(p);
        w.scan(&live(&["/r/wt-a"]), present, info);
        on_disk.borrow_mut().remove("/r/wt-a");
        w.scan(&live(&["/r/wt-a"]), present, info);
        on_disk.borrow_mut().insert("/r/wt-a".into());
        w.scan(&live(&["/r/wt-a"]), present, info);
        on_disk.borrow_mut().remove("/r/wt-a");
        assert!(w.scan(&live(&["/r/wt-a"]), present, info).gone.is_empty());
    }

    #[test]
    fn claims_name_the_actor() {
        let mut c = Claims::default();
        assert_eq!(c.take("/r/wt", Verb::Remove, NOW).0, By::User);

        let mut pane = Map::new();
        pane.insert("pane".into(), json!("s1"));
        c.claim("/r/wt/", Verb::Remove, By::Agent, NOW, pane);
        assert_eq!(c.take("/r/wt", Verb::Create, NOW).0, By::User, "a remove claim says nothing about a create");
        let (by, fields) = c.take("/r/wt", Verb::Remove, NOW + 5.0);
        assert_eq!((by, fields["pane"].clone()), (By::Agent, json!("s1")));
        assert_eq!(c.take("/r/wt", Verb::Remove, NOW + 6.0).0, By::User, "used up");

        c.claim("/r/wt", Verb::Remove, By::Agent, NOW, Map::new());
        c.claim("/r/wt", Verb::Remove, By::FirstMate, NOW, Map::new());
        assert_eq!(c.take("/r/wt", Verb::Remove, NOW).0, By::FirstMate, "First Mate's gated call outranks the hook");

        c.claim("/r/wt", Verb::Create, By::Agent, NOW, Map::new());
        assert!(!c.has("/r/wt", Verb::Create, NOW + CLAIM_WINDOW + 1.0));
        assert_eq!(c.take("/r/wt", Verb::Create, NOW + CLAIM_WINDOW + 1.0).0, By::User, "stale claims lapse");
    }

    fn records(dir: &Path) -> Vec<Record> {
        Log::open(dir.join(FILE_NAME), NOW).recent(100)
    }

    #[test]
    fn removals_are_recorded_with_attribution_and_facts() {
        let tmp = tempfile::tempdir().unwrap();
        let mut o = observer(tmp.path());
        let on_disk = std::cell::RefCell::new(live(&["/r/repo", "/r/a", "/r/b", "/r/c"]));
        let present = |p: &str| on_disk.borrow().contains(p);
        let all = live(&["/r/a", "/r/b", "/r/c"]);
        let s = o.watch.scan(&all, present, info);
        o.apply(s, NOW, |_| Some(NOW - DAY));
        assert!(records(tmp.path()).is_empty(), "the fleet as it was is not news");
        for p in ["/r/a", "/r/b", "/r/c"] {
            o.watch.measured(p, json!({"unpushed": 0, "pr": {"state": "merged"}}), NOW);
        }

        // An agent's hook showed `git worktree remove /r/b`.
        o.handle(Msg::AgentCommand { verb: Verb::Remove, path: "/r/b".into(), pane: "seahelm-x".into() }, NOW);
        // First Mate's approved delete of /r/c returned: recorded at once.
        o.handle(
            Msg::Performed {
                method: "worktree.delete".into(),
                params: json!({"worktree_path": "/r/c"}),
                result: json!({"worktree_path": "/r/c", "deleted": true}),
                by: By::FirstMate,
                how: Some("approved".into()),
                card: Some("autopilot-1".into()),
                pane: None,
            },
            NOW,
        );
        on_disk.borrow_mut().retain(|p| p == "/r/repo");
        for t in [NOW + 20.0, NOW + 40.0] {
            let s = o.watch.scan(&live(&[]), present, info);
            o.apply(s, t, |_| None);
        }

        let rs = records(tmp.path());
        let by: Vec<(&str, &str)> = rs.iter().map(|r| (r.worktree.as_str(), r.by.as_str())).collect();
        assert_eq!(by, vec![("/r/c", "first_mate"), ("/r/a", "user"), ("/r/b", "agent")]);
        assert!(rs.iter().all(|r| r.kind == kind::WORKTREE_REMOVED && r.repo == "/r/repo"));
        assert_eq!(rs[0].fields["how"], "approved");
        assert_eq!(rs[0].fields["card"], "autopilot-1");
        assert_eq!(rs[0].branch, "b/c");
        assert_eq!(rs[1].fields["facts"], json!({"unpushed": 0, "pr": {"state": "merged"}}));
        assert_eq!(rs[2].fields["pane"], "seahelm-x");
    }

    #[test]
    fn creations_are_recorded_when_new_with_the_prompt() {
        let tmp = tempfile::tempdir().unwrap();
        let mut o = observer(tmp.path());
        let present = |p: &str| p.starts_with("/r/");
        let s = o.watch.scan(&live(&["/r/old"]), present, info);
        o.apply(s, NOW, |_| Some(NOW - DAY));

        o.handle(
            Msg::Performed {
                method: "worktree.create".into(),
                params: json!({"repo_path": "/r/repo", "prompt": "fix the login 500"}),
                result: json!({"worktree_path": "/r/fm", "branch": "task/fix"}),
                by: By::FirstMate,
                how: Some("auto".into()),
                card: None,
                pane: None,
            },
            NOW,
        );
        o.handle(Msg::AgentCommand { verb: Verb::Create, path: "/r/agent".into(), pane: "seahelm-y".into() }, NOW);
        let s = o.watch.scan(&live(&["/r/old", "/r/fm", "/r/agent", "/r/mine", "/r/added-project"]), present, info);
        o.apply(s, NOW + 20.0, |p| Some(if p == "/r/added-project" { NOW - 30.0 * DAY } else { NOW }));

        let rs = records(tmp.path());
        let got: Vec<(&str, &str)> = rs.iter().map(|r| (r.worktree.as_str(), r.by.as_str())).collect();
        assert_eq!(got, vec![("/r/agent", "agent"), ("/r/fm", "first_mate"), ("/r/mine", "user")]);
        assert!(rs.iter().all(|r| r.kind == kind::WORKTREE_CREATED));
        assert_eq!(rs[1].fields["prompt"], "fix the login 500");
        assert_eq!(rs[1].fields["how"], "auto");
        assert_eq!(rs[1].branch, "b/fm");
    }

    #[test]
    fn card_answers_are_recorded() {
        let tmp = tempfile::tempdir().unwrap();
        let mut o = observer(tmp.path());
        o.handle(
            Msg::CardAnswered {
                card_kind: "approval",
                card: "autopilot-1".into(),
                option: Some("Approve".into()),
                via: Some("telegram".into()),
                summary: "Delete worktree x".into(),
                action: Some("delete_worktree".into()),
                worktree: "/r/x".into(),
                repo: String::new(),
                habit: Some("_global/delete-merged-clean".into()),
            },
            NOW,
        );
        o.handle(
            Msg::CardAnswered { card_kind: "proposal", card: "proposal-2".into(), option: None, via: None, summary: "s".into(), action: None, worktree: String::new(), repo: String::new(), habit: None },
            NOW,
        );
        let rs = records(tmp.path());
        assert_eq!(rs.len(), 2);
        assert_eq!((rs[0].kind.as_str(), rs[0].by.as_str(), rs[0].worktree.as_str()), (kind::CARD_ANSWERED, "user", "/r/x"));
        assert_eq!(rs[0].fields["option"], "Approve");
        assert_eq!(rs[0].fields["via"], "telegram");
        assert_eq!(rs[0].fields["action"], "delete_worktree");
        assert_eq!(rs[0].fields["habit"], "_global/delete-merged-clean");
        assert!(!rs[1].fields.contains_key("habit"));
        assert_eq!(rs[1].fields["option"], Value::Null);
    }

    #[test]
    fn expiries_are_recorded_with_their_habits() {
        let tmp = tempfile::tempdir().unwrap();
        let mut o = observer(tmp.path());
        o.handle(
            Msg::CardExpired {
                card_kind: "habit.sweep",
                card: "habit.sweep:s1".into(),
                summary: "First Mate: these 2 worktrees look done:".into(),
                worktree: String::new(),
                repo: String::new(),
                habit: Some("_global/delete-merged-clean".into()),
            },
            NOW,
        );
        let rs = records(tmp.path());
        assert_eq!((rs[0].kind.as_str(), rs[0].by.as_str()), (kind::CARD_EXPIRED, "user"));
        assert_eq!(rs[0].fields["card_kind"], "habit.sweep");
        assert_eq!(rs[0].fields["habit"], "_global/delete-merged-clean");
        assert!(!rs[0].fields.contains_key("option"), "nothing was answered");
    }

    #[test]
    fn the_directory_is_made_at_start_so_a_new_user_is_recorded() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join(".config/seahelm/first-mate");
        let answer = || Msg::CardAnswered { card_kind: "approval", card: "c".into(), option: None, via: None, summary: String::new(), action: None, worktree: String::new(), repo: String::new(), habit: None };

        // Without the directory (creating it failed) nothing is written.
        let mut o = observer(&dir);
        o.handle(answer(), NOW);
        assert!(!dir.exists());

        // What `spawn` does first: only the directory, nothing of First Mate's in it.
        assert!(ensure_dir(&dir));
        assert!(ensure_dir(&dir), "and again on the next start");
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
        o.handle(answer(), NOW);
        assert_eq!(records(&dir).len(), 1);
        let names: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        assert_eq!(names, vec![FILE_NAME.to_string()]);
    }

    #[test]
    fn facts_are_logged_as_serde_writes_them() {
        let f = super::facts::Facts { changed: 2, untracked: 3, unpushed: Some(0), pr: Some("merged".into()), ..Default::default() };
        let v = serde_json::to_value(&f).unwrap();
        let mut w = Watch::default();
        w.scan(&live(&["/r/wt"]), |_| true, info);
        w.measured("/r/wt", v.clone(), NOW);
        let (path, k) = w.take("/r/wt").unwrap();
        let r = removed_record(&path, &k, By::User, Map::new());
        assert_eq!(r.fields["facts"], v);
        assert_eq!(r.fields["facts"]["pr"], "merged");
        assert_eq!(r.fields["facts"]["untracked"], 3);
    }
}
