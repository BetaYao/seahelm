//! The daily sweep (docs/first-mate-autonomy.md, "Scenario 1" › "Sweep"):
//! once a day, and when First Mate is turned on, measure every live
//! worktree and match the habits. `auto` matches are deleted and reported
//! in one line; `ask` matches go on one batched card; `suggest` matches are
//! listed in one line, no card; `observe` and `keep` do nothing.
//!
//! Pure where it can be: the facts (`measure`) and the deletion (`Deleter`)
//! are the caller's, so the routing is tested with neither git nor a real
//! worktree. Only while First Mate runs, not paused, and outside quiet
//! hours; the main and integration checkouts are never candidates.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::facts::Facts;
use super::habits::{self, Book, Decision, HabitLevel, Precedence};
use super::lang::Text;
use super::observations::{self, norm, Record};

/// A live linked worktree, before it is measured.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub path: String,
    pub repo: String,
    pub branch: String,
}

/// A worktree with its facts.
#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    pub path: String,
    pub repo: String,
    pub branch: String,
    pub facts: Facts,
}

impl Candidate {
    pub fn name(&self) -> String {
        Path::new(&self.path).file_name().and_then(|n| n.to_str()).unwrap_or(&self.path).to_string()
    }
}

/// Which worktrees are candidates at all. `info`: a linked worktree's repo
/// and branch, None for a main checkout or anything not a checkout.
/// `integration`: every repo's integration checkout. `skip`: worktrees
/// already on a card or First Mate's own directory.
pub fn targets(
    live: &HashSet<String>,
    mut info: impl FnMut(&str) -> Option<(String, String)>,
    integration: &HashSet<String>,
    skip: &HashSet<String>,
) -> Vec<Target> {
    let mut paths: Vec<&String> = live.iter().collect();
    paths.sort();
    let mut out = Vec::new();
    for p in paths {
        let n = norm(p);
        if skip.contains(p) || skip.contains(&n) || integration.contains(&n) {
            continue;
        }
        let Some((repo, branch)) = info(p) else { continue };
        if norm(&repo) == n || branch.is_empty() || branch == "HEAD" {
            continue;
        }
        out.push(Target { path: p.clone(), repo, branch });
    }
    out
}

/// What the sweep decided for one worktree.
#[derive(Clone, Debug, PartialEq)]
pub struct Routed {
    pub candidate: Candidate,
    pub decision: Decision,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Plan {
    pub auto: Vec<Routed>,
    pub ask: Vec<Routed>,
    pub suggest: Vec<Routed>,
}

/// Route every candidate. `books`: a repo's book by repo path (missing:
/// none); `global`: the global book; `prec`: a repo's precedence.
pub fn plan(candidates: Vec<Candidate>, books: &HashMap<String, Book>, global: &Book, prec: impl Fn(&str) -> Precedence) -> Plan {
    let mut p = Plan::default();
    for c in candidates {
        let mut list: Vec<&Book> = Vec::new();
        if let Some(b) = books.get(&c.repo) {
            list.push(b);
        }
        list.push(global);
        let Some(d) = habits::decide(&c.facts, &list, &prec(&c.repo)) else { continue };
        let r = Routed { candidate: c, decision: d };
        match r.decision.level {
            HabitLevel::Auto => p.auto.push(r),
            HabitLevel::Ask => p.ask.push(r),
            HabitLevel::Suggest => p.suggest.push(r),
            HabitLevel::Observe => {}
        }
    }
    p
}

/// Deletes one worktree for a habit. The real one re-measures, matches
/// again and goes through the core's own `worktree.delete`, attributed to
/// First Mate with `how`.
pub trait Deleter {
    fn delete(&self, r: &Routed, how: &str) -> Result<(), String>;
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Report {
    pub deleted: Vec<Routed>,
    /// Matched `auto` but not deleted, and why.
    pub failed: Vec<(Routed, String)>,
    pub ask: Vec<Routed>,
    pub suggest: Vec<Routed>,
    /// Repos skipped (quiet hours, rules that do not parse).
    pub skipped_repos: Vec<(String, String)>,
}

/// Act on a plan: delete the `auto` matches — each checked once more
/// against the safety rule on the facts at hand — and hand the rest back.
pub fn run(p: Plan, deleter: &dyn Deleter) -> Report {
    let mut r = Report { ask: p.ask, suggest: p.suggest, ..Report::default() };
    for item in p.auto {
        if !habits::nothing_to_lose(&item.candidate.facts) {
            r.failed.push((item, "something to lose after all; left alone".into()));
            continue;
        }
        let how = format!("habit:{}", item.decision.id);
        match deleter.delete(&item, &how) {
            Ok(()) => r.deleted.push(item),
            Err(e) => r.failed.push((item, e)),
        }
    }
    r
}

/// One line for First Mate's conversation (a `note` row: no model turn).
pub fn line_deleted(items: &[Routed]) -> Option<Text> {
    (!items.is_empty()).then(|| {
        let names: Vec<String> = items.iter().map(|r| format!("{} ({})", r.candidate.name(), r.decision.id)).collect();
        Text::new(
            format!("Deleted {} by habit: {}. Branches kept.", plural(items.len(), "worktree"), names.join(" · ")),
            format!("按习惯删了 {} 个 worktree：{}。分支保留。", items.len(), names.join(" · ")),
        )
    })
}

pub fn line_suggest(items: &[Routed]) -> Option<Text> {
    (!items.is_empty()).then(|| {
        let names: Vec<String> = items.iter().map(|r| r.candidate.name()).collect();
        Text::new(format!("These look done: {}.", names.join(" · ")), format!("这些看起来做完了：{}。", names.join(" · ")))
    })
}

fn plural(n: usize, one: &str) -> String {
    format!("{n} {one}{}", if n == 1 { "" } else { "s" })
}

// MARK: the batched card

pub const DELETE: &str = "Delete";
pub const KEEP: &str = "Keep";
pub const LET_ME_PICK: &str = "Let me pick";
pub const NOT_NOW: &str = "Not now";
pub const SWEEP_PREFIX: &str = "habit.sweep:";
pub const ITEM_PREFIX: &str = "habit.item:";

pub fn delete_all(n: usize) -> String {
    format!("Delete all {n}")
}

/// One sweep's `ask` matches, on one card.
#[derive(Clone, Debug, PartialEq)]
pub struct Batch {
    pub payload: String,
    pub items: Vec<Routed>,
    /// Items still to decide (by index) after "Let me pick".
    pub open: Vec<usize>,
    /// Habits already taken down for this batch: one rejection per batch.
    pub demoted: HashSet<(String, String)>,
}

impl Batch {
    pub fn new(nonce: &str, items: Vec<Routed>) -> Batch {
        let open = (0..items.len()).collect();
        Batch { payload: format!("{SWEEP_PREFIX}{nonce}"), items, open, demoted: HashSet::new() }
    }

    /// The card: every worktree with its facts. One worktree is asked
    /// about directly; several get "delete all" or "let me pick".
    pub fn card(&self) -> (String, Vec<String>) {
        self.card_in(super::lang::Lang::En)
    }

    /// The card in the user's language. The option labels stay as they are:
    /// answers are matched on them.
    pub fn card_in(&self, lang: super::lang::Lang) -> (String, Vec<String>) {
        use super::lang::Lang;
        let mut m = match (lang, self.items.len()) {
            (Lang::En, 1) => "First Mate: this worktree looks done:".to_string(),
            (Lang::En, n) => format!("First Mate: these {n} worktrees look done:"),
            (Lang::Zh, 1) => "First Mate：这个 worktree 看起来已经做完了：".to_string(),
            (Lang::Zh, n) => format!("First Mate：这 {n} 个 worktree 看起来已经做完了："),
        };
        for r in &self.items {
            m += &format!("\n• {} — {} [{}]", r.candidate.name(), r.candidate.facts.summary(), r.decision.id);
        }
        let options = if self.items.len() == 1 {
            vec![DELETE.into(), KEEP.into(), NOT_NOW.into()]
        } else {
            vec![delete_all(self.items.len()), LET_ME_PICK.into(), NOT_NOW.into()]
        };
        (m, options)
    }

    pub fn item_payload(&self, i: usize) -> String {
        format!("{ITEM_PREFIX}{}:{i}", self.payload.trim_start_matches(SWEEP_PREFIX))
    }

    pub fn item_card(&self, i: usize) -> (String, Vec<String>) {
        self.item_card_in(i, super::lang::Lang::En)
    }

    pub fn item_card_in(&self, i: usize, lang: super::lang::Lang) -> (String, Vec<String>) {
        let r = &self.items[i];
        let head = lang.pick("First Mate: delete worktree", "First Mate：删除 worktree");
        let q = lang.pick("?", "？");
        (format!("{head} {}{q} — {} [{}]", r.candidate.name(), r.candidate.facts.summary(), r.decision.id), vec![DELETE.into(), KEEP.into()])
    }
}

/// What an answer to a batch or item card asks for.
#[derive(Debug, PartialEq)]
pub enum BatchAnswer {
    /// Delete these items (one approval per habit).
    Delete(Vec<usize>),
    /// Leave this item: a rejection of its habit.
    Keep(usize),
    /// Raise one card per item.
    Pick,
    Nothing,
}

pub fn answer_batch(b: &Batch, option: Option<&str>) -> BatchAnswer {
    match option {
        Some(o) if b.items.len() == 1 && o == DELETE => BatchAnswer::Delete(vec![0]),
        Some(o) if b.items.len() == 1 && o == KEEP => BatchAnswer::Keep(0),
        Some(o) if o == delete_all(b.items.len()) => BatchAnswer::Delete(b.open.clone()),
        Some(LET_ME_PICK) => BatchAnswer::Pick,
        _ => BatchAnswer::Nothing,
    }
}

// MARK: when it runs, and undo

/// An automatic deletion, watched for the user undoing it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Deleted {
    pub key: String,
    pub id: String,
    pub repo: String,
    pub branch: String,
    pub worktree: String,
    pub at: f64,
}

/// `habits/.sweep.json`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct State {
    /// The local day each repo was last swept.
    #[serde(default)]
    pub swept: BTreeMap<String, String>,
    /// When the last sweep ran (unix seconds).
    #[serde(default)]
    pub last_at: f64,
    #[serde(default)]
    pub deleted: Vec<Deleted>,
    /// When the inventory last measured the worktrees (`inventory`); None:
    /// never, so turning First Mate on takes one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inventory_at: Option<f64>,
}

/// Turning First Mate on sweeps at once, unless one ran this recently (a
/// core restart is not the user turning it on).
pub const ON_START_GAP: f64 = 6.0 * 3600.0;

impl State {
    pub fn load(path: &Path) -> State {
        std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
    }

    pub fn save(&self, path: &Path) {
        if let Some(d) = path.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let tmp = path.with_extension("tmp");
        if std::fs::write(&tmp, serde_json::to_string_pretty(self).unwrap_or_default()).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }

    pub fn path(habits_dir: &Path) -> PathBuf {
        habits_dir.join(".sweep.json")
    }

    /// Whether a repo is due today.
    pub fn due(&self, repo: &str, day: &str) -> bool {
        self.swept.get(repo).map(String::as_str) != Some(day)
    }

    /// Whether turning First Mate on should take the inventory: only if
    /// none was ever taken (the user can redo it, `habits.inventory`).
    pub fn inventory_due(&self) -> bool {
        self.inventory_at.is_none()
    }

    /// Whether turning on now should sweep everything again.
    pub fn sweep_on_start(&self, now: f64) -> bool {
        now - self.last_at >= ON_START_GAP
    }

    /// Automatic deletions the user undid: the branch came back as a
    /// worktree in the same repo within the window. Watches past the window
    /// are dropped; undone ones are taken out and returned.
    pub fn undone(&mut self, records: &[Record], now: f64) -> Vec<Deleted> {
        let window = habits::tuning::UNDO_WINDOW_DAYS * 86_400.0;
        let mut out = Vec::new();
        self.deleted.retain(|d| {
            let since = super::engine::iso8601(d.at);
            let until = super::engine::iso8601(d.at + window);
            let back = records.iter().any(|r| {
                r.kind == observations::kind::WORKTREE_CREATED
                    && r.branch == d.branch
                    && norm(&r.repo) == norm(&d.repo)
                    && r.at.as_str() > since.as_str()
                    && r.at.as_str() <= until.as_str()
            });
            if back {
                out.push(d.clone());
                return false;
            }
            now - d.at <= window
        });
        out
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::first_mate::habits::{Store, GLOBAL, SEED_ID};
    use crate::first_mate::observations::By;
    use crate::first_mate::rules::Level as RuleLevel;
    use std::cell::RefCell;

    const NOW: f64 = 1_793_000_000.0;
    const TODAY: &str = "2026-10-26";

    fn clean_merged() -> Facts {
        Facts { pr: Some("merged".into()), pr_number: Some(7), unpushed: Some(0), idle_days: Some(3), days_since_merge: Some(3), ..Facts::default() }
    }

    fn cand(name: &str, facts: Facts) -> Candidate {
        Candidate { path: format!("/r/wt/{name}"), repo: "/r/repo".into(), branch: format!("feat/{name}"), facts }
    }

    /// Records what it was asked to delete; never touches a disk.
    #[derive(Default)]
    struct FakeDeleter {
        calls: RefCell<Vec<(String, String)>>,
        fail: Option<String>,
    }

    impl Deleter for FakeDeleter {
        fn delete(&self, r: &Routed, how: &str) -> Result<(), String> {
            self.calls.borrow_mut().push((r.candidate.path.clone(), how.into()));
            match &self.fail {
                Some(e) if r.candidate.path.ends_with(e.as_str()) => Err("git worktree remove: busy".into()),
                _ => Ok(()),
            }
        }
    }

    /// A repo book with an approved `auto` habit, a `suggest` one and a
    /// `keep` one, laid over the seed at `ask`.
    fn books() -> (HashMap<String, Book>, Book) {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store::new(tmp.path().to_path_buf());
        let key = habits::repo_key("/r/repo");
        let text = r#"
- id: merged-long-ago
  when: { pr: merged, days_since_merge: ">=14", uncommitted: 0, untracked: 0, ignored: 0, unpushed: 0, busy_panes: 0 }
  do: delete_worktree
  level: auto
  approved: 2026-10-01
- id: closed-idle
  when: { pr: closed, idle_days: ">=30" }
  do: delete_worktree
  level: suggest
- id: keep-spikes
  when: { pr: none, idle_days: ">=0" }
  do: keep
  level: observe
- id: open-prs
  when: { pr: open }
  do: delete_worktree
  level: observe
"#;
        std::fs::write(store.path(&key), text).unwrap();
        let mut granted = serde_json::Map::new();
        granted.insert(key.clone(), serde_json::json!({"merged-long-ago": "auto", "closed-idle": "suggest", "keep-spikes": "observe", "open-prs": "observe"}));
        std::fs::write(tmp.path().join(".granted.json"), serde_json::Value::Object(granted).to_string()).unwrap();
        let repo = store.load(&key, TODAY);
        assert!(repo.notes.is_empty(), "{:?}", repo.notes);
        (HashMap::from([("/r/repo".to_string(), repo)]), Book::seeded(TODAY))
    }

    fn prec(_: &str) -> Precedence {
        Precedence { repo_cap: None, user_default: RuleLevel::Ask }
    }

    #[test]
    fn routes_by_level() {
        let (repo, global) = books();
        let cands = vec![
            cand("old", Facts { days_since_merge: Some(20), ..clean_merged() }),
            cand("recent", clean_merged()),
            cand("closed", Facts { pr: Some("closed".into()), idle_days: Some(45), untracked: 3, ..clean_merged() }),
            cand("spike", Facts { pr: Some("none".into()), ..clean_merged() }),
            cand("open", Facts { pr: Some("open".into()), ..clean_merged() }),
            cand("dirty", Facts { changed: 1, ..clean_merged() }),
            cand("unknown", Facts { unpushed: None, ..clean_merged() }),
        ];
        let p = plan(cands, &repo, &global, prec);
        let names = |v: &[Routed]| v.iter().map(|r| r.candidate.name()).collect::<Vec<_>>();
        assert_eq!(names(&p.auto), vec!["old"]);
        assert_eq!(p.auto[0].decision.id, "merged-long-ago");
        assert_eq!(names(&p.ask), vec!["recent"]);
        assert_eq!((p.ask[0].decision.key.as_str(), p.ask[0].decision.id.as_str()), (GLOBAL, SEED_ID));
        assert_eq!(names(&p.suggest), vec!["closed"], "suggest may list a worktree with untracked files; it deletes nothing");
        // spike: kept; open: observe; dirty/unknown: no habit matches.

        let d = FakeDeleter::default();
        let r = run(p, &d);
        assert_eq!(d.calls.borrow().clone(), vec![("/r/wt/old".to_string(), "habit:merged-long-ago".to_string())]);
        assert_eq!(names(&r.deleted), vec!["old"]);
        assert_eq!(line_deleted(&r.deleted).unwrap().en, "Deleted 1 worktree by habit: old (merged-long-ago). Branches kept.");
        assert_eq!(line_deleted(&r.deleted).unwrap().zh, "按习惯删了 1 个 worktree：old (merged-long-ago)。分支保留。");
        assert_eq!(line_suggest(&r.suggest).unwrap().en, "These look done: closed.");
    }

    #[test]
    fn caps_hold_auto_back() {
        let (repo, global) = books();
        let old = cand("old", Facts { days_since_merge: Some(20), ..clean_merged() });
        let ask = plan(vec![old.clone()], &repo, &global, |_| Precedence { repo_cap: Some(RuleLevel::Ask), user_default: RuleLevel::Auto });
        assert_eq!((ask.auto.len(), ask.ask.len()), (0, 1), "the repo's file caps at ask");
        let deny = plan(vec![old], &repo, &global, |_| Precedence { repo_cap: Some(RuleLevel::Deny), user_default: RuleLevel::Auto });
        assert_eq!(deny, Plan::default(), "deny there wins");
    }

    #[test]
    fn auto_never_deletes_what_has_something_to_lose() {
        // A plan built by hand (or by a bug) with a dirty auto match: run refuses it.
        let (repo, global) = books();
        let mut p = plan(vec![cand("old", Facts { days_since_merge: Some(20), ..clean_merged() })], &repo, &global, prec);
        p.auto[0].candidate.facts.ignored = 1;
        let d = FakeDeleter::default();
        let r = run(p, &d);
        assert!(d.calls.borrow().is_empty());
        assert_eq!(r.failed.len(), 1);

        // A failed deletion is reported, the rest go on.
        let p = plan(
            vec![cand("a", Facts { days_since_merge: Some(20), ..clean_merged() }), cand("b", Facts { days_since_merge: Some(30), ..clean_merged() })],
            &repo,
            &global,
            prec,
        );
        let d = FakeDeleter { fail: Some("/a".into()), ..FakeDeleter::default() };
        let r = run(p, &d);
        assert_eq!(r.deleted.len(), 1);
        assert_eq!(r.failed[0].1, "git worktree remove: busy");
    }

    #[test]
    fn main_integration_and_carded_worktrees_are_not_candidates() {
        let live: HashSet<String> = ["/nonexistent/repo", "/nonexistent/wt/a", "/nonexistent/wt/integration", "/nonexistent/wt/carded", "/nonexistent/wt/detached"].iter().map(|s| s.to_string()).collect();
        let info = |p: &str| -> Option<(String, String)> {
            match p {
                "/nonexistent/repo" => Some(("/nonexistent/repo".into(), "main".into())),
                "/nonexistent/wt/detached" => Some(("/nonexistent/repo".into(), "HEAD".into())),
                _ => Some(("/nonexistent/repo".into(), format!("b/{}", p.rsplit('/').next().unwrap()))),
            }
        };
        let integration: HashSet<String> = [norm("/nonexistent/wt/integration")].into();
        let skip: HashSet<String> = ["/nonexistent/wt/carded".to_string()].into();
        let t = targets(&live, info, &integration, &skip);
        assert_eq!(t, vec![Target { path: "/nonexistent/wt/a".into(), repo: "/nonexistent/repo".into(), branch: "b/a".into() }]);
    }

    fn routed(name: &str) -> Routed {
        Routed { candidate: cand(name, clean_merged()), decision: Decision { key: GLOBAL.into(), id: SEED_ID.into(), level: HabitLevel::Ask } }
    }

    #[test]
    fn one_card_per_sweep() {
        let b = Batch::new("n1", vec![routed("a"), routed("b"), routed("c")]);
        let (msg, options) = b.card();
        assert!(msg.starts_with("First Mate: these 3 worktrees look done:"));
        assert!(msg.contains("• a — nothing uncommitted") && msg.contains("PR #7 merged 3 days ago") && msg.contains("[delete-merged-clean]"), "{msg}");
        assert_eq!(options, vec!["Delete all 3", "Let me pick", "Not now"]);
        assert_eq!(answer_batch(&b, Some("Delete all 3")), BatchAnswer::Delete(vec![0, 1, 2]));
        assert_eq!(answer_batch(&b, Some(LET_ME_PICK)), BatchAnswer::Pick);
        assert_eq!(answer_batch(&b, Some(NOT_NOW)), BatchAnswer::Nothing);
        assert_eq!(answer_batch(&b, None), BatchAnswer::Nothing);
        assert_eq!(b.item_payload(2), "habit.item:n1:2");
        assert_eq!(b.item_card(1).1, vec![DELETE, KEEP]);

        let one = Batch::new("n2", vec![routed("a")]);
        assert_eq!(one.card().1, vec![DELETE, KEEP, NOT_NOW]);
        assert_eq!(answer_batch(&one, Some(KEEP)), BatchAnswer::Keep(0));
        assert_eq!(answer_batch(&one, Some(DELETE)), BatchAnswer::Delete(vec![0]));
    }

    #[test]
    fn checking_a_deleted_branch_out_again_undoes_it() {
        let mut s = State::default();
        let watch = |branch: &str| Deleted { key: GLOBAL.into(), id: SEED_ID.into(), repo: "/r/repo".into(), branch: branch.into(), worktree: format!("/r/wt/{branch}"), at: NOW };
        s.deleted = vec![watch("feat/a"), watch("feat/b"), watch("feat/c")];
        let created = |branch: &str, at: f64| {
            let mut r = Record::new(observations::kind::WORKTREE_CREATED, By::User);
            r.repo = "/r/repo".into();
            r.branch = branch.into();
            r.at = super::super::engine::iso8601(at);
            r
        };
        let recs = vec![created("feat/a", NOW + 3600.0), created("feat/b", NOW - 60.0), created("feat/c", NOW + 9.0 * 86_400.0)];
        let undone = s.undone(&recs, NOW + 2.0 * 86_400.0);
        assert_eq!(undone.iter().map(|d| d.branch.as_str()).collect::<Vec<_>>(), vec!["feat/a"]);
        assert_eq!(s.deleted.len(), 2, "still watching b and c");
        assert!(s.undone(&recs, NOW + 8.0 * 86_400.0).is_empty());
        assert!(s.deleted.is_empty(), "past the window: no longer watched");
    }

    #[test]
    fn once_a_day_per_repo_and_on_start_after_a_gap() {
        let mut s = State::default();
        assert!(s.due("/r/repo", TODAY) && s.sweep_on_start(NOW));
        s.swept.insert("/r/repo".into(), TODAY.into());
        s.last_at = NOW;
        assert!(!s.due("/r/repo", TODAY));
        assert!(s.due("/r/repo", "2026-10-27"));
        assert!(!s.sweep_on_start(NOW + 3600.0), "a restart an hour later is not a new sweep");
        assert!(s.sweep_on_start(NOW + ON_START_GAP));
        let tmp = tempfile::tempdir().unwrap();
        let path = State::path(tmp.path());
        s.save(&path);
        assert_eq!(State::load(&path), s);
    }
}
