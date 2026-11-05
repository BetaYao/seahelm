//! What wakes First Mate and what it is told (`AutopilotEvents.swift`): PR
//! snapshots into events, events matched to rules, the prompt, the ledger of
//! what already fired, and the audit log. The ledger and the log are the
//! app's files in the app's shape, so moving First Mate to the core keeps
//! its memory.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use super::clock::Local;
use super::facts::Facts;
use super::rules::{Action, Config, Rule, Trigger};
use crate::pr::{Checks, PrStatus, State};

/// Something that may wake First Mate.
#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    pub trigger: Trigger,
    pub repo: String,
    pub worktree: String,
    pub branch: String,
    pub pr: Option<PrStatus>,
    /// The worktree as measured when the event fired.
    pub facts: Option<Facts>,
}

/// A worktree's branch and PR, as one look at the fleet found them.
#[derive(Clone, Debug, PartialEq)]
pub struct Observation {
    pub worktree: String,
    pub repo: String,
    pub branch: String,
    pub pr: Option<PrStatus>,
}

/// Successive PR snapshots into `ci.failed` / `pr.merged`.
///
/// `ci.failed` fires on an observed edge only: a PR already red when first
/// seen is somebody's known state, not news. `pr.merged` fires the first
/// time a merge is seen, even at launch, once per PR ever (the ledger).
#[derive(Default)]
pub struct Detector {
    last: HashMap<String, PrStatus>,
}

impl Detector {
    pub fn observe(&mut self, obs: &[Observation], already_merged: impl Fn(&str) -> bool) -> Vec<Event> {
        let mut events = Vec::new();
        let mut next = HashMap::new();
        for o in obs {
            let Some(pr) = &o.pr else { continue };
            next.insert(o.worktree.clone(), pr.clone());
            let event = |trigger| Event {
                trigger,
                repo: o.repo.clone(),
                worktree: o.worktree.clone(),
                branch: o.branch.clone(),
                pr: Some(pr.clone()),
                facts: None,
            };
            if pr.state == State::Merged {
                if !already_merged(&merged_key(&o.repo, pr.number)) {
                    events.push(event(Trigger::PrMerged));
                }
                continue;
            }
            if pr.is_live() && pr.checks == Some(Checks::Failing) {
                if let Some(old) = self.last.get(&o.worktree) {
                    if old.number != pr.number || old.checks != Some(Checks::Failing) {
                        events.push(event(Trigger::CiFailed));
                    }
                }
            }
        }
        self.last = next;
        events
    }
}

pub fn merged_key(repo: &str, pr: u64) -> String {
    format!("{repo}#{pr}")
}

/// Merges already handled, and attempts per rule, PR and day. `state.json`
/// beside First Mate's files, as the app wrote it.
pub struct Ledger {
    path: PathBuf,
    state: Mutex<LedgerState>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
struct LedgerState {
    #[serde(default)]
    merged: BTreeSet<String>,
    /// day → "rule|repo#pr" → count. Only today is kept.
    #[serde(default)]
    attempts: BTreeMap<String, BTreeMap<String, u32>>,
}

impl Ledger {
    pub fn open(path: PathBuf) -> Self {
        let state = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Ledger { path, state: Mutex::new(state) }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, LedgerState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn merge_handled(&self, key: &str) -> bool {
        self.lock().merged.contains(key)
    }

    pub fn mark_merge_handled(&self, key: &str) {
        self.lock().merged.insert(key.to_string());
        self.save();
    }

    pub fn attempts(&self, rule: &str, repo: &str, pr: u64, day: &str) -> u32 {
        self.lock().attempts.get(day).and_then(|d| d.get(&format!("{rule}|{repo}#{pr}"))).copied().unwrap_or(0)
    }

    pub fn record_attempt(&self, rule: &str, repo: &str, pr: u64, day: &str) {
        {
            let mut st = self.lock();
            st.attempts.retain(|d, _| d == day);
            *st.attempts.entry(day.to_string()).or_default().entry(format!("{rule}|{repo}#{pr}")).or_default() += 1;
        }
        self.save();
    }

    fn save(&self) {
        let snapshot = self.lock().clone();
        if let Ok(bytes) = serde_json::to_vec(&snapshot) {
            if let Some(dir) = self.path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let tmp = self.path.with_extension("json.tmp");
            if std::fs::write(&tmp, bytes).is_ok() {
                let _ = std::fs::rename(&tmp, &self.path);
            }
        }
    }
}

/// What First Mate is handed for one matched rule.
#[derive(Clone, Debug, PartialEq)]
pub struct Dispatch {
    pub rule: Rule,
    pub event: Event,
    pub prompt: String,
}

/// The rules an event matches, with their prompts. Pure but for the ledger.
pub fn dispatches(event: &Event, config: &Config, ledger: &Ledger, day: &str) -> Vec<Dispatch> {
    let mut out = Vec::new();
    for rule in config.rules_for(&event.trigger) {
        if rule.branch.as_ref().is_some_and(|f| !f.matches(&event.branch)) {
            continue;
        }
        if let (Some(max), Some(pr)) = (rule.max_attempts, &event.pr) {
            if ledger.attempts(&rule.name, &event.repo, pr.number, day) >= max {
                continue;
            }
        }
        out.push(Dispatch { rule: rule.clone(), event: event.clone(), prompt: prompt(rule, event, config) });
    }
    out
}

/// `{{name}}` → value. Unknown names are left as written, so a typo shows.
pub fn render(template: &str, event: &Event, rule: &Rule) -> String {
    let pr = event.pr.as_ref();
    [
        ("repo", event.repo.clone()),
        ("worktree", event.worktree.clone()),
        ("branch", event.branch.clone()),
        ("pr", pr.map(|p| p.number.to_string()).unwrap_or_default()),
        ("pr_url", pr.map(|p| p.url.clone()).unwrap_or_default()),
        ("rule", rule.name.clone()),
    ]
    .iter()
    .fold(template.to_string(), |t, (k, v)| t.replace(&format!("{{{{{k}}}}}"), v))
}

/// A header First Mate can parse at a glance, then the rule's own words.
pub fn prompt(rule: &Rule, event: &Event, config: &Config) -> String {
    let mut lines = vec![
        format!("[seahelm event] {} · rule {}", event.trigger.event_name(), rule.name),
        format!("repo: {}", event.repo),
        format!("worktree: {} (branch {})", event.worktree, event.branch),
    ];
    if let Some(pr) = &event.pr {
        lines.push(format!("PR: #{} {} — {}", pr.number, pr.url, pr.summary()));
    }
    if let Some(f) = &event.facts {
        lines.push(format!("facts (measured by seahelm; trust these over your own summary): {}", f.summary()));
    }
    let autonomy: Vec<String> =
        Action::ALL.iter().map(|a| format!("{}={}", a.as_str(), config.autonomy(*a, Some(rule)).as_str())).collect();
    lines.push(format!("autonomy: {}", autonomy.join(", ")));
    lines.push(String::new());
    lines.push(render(&rule.brief, event, rule).trim().to_string());
    lines.join("\n")
}

/// One line per event, delivery and action: `audit.jsonl`, in the app's
/// shape (camelCase keys, ISO 8601 times).
pub struct Audit {
    path: PathBuf,
    lock: Mutex<()>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub at: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub worktree_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pr: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub level: Option<String>,
    /// The pane an action spoke to, as the user knows it (`#7 · feat-x`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
    /// What an action said or started, one line: the brief describes the
    /// action itself, in the user's language, from these fields.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    pub text: String,
}

impl Entry {
    pub fn new(now: f64, kind: &str, text: impl Into<String>) -> Self {
        Entry { at: iso8601(now), kind: kind.into(), text: text.into(), ..Entry::default() }
    }

    /// What the dock reports as the last thing that happened.
    pub fn is_notable(&self) -> bool {
        matches!(self.kind.as_str(), "event" | "action" | "approval" | "denied")
    }

    pub fn headline(&self) -> String {
        match self.kind.as_str() {
            "message" => format!("you: {}", self.text),
            "action" => format!("→ {}", self.text),
            "approval" => format!("? {}", self.text),
            "denied" => format!("✕ {}", self.text),
            _ => self.text.clone(),
        }
    }
}

impl Audit {
    pub fn open(path: PathBuf) -> Self {
        Audit { path, lock: Mutex::new(()) }
    }

    pub fn append(&self, entry: &Entry) {
        let Ok(mut line) = serde_json::to_vec(entry) else { return };
        line.push(b'\n');
        let _g = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&self.path) {
            let _ = f.write_all(&line);
        }
    }

    /// The newest `limit` entries, oldest first.
    pub fn recent(&self, limit: usize) -> Vec<Entry> {
        let _g = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let text = std::fs::read_to_string(&self.path).unwrap_or_default();
        let lines: Vec<&str> = text.lines().collect();
        lines[lines.len().saturating_sub(limit)..].iter().filter_map(|l| serde_json::from_str(l).ok()).collect()
    }
}

/// `2026-11-03T09:30:00Z`, as Foundation's `.iso8601` strategy writes it.
pub fn iso8601(unix: f64) -> String {
    let t = Local::with_offset(unix, 0);
    let secs = (unix.floor() as i64).rem_euclid(60);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", t.year, t.month, t.day, t.hour, t.minute, secs)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pr(number: u64, state: State, checks: Option<Checks>) -> PrStatus {
        PrStatus { number, url: format!("https://github.com/o/r/pull/{number}"), state, checks, review: None, head_oid: None, merged_at: None }
    }

    fn obs(wt: &str, p: Option<PrStatus>) -> Observation {
        Observation { worktree: wt.into(), repo: "/r".into(), branch: "task/x".into(), pr: p }
    }

    #[test]
    fn ci_failed_fires_on_the_edge_only() {
        let mut d = Detector::default();
        let none = |_: &str| false;
        assert!(d.observe(&[obs("/w", Some(pr(1, State::Open, Some(Checks::Failing))))], none).is_empty());
        assert!(d.observe(&[obs("/w", Some(pr(1, State::Open, Some(Checks::Failing))))], none).is_empty());
        d.observe(&[obs("/w", Some(pr(1, State::Open, Some(Checks::Pending))))], none);
        let e = d.observe(&[obs("/w", Some(pr(1, State::Open, Some(Checks::Failing))))], none);
        assert_eq!(e.len(), 1);
        assert_eq!(e[0].trigger, Trigger::CiFailed);
    }

    #[test]
    fn a_merge_fires_once_per_pr_even_at_launch() {
        let mut d = Detector::default();
        let e = d.observe(&[obs("/w", Some(pr(7, State::Merged, None)))], |_| false);
        assert_eq!(e[0].trigger, Trigger::PrMerged);
        assert!(d.observe(&[obs("/w", Some(pr(7, State::Merged, None)))], |k| k == "/r#7").is_empty());
    }

    #[test]
    fn ledger_counts_attempts_per_day_and_keeps_only_today() {
        let dir = tempfile::tempdir().unwrap();
        let l = Ledger::open(dir.path().join("state.json"));
        l.record_attempt("fix-ci", "/r", 3, "2026-11-03");
        l.record_attempt("fix-ci", "/r", 3, "2026-11-03");
        assert_eq!(l.attempts("fix-ci", "/r", 3, "2026-11-03"), 2);
        l.record_attempt("fix-ci", "/r", 3, "2026-11-04");
        assert_eq!(l.attempts("fix-ci", "/r", 3, "2026-11-03"), 0);
        l.mark_merge_handled("/r#3");
        let again = Ledger::open(dir.path().join("state.json"));
        assert!(again.merge_handled("/r#3"));
        assert_eq!(again.attempts("fix-ci", "/r", 3, "2026-11-04"), 1);
    }

    #[test]
    fn reads_the_apps_ledger() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        std::fs::write(&path, r#"{"merged":["/r#9"],"attempts":{"2026-11-03":{"fix-ci|/r#9":1}}}"#).unwrap();
        let l = Ledger::open(path);
        assert!(l.merge_handled("/r#9"));
        assert_eq!(l.attempts("fix-ci", "/r", 9, "2026-11-03"), 1);
    }

    #[test]
    fn dispatch_respects_branch_and_max_attempts() {
        let dir = tempfile::tempdir().unwrap();
        let ledger = Ledger::open(dir.path().join("state.json"));
        let config = Config::built_in();
        let mut event = Event {
            trigger: Trigger::CiFailed,
            repo: "/r".into(),
            worktree: "/w".into(),
            branch: "task/x".into(),
            pr: Some(pr(5, State::Open, Some(Checks::Failing))),
            facts: None,
        };
        let d = dispatches(&event, &config, &ledger, "2026-11-03");
        assert_eq!(d.len(), 1);
        assert!(d[0].prompt.starts_with("[seahelm event] ci.failed · rule fix-ci\nrepo: /r\n"));
        assert!(d[0].prompt.contains("autonomy: message_pane=auto, start_agent=ask, delete_worktree=ask"));
        assert!(d[0].prompt.ends_with("ask it to fix and push; if it is busy, wait for it; if there is none, start one."));
        assert!(d[0].prompt.contains("PR #5 on task/x failed CI"));
        ledger.record_attempt("fix-ci", "/r", 5, "2026-11-03");
        ledger.record_attempt("fix-ci", "/r", 5, "2026-11-03");
        assert!(dispatches(&event, &config, &ledger, "2026-11-03").is_empty());
        event.branch = "main".into();
        assert!(dispatches(&event, &config, &ledger, "2026-11-04").is_empty());
    }

    #[test]
    fn audit_lines_are_the_apps() {
        let dir = tempfile::tempdir().unwrap();
        let a = Audit::open(dir.path().join("audit.jsonl"));
        let mut e = Entry::new(1_793_698_200.0, "event", "ci.failed · x");
        e.worktree_path = Some("/w".into());
        a.append(&e);
        let text = std::fs::read_to_string(dir.path().join("audit.jsonl")).unwrap();
        assert_eq!(text, "{\"at\":\"2026-11-03T09:30:00Z\",\"kind\":\"event\",\"worktreePath\":\"/w\",\"text\":\"ci.failed · x\"}\n");
        assert_eq!(a.recent(10), vec![e]);
    }
}
