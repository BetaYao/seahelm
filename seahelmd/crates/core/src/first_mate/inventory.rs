//! The inventory card (docs/first-mate-autonomy.md, "Scenario 1" step 3,
//! D6): the cold start of the learning loop. Worktrees pile up because the
//! user does not delete them, so First Mate never sees a deletion to learn
//! from. The first time First Mate is turned on (and again on demand,
//! `habits.inventory`), the core measures every live worktree and groups
//! the ones that look finished by facts signature:
//!
//! - **merged** — the PR merged, nothing to lose;
//! - **closed** — the PR closed unmerged, nothing to lose;
//! - **idle** — no PR, nothing done for 30+ days, nothing to lose;
//! - **at risk** — any of those, but with something to lose (uncommitted,
//!   untracked, ignored-but-worth-keeping files, unpushed commits — or
//!   unpushed commits git could not count).
//!
//! An open or draft PR, a busy pane, recent work without a PR, or a PR
//! nobody could look up leaves a worktree out. Each non-empty group is
//! one card, all raised together (raised cards carry one question each;
//! the follow-up chain in the card model is for an agent's own
//! multi-question dialog, whose keys the core presses). The answers:
//!
//! - *delete* — the group's worktrees are deleted now, each measured and
//!   matched against the group again first, and a deletion habit for the
//!   signature is written at `ask`, granted by the answer;
//! - *keep* — a `keep` habit for the signature: the group is never offered;
//! - *ask me each time* — a deletion habit at `observe`.
//!
//! The at-risk group offers no *delete*: nothing that would lose work is
//! deleted from a group answer. Each answer is one decision in the habit's
//! evidence, however many worktrees it covered. Habits go into the global
//! book: the answer is about a signature, not a repo.
//!
//! Pure where it can be: the facts, the deletion (`Deleter`) and the habit
//! files are the caller's.

use std::collections::{BTreeSet, HashMap};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use super::facts::Facts;
use super::habits::{self, Decision, Do, Evidence, Grant, Habit, HabitLevel, Origin, Status, When, GLOBAL};
use super::sweep::{self, Candidate, Deleter, Routed};

pub const PREFIX: &str = "habit.inventory:";
pub const KEEP: &str = "Keep";
pub const ASK_EACH_TIME: &str = "Ask me each time";
/// Idle this many days with no PR puts a clean worktree in the idle group.
pub const IDLE_DAYS: u32 = 30;
/// Worktrees named on one card; the rest are counted.
const LISTED: usize = 12;
/// How a deletion from the inventory is attributed (`how` in the log).
pub const HOW: &str = "inventory";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Group {
    Merged,
    Closed,
    Idle,
    AtRisk,
}

impl Group {
    pub const ALL: [Group; 4] = [Group::Merged, Group::Closed, Group::Idle, Group::AtRisk];

    pub fn key(self) -> &'static str {
        match self {
            Group::Merged => "merged",
            Group::Closed => "closed",
            Group::Idle => "idle",
            Group::AtRisk => "at-risk",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Group::Merged => "PR merged, nothing to lose",
            Group::Closed => "PR closed without merging, nothing to lose",
            Group::Idle => "no PR, idle 30+ days, nothing to lose",
            Group::AtRisk => "finished or idle, but has something to lose",
        }
    }

    /// Only a group with nothing to lose can be deleted from its card.
    pub fn can_delete(self) -> bool {
        self != Group::AtRisk
    }

    /// The signature's `when`, without the at-risk facts.
    fn scope(self) -> &'static str {
        match self {
            Group::Merged => "pr: merged",
            Group::Closed => "pr: closed",
            Group::Idle => "pr: none, idle_days: \">=30\"",
            Group::AtRisk => unreachable!("the at-risk group has a scope per member"),
        }
    }
}

/// Which group a worktree's facts put it in, if any.
pub fn classify(f: &Facts) -> Option<Group> {
    if f.busy_panes > 0 {
        return None;
    }
    let stale = match f.pr.as_deref() {
        Some("merged" | "closed") => true,
        Some("none") => f.idle_days.is_some_and(|d| d >= IDLE_DAYS),
        // open, draft, or nobody could look the PR up
        _ => false,
    };
    if !stale {
        return None;
    }
    if !habits::nothing_to_lose(f) {
        return Some(Group::AtRisk);
    }
    match f.pr.as_deref() {
        Some("merged") => Some(Group::Merged),
        Some("closed") => Some(Group::Closed),
        _ => Some(Group::Idle),
    }
}

/// The measured worktrees by group, in `Group::ALL` order, empty groups left out.
pub fn group(candidates: Vec<Candidate>) -> Vec<(Group, Vec<Candidate>)> {
    let mut by: HashMap<Group, Vec<Candidate>> = HashMap::new();
    for c in candidates {
        if let Some(g) = classify(&c.facts) {
            by.entry(g).or_default().push(c);
        }
    }
    Group::ALL.into_iter().filter_map(|g| by.remove(&g).map(|mut v| {
        v.sort_by(|a, b| a.path.cmp(&b.path));
        (g, v)
    })).collect()
}

// MARK: the habits an answer writes

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Answer {
    Delete,
    Keep,
    AskEachTime,
}

impl Answer {
    pub fn as_str(self) -> &'static str {
        match self {
            Answer::Delete => "delete",
            Answer::Keep => "keep",
            Answer::AskEachTime => "ask me each time",
        }
    }
}

pub fn delete_label(n: usize) -> String {
    if n == 1 {
        "Delete it".into()
    } else {
        format!("Delete all {n}")
    }
}

/// What a card offers: no delete for the at-risk group.
pub fn options(g: Group, n: usize) -> Vec<String> {
    let mut o = Vec::new();
    if g.can_delete() {
        o.push(delete_label(n));
    }
    o.push(KEEP.into());
    o.push(ASK_EACH_TIME.into());
    o
}

/// The answer an option names on this group's card; None for anything
/// else — a dismissal, or a delete the at-risk card never offered.
pub fn parse_answer(g: Group, n: usize, option: Option<&str>) -> Option<Answer> {
    match option? {
        o if g.can_delete() && o == delete_label(n) => Some(Answer::Delete),
        KEEP => Some(Answer::Keep),
        ASK_EACH_TIME => Some(Answer::AskEachTime),
        _ => None,
    }
}

/// The at-risk facts a worktree has above zero.
fn risks(f: &Facts) -> Vec<&'static str> {
    let mut out = Vec::new();
    if f.changed > 0 {
        out.push("uncommitted");
    }
    if f.untracked > 0 {
        out.push("untracked");
    }
    if f.ignored > 0 {
        out.push("ignored");
    }
    if f.unpushed.is_some_and(|n| n > 0) {
        out.push("unpushed");
    }
    out
}

/// The signatures a group's habits are written for: (id, when). One for a
/// group with nothing to lose; for the at-risk group one per (finished or
/// idle, at-risk fact) its members show — a `when` is a conjunction, and
/// "anything to lose" is not one fact. A member whose only risk is
/// unpushed commits git could not count gives none: no measured fact
/// says so, and no deletion habit matches an unknown anyway.
pub fn signatures(g: Group, members: &[Candidate]) -> Vec<(String, When)> {
    let zeros = "uncommitted: 0, untracked: 0, ignored: 0, unpushed: 0, busy_panes: 0";
    if g.can_delete() {
        let when = When::parse_yaml(&format!("{{{}, {zeros}}}", g.scope())).expect("inventory signatures are valid");
        return vec![(format!("inventory-{}", g.key()), when)];
    }
    let mut set: BTreeSet<(&str, &str)> = BTreeSet::new();
    for m in members {
        let scope = if matches!(m.facts.pr.as_deref(), Some("merged" | "closed")) { "done" } else { "idle" };
        for r in risks(&m.facts) {
            set.insert((scope, r));
        }
    }
    set.into_iter()
        .map(|(scope, fact)| {
            let s = if scope == "done" { "pr: \"merged|closed\"" } else { "pr: none, idle_days: \">=30\"" };
            let when = When::parse_yaml(&format!("{{{s}, {fact}: \">=1\", busy_panes: 0}}")).expect("inventory signatures are valid");
            (format!("inventory-at-risk-{scope}-{fact}"), when)
        })
        .collect()
}

/// The habits an answer writes, at the level it grants: delete → a
/// deletion habit at `ask`, keep → a `keep` habit, ask me each time → a
/// deletion habit at `observe`. One decision in each habit's evidence.
pub fn habits_for(g: Group, a: Answer, members: &[Candidate], today: &str) -> Vec<Habit> {
    let (act, level) = match a {
        Answer::Delete => (Do::DeleteWorktree, HabitLevel::Ask),
        Answer::Keep => (Do::Keep, HabitLevel::Observe),
        Answer::AskEachTime => (Do::DeleteWorktree, HabitLevel::Observe),
    };
    let decided = a != Answer::AskEachTime;
    signatures(g, members)
        .into_iter()
        .map(|(id, when)| Habit {
            id,
            about: habits::ABOUT_CLEANUP.into(),
            when,
            act,
            level,
            status: Status::Active,
            observed: today.into(),
            sources: Vec::new(),
            origin: Origin::Inventory,
            evidence: Evidence { approved: decided as u32, streak: (a == Answer::Delete) as u32, since: today.into(), ..Evidence::default() },
            examples: members.iter().map(|m| m.branch.clone()).filter(|b| !b.is_empty()).take(habits::tuning::EXAMPLES_CAP).collect(),
            approved: decided.then(|| today.to_string()),
        })
        .collect()
}

// MARK: the cards

/// One group's card, open.
#[derive(Clone, Debug, PartialEq)]
pub struct Card {
    pub payload: String,
    pub group: Group,
    pub members: Vec<Candidate>,
}

impl Card {
    /// The card's text and options. `i`/`of`: its place among the cards
    /// raised together.
    pub fn render(&self, i: usize, of: usize) -> (String, Vec<String>) {
        let n = self.members.len();
        let mut m = format!("First Mate · inventory {i}/{of}: {} — {}", self.group.title(), plural(n, "worktree"));
        for c in self.members.iter().take(LISTED) {
            m += &format!("\n• {} — {}", c.name(), c.facts.summary());
        }
        if n > LISTED {
            m += &format!("\n• +{} more", n - LISTED);
        }
        m += match self.group {
            Group::AtRisk => "\nDeleting these would lose work, so I only ask whether to keep them or ask you each time.",
            _ => "\nOne answer for the group; I learn from it. Branches are kept.",
        };
        (m, options(self.group, n))
    }
}

/// An answered card: the card, what the answer means (None: dismissed or
/// not an option of this card), and the habits it writes with their grants.
pub struct Answered {
    pub card: Card,
    pub answer: Option<Answer>,
    pub habits: Vec<(Habit, Grant)>,
}

/// The inventory cards open now.
#[derive(Default)]
pub struct Cards {
    open: HashMap<String, Card>,
}

impl Cards {
    /// One card per group, replacing any still open from an earlier
    /// inventory (their payloads are returned for the caller to drop).
    pub fn raise(&mut self, nonce: &str, groups: Vec<(Group, Vec<Candidate>)>) -> (Vec<Card>, Vec<String>) {
        let old: Vec<String> = self.open.drain().map(|(p, _)| p).collect();
        let cards: Vec<Card> = groups.into_iter().map(|(group, members)| Card { payload: format!("{PREFIX}{nonce}:{}", group.key()), group, members }).collect();
        for c in &cards {
            self.open.insert(c.payload.clone(), c.clone());
        }
        (cards, old)
    }

    pub fn contains(&self, payload: &str) -> bool {
        self.open.contains_key(payload)
    }

    pub fn payloads(&self) -> Vec<String> {
        self.open.keys().cloned().collect()
    }

    /// Worktrees on an open inventory card.
    pub fn worktrees(&self) -> impl Iterator<Item = &str> {
        self.open.values().flat_map(|c| c.members.iter().map(|m| m.path.as_str()))
    }

    pub fn clear(&mut self) {
        self.open.clear();
    }

    /// The user's answer. Only an option the card offered grants anything.
    pub fn answer(&mut self, payload: &str, option: Option<&str>, today: &str) -> Option<Answered> {
        let card = self.open.remove(payload)?;
        let answer = parse_answer(card.group, card.members.len(), option);
        let habits = answer
            .map(|a| {
                habits_for(card.group, a, &card.members, today)
                    .into_iter()
                    .map(|h| {
                        let g = Grant::from_inventory_card(GLOBAL, &h.id, h.level);
                        (h, g)
                    })
                    .collect()
            })
            .unwrap_or_default();
        Some(Answered { card, answer, habits })
    }
}

// MARK: deleting a group the user said to delete

#[derive(Debug, Default)]
pub struct DeleteReport {
    pub deleted: Vec<Candidate>,
    pub failed: Vec<(Candidate, String)>,
}

/// Delete a group's worktrees after the user's delete answer: each is
/// measured again and must still be in the same group with nothing to
/// lose; then the `Deleter` (the core's `worktree.delete`, attributed to
/// First Mate, `how` = inventory, with the card) removes it.
pub fn delete_group(g: Group, members: Vec<Candidate>, habit: &str, measure: impl Fn(&str) -> Facts, deleter: &dyn Deleter) -> DeleteReport {
    let mut r = DeleteReport::default();
    if !g.can_delete() {
        r.failed = members.into_iter().map(|m| (m, "this group is never deleted from its card".to_string())).collect();
        return r;
    }
    for mut m in members {
        let facts = measure(&m.path);
        if classify(&facts) != Some(g) || !habits::nothing_to_lose(&facts) {
            let why = format!("changed since the card: {}", facts.summary());
            m.facts = facts;
            r.failed.push((m, why));
            continue;
        }
        m.facts = facts;
        let routed = Routed { candidate: m, decision: Decision { key: GLOBAL.into(), id: habit.into(), level: HabitLevel::Ask } };
        match deleter.delete(&routed, HOW) {
            Ok(()) => r.deleted.push(routed.candidate),
            Err(e) => r.failed.push((routed.candidate, e)),
        }
    }
    r
}

// MARK: when it runs

/// A measurement running longer than this is taken for dead.
const STUCK: Duration = Duration::from_secs(60 * 60);

/// When the inventory runs: once, the first time First Mate is turned on
/// (the flag is `sweep::State::inventory_at`, written when it measured),
/// and whenever the user asks (`habits.inventory`). The sweep waits for it.
#[derive(Debug, Default)]
pub struct Schedule {
    due: bool,
    running: Option<Instant>,
}

/// What a `habits.inventory` request does.
#[derive(Debug, PartialEq, Eq)]
pub enum Request {
    Start,
    AlreadyMeasuring,
    Off,
}

impl Schedule {
    /// First Mate turned on: due if no inventory was ever taken.
    pub fn turned_on(&mut self, state: &sweep::State) {
        self.due = state.inventory_due();
    }

    pub fn busy(&self) -> bool {
        self.running.is_some_and(|t| t.elapsed() < STUCK)
    }

    /// Whether to start the automatic one now (marks it started).
    pub fn start_if_due(&mut self, paused: bool) -> bool {
        if !self.due || self.busy() || paused {
            return false;
        }
        self.due = false;
        self.running = Some(Instant::now());
        true
    }

    /// The user's request (marks it started when it is to start).
    pub fn request(&mut self, first_mate_running: bool) -> Request {
        if !first_mate_running {
            return Request::Off;
        }
        if self.busy() {
            return Request::AlreadyMeasuring;
        }
        self.due = false;
        self.running = Some(Instant::now());
        Request::Start
    }

    /// The measurement came back: the flag is written, done or not answered.
    pub fn measured(&mut self, state: &mut sweep::State, now: f64) {
        self.running = None;
        state.inventory_at = Some(now);
    }

    /// The sweep holds off while an inventory is due or measuring: the
    /// inventory's cards cover what it would ask.
    pub fn holds_sweep(&self) -> bool {
        self.due || self.busy()
    }
}

// MARK: lines and the preview

/// The note row when the cards go up (or when there is nothing to ask).
pub fn line_raised(measured: usize, groups: &[(Group, Vec<Candidate>)]) -> String {
    if groups.is_empty() {
        return format!("Inventory: measured {}; none looks finished, so there is nothing to ask.", plural(measured, "worktree"));
    }
    let parts: Vec<String> = groups.iter().map(|(g, m)| format!("{} {}", g.title(), m.len())).collect();
    format!(
        "Inventory: measured {} — {}. One card per group; nothing is deleted unless you say so.",
        plural(measured, "worktree"),
        parts.join(" · ")
    )
}

/// The note row for an answer.
pub fn line_answered(card: &Card, a: Answer, ids: &[String]) -> String {
    let habit = match a {
        Answer::Delete => "at ask",
        Answer::Keep => "keep: not offered again",
        Answer::AskEachTime => "at observe",
    };
    let mut s = if ids.is_empty() {
        format!("Inventory · {}: {} — nothing measurable to write a habit for", card.group.title(), a.as_str())
    } else {
        format!("Inventory · {}: {} — habit {} {habit}", card.group.title(), a.as_str(), ids.join(", "))
    };
    if a == Answer::Delete {
        s += &format!("; deleting {}", plural(card.members.len(), "worktree"));
    }
    s + "."
}

pub fn line_deleted(g: Group, r: &DeleteReport) -> String {
    let mut s = format!("Inventory deleted {} ({}). Branches kept.", plural(r.deleted.len(), "worktree"), g.title());
    if !r.failed.is_empty() {
        let left: Vec<String> = r.failed.iter().map(|(c, why)| format!("{} ({why})", c.name())).collect();
        s += &format!(" Left alone: {}.", left.join(" · "));
    }
    s
}

/// `habits.inventory {preview: true}`: the groups, raising nothing.
pub fn preview_json(measured: usize, groups: &[(Group, Vec<Candidate>)]) -> Value {
    let gs: Vec<Value> = groups
        .iter()
        .map(|(g, m)| {
            json!({
                "group": g.key(),
                "title": g.title(),
                "options": options(*g, m.len()),
                "habits": signatures(*g, m).into_iter().map(|(id, _)| id).collect::<Vec<_>>(),
                "worktrees": m.iter().map(|c| json!({"path": c.path, "repo": c.repo, "branch": c.branch, "facts": c.facts.summary()})).collect::<Vec<_>>(),
            })
        })
        .collect();
    json!({"measured": measured, "groups": gs})
}

fn plural(n: usize, one: &str) -> String {
    format!("{n} {one}{}", if n == 1 { "" } else { "s" })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::first_mate::habits::{Book, Precedence, Store};
    use crate::first_mate::rules::Level as RuleLevel;
    use std::cell::RefCell;

    const TODAY: &str = "2026-11-05";

    fn clean(pr: &str) -> Facts {
        Facts { pr: Some(pr.into()), unpushed: Some(0), idle_days: Some(3), ..Facts::default() }
    }

    fn cand(name: &str, facts: Facts) -> Candidate {
        Candidate { path: format!("/nonexistent/wt/{name}"), repo: "/nonexistent/repo".into(), branch: format!("feat/{name}"), facts }
    }

    fn names(v: &[Candidate]) -> Vec<String> {
        v.iter().map(|c| c.name()).collect()
    }

    /// Records what it was asked to delete; never touches a disk.
    #[derive(Default)]
    struct FakeDeleter {
        calls: RefCell<Vec<(String, String, String)>>,
    }

    impl Deleter for FakeDeleter {
        fn delete(&self, r: &Routed, how: &str) -> Result<(), String> {
            self.calls.borrow_mut().push((r.candidate.path.clone(), how.into(), r.decision.id.clone()));
            if r.candidate.path.ends_with("/busy") {
                return Err("git worktree remove: busy".into());
            }
            Ok(())
        }
    }

    fn mixed() -> Vec<Candidate> {
        vec![
            cand("m1", clean("merged")),
            cand("m2", Facts { days_since_merge: Some(40), ..clean("merged") }),
            cand("c1", clean("closed")),
            cand("i1", Facts { idle_days: Some(45), ..clean("none") }),
            cand("young", Facts { idle_days: Some(10), ..clean("none") }),
            cand("open", clean("open")),
            cand("draft", clean("draft")),
            cand("unknown-pr", Facts { pr: None, idle_days: Some(90), ..clean("none") }),
            cand("busy", Facts { busy_panes: 1, ..clean("merged") }),
            cand("dirty", Facts { changed: 2, ..clean("merged") }),
            cand("env", Facts { ignored: 1, ignored_files: vec![".env".into()], ..clean("closed") }),
            cand("ahead", Facts { unpushed: Some(3), idle_days: Some(60), ..clean("none") }),
            cand("cant-tell", Facts { unpushed: None, ..clean("merged") }),
            cand("young-dirty", Facts { untracked: 4, idle_days: Some(2), ..clean("none") }),
        ]
    }

    #[test]
    fn groups_by_signature_and_leaves_live_work_out() {
        let g = group(mixed());
        let got: Vec<(Group, Vec<String>)> = g.iter().map(|(g, m)| (*g, names(m))).collect();
        assert_eq!(
            got,
            vec![
                (Group::Merged, vec!["m1".into(), "m2".into()]),
                (Group::Closed, vec!["c1".into()]),
                (Group::Idle, vec!["i1".into()]),
                (Group::AtRisk, vec!["ahead".into(), "cant-tell".into(), "dirty".into(), "env".into()]),
            ],
            "open/draft PRs, busy panes, recent work without a PR and an unknown PR are not listed"
        );
    }

    #[test]
    fn empty_groups_are_left_out_and_nothing_means_no_card() {
        let g = group(vec![cand("m1", clean("merged")), cand("open", clean("open"))]);
        assert_eq!(g.iter().map(|(g, _)| *g).collect::<Vec<_>>(), vec![Group::Merged]);
        let none = group(vec![cand("open", clean("open")), cand("young", Facts { idle_days: Some(1), ..clean("none") })]);
        assert!(none.is_empty());
        let mut cards = Cards::default();
        let (raised, _) = cards.raise("n0", none.clone());
        assert!(raised.is_empty() && cards.payloads().is_empty(), "no card at all");
        assert_eq!(line_raised(2, &none), "Inventory: measured 2 worktrees; none looks finished, so there is nothing to ask.");
    }

    #[test]
    fn the_at_risk_group_cannot_be_deleted() {
        let g = group(mixed());
        let (_, at_risk) = g.iter().find(|(g, _)| *g == Group::AtRisk).unwrap();
        let n = at_risk.len();
        assert_eq!(options(Group::AtRisk, n), vec![KEEP, ASK_EACH_TIME]);
        assert_eq!(options(Group::Merged, 2), vec!["Delete all 2", KEEP, ASK_EACH_TIME]);
        assert_eq!(options(Group::Closed, 1), vec!["Delete it", KEEP, ASK_EACH_TIME]);
        // A delete sent anyway (a stale client, a hand-made answer) is no answer.
        assert_eq!(parse_answer(Group::AtRisk, n, Some(&delete_label(n))), None);
        let mut cards = Cards::default();
        let (raised, _) = cards.raise("n1", g.clone());
        let p = raised.iter().find(|c| c.group == Group::AtRisk).unwrap().payload.clone();
        let a = cards.answer(&p, Some(&delete_label(n)), TODAY).unwrap();
        assert!(a.answer.is_none() && a.habits.is_empty());
        // And deleting the group directly refuses every member.
        let d = FakeDeleter::default();
        let r = delete_group(Group::AtRisk, at_risk.clone(), "x", |_| clean("merged"), &d);
        assert!(d.calls.borrow().is_empty());
        assert_eq!(r.failed.len(), n);
    }

    fn global_book(dir: &std::path::Path) -> (Store, Book) {
        let store = Store::new(dir.to_path_buf());
        let b = store.load(GLOBAL, TODAY);
        (store, b)
    }

    fn adopt_all(b: &mut Book, a: Answered) -> Vec<String> {
        let mut ids = Vec::new();
        for (h, g) in a.habits {
            ids.push(h.id.clone());
            b.adopt(h, g, TODAY).unwrap();
        }
        ids
    }

    #[test]
    fn delete_writes_an_ask_habit_granted_by_the_answer_and_deletes_after_rematching() {
        let tmp = tempfile::tempdir().unwrap();
        let (store, mut book) = global_book(tmp.path());
        let mut cards = Cards::default();
        let merged = vec![cand("m1", clean("merged")), cand("m2", clean("merged")), cand("busy", clean("merged")), cand("changed", clean("merged"))];
        let (raised, _) = cards.raise("n2", vec![(Group::Merged, merged.clone())]);
        let card = &raised[0];
        assert_eq!(card.payload, "habit.inventory:n2:merged");
        let (msg, opts) = card.render(1, 1);
        assert!(msg.starts_with("First Mate · inventory 1/1: PR merged, nothing to lose — 4 worktrees"), "{msg}");
        assert_eq!(opts[0], "Delete all 4");

        let a = cards.answer(&card.payload, Some("Delete all 4"), TODAY).unwrap();
        assert_eq!(a.answer, Some(Answer::Delete));
        assert!(!cards.contains(&card.payload), "answered once");
        let members = a.card.members.clone();
        let ids = adopt_all(&mut book, a);
        assert_eq!(ids, vec!["inventory-merged"]);
        store.save(&book, 1_793_000_000.0).unwrap();

        // Read back as the core does: granted at ask, origin inventory, one decision.
        let back = store.load(GLOBAL, TODAY);
        let h = back.get("inventory-merged").unwrap();
        assert_eq!((back.level(h), h.act, h.origin), (HabitLevel::Ask, Do::DeleteWorktree, Origin::Inventory));
        assert_eq!(h.evidence.approved, 1, "one answer about four worktrees is one decision");
        assert!(back.notes.is_empty(), "{:?}", back.notes);
        let granted: Value = serde_json::from_str(&std::fs::read_to_string(tmp.path().join(".granted.json")).unwrap()).unwrap();
        assert_eq!(granted[GLOBAL]["inventory-merged"], "ask");
        // It decides a clean merged worktree at ask, never auto.
        let prec = Precedence { repo_cap: None, user_default: RuleLevel::Auto };
        let d = habits::decide(&clean("merged"), &[&back], &prec).unwrap();
        assert_eq!(d.level, HabitLevel::Ask);
        assert!(!h.when.matches(&Facts { untracked: 1, ..clean("merged") }));

        // Deletion: re-measured; one changed since, one fails in git.
        let del = FakeDeleter::default();
        let measure = |p: &str| if p.ends_with("/changed") { Facts { changed: 1, ..clean("merged") } } else { clean("merged") };
        let r = delete_group(Group::Merged, members, "inventory-merged", measure, &del);
        let calls = del.calls.borrow().clone();
        assert_eq!(calls.iter().map(|c| c.0.rsplit('/').next().unwrap().to_string()).collect::<Vec<_>>(), vec!["m1", "m2", "busy"]);
        assert!(calls.iter().all(|c| c.1 == "inventory" && c.2 == "inventory-merged"));
        assert_eq!(names(&r.deleted), vec!["m1", "m2"]);
        assert_eq!(r.failed.len(), 2);
        assert!(r.failed.iter().any(|(c, why)| c.name() == "changed" && why.starts_with("changed since the card")));
        assert_eq!(line_deleted(Group::Merged, &r).split(" Left alone").next().unwrap(), "Inventory deleted 2 worktrees (PR merged, nothing to lose). Branches kept.");
    }

    #[test]
    fn keep_writes_a_keep_habit_that_stops_the_group_being_offered() {
        let tmp = tempfile::tempdir().unwrap();
        let (store, mut book) = global_book(tmp.path());
        let mut cards = Cards::default();
        let (raised, _) = cards.raise("n3", vec![(Group::Merged, vec![cand("m1", clean("merged"))])]);
        let a = cards.answer(&raised[0].payload, Some(KEEP), TODAY).unwrap();
        assert_eq!(a.answer, Some(Answer::Keep));
        adopt_all(&mut book, a);
        store.save(&book, 1_793_000_000.0).unwrap();
        let back = store.load(GLOBAL, TODAY);
        let h = back.get("inventory-merged").unwrap();
        assert_eq!((h.act, h.evidence.approved), (Do::Keep, 1));
        // The seed would offer a clean merged worktree; the keep habit wins.
        let prec = Precedence { repo_cap: None, user_default: RuleLevel::Ask };
        assert_eq!(habits::decide(&clean("merged"), &[&back], &prec), None);
    }

    #[test]
    fn ask_each_time_writes_an_observe_habit() {
        let tmp = tempfile::tempdir().unwrap();
        let (store, mut book) = global_book(tmp.path());
        let mut cards = Cards::default();
        let (raised, _) = cards.raise("n4", vec![(Group::Idle, vec![cand("i1", Facts { idle_days: Some(40), ..clean("none") })])]);
        let a = cards.answer(&raised[0].payload, Some(ASK_EACH_TIME), TODAY).unwrap();
        adopt_all(&mut book, a);
        store.save(&book, 1_793_000_000.0).unwrap();
        let back = store.load(GLOBAL, TODAY);
        let h = back.get("inventory-idle").unwrap();
        assert_eq!((back.level(h), h.act, h.evidence.approved), (HabitLevel::Observe, Do::DeleteWorktree, 0));
        assert!(h.when.matches(&Facts { idle_days: Some(31), ..clean("none") }));
        assert!(!h.when.matches(&Facts { idle_days: Some(29), ..clean("none") }));
    }

    #[test]
    fn at_risk_habits_follow_what_the_members_have_to_lose() {
        let members = vec![
            cand("dirty", Facts { changed: 2, ..clean("merged") }),
            cand("env", Facts { ignored: 1, ..clean("closed") }),
            cand("ahead", Facts { unpushed: Some(3), idle_days: Some(60), ..clean("none") }),
            cand("cant-tell", Facts { unpushed: None, ..clean("merged") }),
        ];
        let ids: Vec<String> = signatures(Group::AtRisk, &members).into_iter().map(|(id, _)| id).collect();
        assert_eq!(ids, vec!["inventory-at-risk-done-ignored", "inventory-at-risk-done-uncommitted", "inventory-at-risk-idle-unpushed"]);
        let mut cards = Cards::default();
        let (raised, _) = cards.raise("n5", vec![(Group::AtRisk, members)]);
        let a = cards.answer(&raised[0].payload, Some(KEEP), TODAY).unwrap();
        assert!(a.habits.iter().all(|(h, g)| h.act == Do::Keep && g.level == HabitLevel::Observe));
        // A keep for "merged with uncommitted files" leaves such a worktree alone.
        let tmp = tempfile::tempdir().unwrap();
        let (_, mut book) = global_book(tmp.path());
        adopt_all(&mut book, a);
        let prec = Precedence { repo_cap: None, user_default: RuleLevel::Ask };
        assert_eq!(habits::decide(&Facts { changed: 1, ..clean("merged") }, &[&book], &prec), None);
        // An at-risk deletion habit can never be auto.
        let h = book.get("inventory-at-risk-done-uncommitted").unwrap();
        assert!(h.when.admits_risk());
    }

    #[test]
    fn redoing_counts_one_more_decision_and_follows_the_new_answer() {
        let tmp = tempfile::tempdir().unwrap();
        let (_, mut book) = global_book(tmp.path());
        let mut cards = Cards::default();
        let group = || vec![(Group::Closed, vec![cand("c1", clean("closed")), cand("c2", clean("closed"))])];
        let (r1, _) = cards.raise("n6", group());
        adopt_all(&mut book, cards.answer(&r1[0].payload, Some("Delete all 2"), TODAY).unwrap());
        let (r2, old) = cards.raise("n7", group());
        assert!(old.is_empty(), "the first card was answered");
        adopt_all(&mut book, cards.answer(&r2[0].payload, Some("Delete all 2"), TODAY).unwrap());
        let h = book.get("inventory-closed").unwrap();
        assert_eq!((h.evidence.approved, h.evidence.streak, book.level(h)), (2, 2, HabitLevel::Ask));
        // Changed their mind: keep. The habit turns into a keep habit.
        let (r3, _) = cards.raise("n8", group());
        let (r4, old) = cards.raise("n9", group());
        assert_eq!(old, vec![r3[0].payload.clone()], "a redo replaces the cards still open");
        assert!(cards.answer(&r3[0].payload, Some(KEEP), TODAY).is_none(), "a replaced card answers nothing");
        adopt_all(&mut book, cards.answer(&r4[0].payload, Some(KEEP), TODAY).unwrap());
        let h = book.get("inventory-closed").unwrap();
        assert_eq!((h.act, h.evidence.approved, h.evidence.streak), (Do::Keep, 3, 0));
        assert_eq!(book.habits.iter().filter(|h| h.id == "inventory-closed").count(), 1);
    }

    #[test]
    fn a_grant_only_covers_its_own_habit_and_never_auto() {
        let tmp = tempfile::tempdir().unwrap();
        let (_, mut book) = global_book(tmp.path());
        let h = habits_for(Group::Merged, Answer::Delete, &[cand("m1", clean("merged"))], TODAY).remove(0);
        let other = Grant::from_inventory_card(GLOBAL, "something-else", HabitLevel::Ask);
        assert!(book.adopt(h.clone(), other, TODAY).is_err());
        let auto = Grant::from_inventory_card(GLOBAL, &h.id, HabitLevel::Auto);
        assert_eq!(auto.level, HabitLevel::Ask, "an inventory grant is capped at ask");
        let wrong_book = Grant::from_inventory_card("repo-1234", &h.id, HabitLevel::Ask);
        assert!(book.adopt(h, wrong_book, TODAY).is_err());
    }

    #[test]
    fn dismissing_writes_nothing() {
        let mut cards = Cards::default();
        let (raised, _) = cards.raise("n10", vec![(Group::Merged, vec![cand("m1", clean("merged"))])]);
        let a = cards.answer(&raised[0].payload, None, TODAY).unwrap();
        assert!(a.answer.is_none() && a.habits.is_empty());
    }

    #[test]
    fn taken_once_on_first_turning_on_and_again_on_request() {
        let tmp = tempfile::tempdir().unwrap();
        let path = sweep::State::path(tmp.path());
        let mut state = sweep::State::load(&path);
        let mut s = Schedule::default();
        // Never taken: turning on makes it due, and the sweep waits.
        s.turned_on(&state);
        assert!(s.holds_sweep());
        assert!(!s.start_if_due(true), "not while paused");
        assert!(s.start_if_due(false));
        assert!(!s.start_if_due(false), "started once");
        assert!(s.holds_sweep(), "measuring");
        assert_eq!(s.request(true), Request::AlreadyMeasuring);
        s.measured(&mut state, 1_793_000_000.0);
        assert!(!s.holds_sweep());
        state.save(&path);

        // A core restart, or turning First Mate off and on: not again.
        let state = sweep::State::load(&path);
        assert_eq!(state.inventory_at, Some(1_793_000_000.0));
        let mut s = Schedule::default();
        s.turned_on(&state);
        assert!(!s.holds_sweep() && !s.start_if_due(false));

        // The user redoes it: only with First Mate on.
        assert_eq!(s.request(false), Request::Off);
        assert_eq!(s.request(true), Request::Start);
        assert!(s.busy());
    }

    #[test]
    fn lines_and_preview() {
        let g = group(mixed());
        let line = line_raised(14, &g);
        assert!(line.starts_with("Inventory: measured 14 worktrees — PR merged, nothing to lose 2 · "), "{line}");
        let p = preview_json(14, &g);
        assert_eq!(p["groups"][0]["group"], "merged");
        assert_eq!(p["groups"][3]["options"], json!([KEEP, ASK_EACH_TIME]));
        let card = Card { payload: "p".into(), group: Group::Merged, members: vec![cand("m1", clean("merged"))] };
        assert_eq!(line_answered(&card, Answer::Delete, &["inventory-merged".into()]), "Inventory · PR merged, nothing to lose: delete — habit inventory-merged at ask; deleting 1 worktree.");
    }
}
