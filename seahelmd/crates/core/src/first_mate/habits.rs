//! First Mate's habits (docs/first-mate-autonomy.md, "The learning loop" ›
//! "Habits", "Promotion and demotion", "Where habits sit against rules"):
//! what the user does again and again, written in facts the core measures,
//! with a level saying how much of it First Mate may take over.
//!
//! Files, local to this machine (D7): `first-mate/habits/<repo-key>.yml`
//! per project and `habits/_global.yml` for every project, each a YAML
//! list in the doc's format. Every write keeps the file it replaced under
//! `habits/.history/`, so a change can be undone (`Store::undo`).
//!
//! Levels only go up through a card the user answers (D1). The core keeps
//! the level it granted each habit in `habits/.granted.json` and reads a
//! file's level as at most that: a level raised by anything but the core's
//! own promotion path — First Mate editing the file, a script, a stale
//! copy — is held at what the core granted. The only way to a higher
//! grant is a `Grant`, which only `Offers::answer` makes, from the user's
//! yes on a promotion card the core raised itself. The one exception is
//! `observe → suggest`, which only means "mention it", and is the core's
//! own counting (`Book::count`). Down is automatic: a rejection, an undone
//! automatic deletion, two unanswered expiries.
//!
//! A level raised by hand in the file (above the grant) is not dropped
//! silently (D12): it stays in the file, is honoured at the grant, and the
//! core asks on a confirmation card (`habit.confirm:`). Yes grants it; no
//! writes the file back to the granted level.
//!
//! `.granted.json` is sealed (docs/first-mate-autonomy.md, "Who may answer
//! a card"): the core keeps the text it last wrote, in memory and in
//! `.granted.seal.json` with its SHA-256, and every read compares. A change
//! the core did not make — First Mate's shell editing the file, a deleted
//! file — is put back to the core's version and reported (a note in First
//! Mate's timeline, an audit line). `.history/` needs no seal: it only feeds
//! `undo`, which can only lower a grant.
//!
//! Measurable habits only in this phase: `when` must use the vocabulary
//! (`Fact`); judgement habits arrive with phase 6. A habit whose `when`
//! admits uncommitted, untracked, ignored or unpushed work, or busy panes,
//! can never be `auto`, whatever the file or the evidence says.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use serde_yaml::{Mapping, Value as Yaml};

use super::facts::Facts;
use super::lang::{Lang, Text};
use super::observations::{self, Record};
use super::rules::Level as RuleLevel;

/// The learning loop's thresholds, in one place (phase 6 tunes them, D9).
pub mod tuning {
    /// Matching actions before `observe` becomes `suggest`, and fresh ones
    /// before `suggest → ask` is offered (again, after a decline).
    pub const N: usize = 3;
    /// Approvals in a row before `ask → auto` is offered.
    pub const M: u32 = 5;
    /// The actions behind N must fall on this many distinct days…
    pub const MIN_DAYS: usize = 2;
    /// …and in this many distinct worktrees: one answer about twelve
    /// worktrees is one decision, not twelve.
    pub const MIN_WORKTREES: usize = 2;
    /// A branch checked out again as a worktree within this many days of
    /// First Mate deleting it on its own undoes that deletion.
    pub const UNDO_WINDOW_DAYS: f64 = 7.0;
    /// Unanswered expiries in a row that take a habit down a level.
    pub const EXPIRIES_TO_DEMOTE: u32 = 2;
    /// Branch names kept as examples.
    pub const EXAMPLES_CAP: usize = 8;
}

pub const GLOBAL: &str = "_global";
pub const SEED_ID: &str = "delete-merged-clean";
pub const ABOUT_CLEANUP: &str = "worktree.cleanup";
pub const YES_PREFIX: &str = "Yes, ";
pub const NOT_YET: &str = "Not yet";
pub const PROMOTE_PREFIX: &str = "habit.promote:";
pub const CONFIRM_PREFIX: &str = "habit.confirm:";
pub const PUT_IT_BACK: &str = "No, put it back";

// MARK: levels and the vocabulary

/// How much of a habit First Mate does, least first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HabitLevel {
    /// A hypothesis being counted: nothing happens.
    Observe,
    /// Mentioned in a line, no card.
    Suggest,
    /// Done after one tap (batched).
    Ask,
    /// Done, and reported afterwards.
    Auto,
}

impl HabitLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            HabitLevel::Observe => "observe",
            HabitLevel::Suggest => "suggest",
            HabitLevel::Ask => "ask",
            HabitLevel::Auto => "auto",
        }
    }

    pub fn up(self) -> Option<Self> {
        match self {
            HabitLevel::Observe => Some(HabitLevel::Suggest),
            HabitLevel::Suggest => Some(HabitLevel::Ask),
            HabitLevel::Ask => Some(HabitLevel::Auto),
            HabitLevel::Auto => None,
        }
    }

    pub fn down(self) -> Self {
        match self {
            HabitLevel::Auto => HabitLevel::Ask,
            HabitLevel::Ask => HabitLevel::Suggest,
            _ => HabitLevel::Observe,
        }
    }

    /// Held under a rule level: `deny` silences it, `ask` caps it.
    pub fn capped_by(self, rule: RuleLevel) -> Self {
        match rule {
            RuleLevel::Auto => self,
            RuleLevel::Ask => self.min(HabitLevel::Ask),
            RuleLevel::Deny => HabitLevel::Observe,
        }
    }
}

/// The measured facts a `when` may name (docs: "Vocabulary of measured facts").
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Fact {
    Pr,
    DaysSinceMerge,
    Uncommitted,
    Untracked,
    Ignored,
    Unpushed,
    IdleDays,
    BusyPanes,
    IdenticalToBase,
    /// Derived: uncommitted, untracked, ignored or unpushed above zero.
    AtRisk,
}

impl Fact {
    pub const ALL: [Fact; 10] = [
        Fact::Pr,
        Fact::DaysSinceMerge,
        Fact::Uncommitted,
        Fact::Untracked,
        Fact::Ignored,
        Fact::Unpushed,
        Fact::IdleDays,
        Fact::BusyPanes,
        Fact::IdenticalToBase,
        Fact::AtRisk,
    ];
    /// What a deletion could lose: an `auto` habit must pin each to zero.
    pub const AT_RISK: [Fact; 5] = [Fact::Uncommitted, Fact::Untracked, Fact::Ignored, Fact::Unpushed, Fact::BusyPanes];

    pub fn as_str(self) -> &'static str {
        match self {
            Fact::Pr => "pr",
            Fact::DaysSinceMerge => "days_since_merge",
            Fact::Uncommitted => "uncommitted",
            Fact::Untracked => "untracked",
            Fact::Ignored => "ignored",
            Fact::Unpushed => "unpushed",
            Fact::IdleDays => "idle_days",
            Fact::BusyPanes => "busy_panes",
            Fact::IdenticalToBase => "identical_to_base",
            Fact::AtRisk => "at_risk",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        // The doc's table spells it `ignored_files`.
        if s == "ignored_files" {
            return Some(Fact::Ignored);
        }
        Fact::ALL.into_iter().find(|f| f.as_str() == s)
    }

    fn vocabulary() -> String {
        Fact::ALL.iter().map(|f| f.as_str()).collect::<Vec<_>>().join(", ")
    }
}

pub const PR_STATES: &[&str] = &["merged", "closed", "open", "draft", "none"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    Eq,
    Ge,
    Gt,
    Le,
    Lt,
}

/// One fact's condition.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Cond {
    /// `0`, `">=1"`, `"<3"`.
    Num(Op, u32),
    /// `merged`, `"merged|closed"`, `[merged, closed]`.
    Pr(Vec<String>),
    Bool(bool),
}

impl Cond {
    fn parse(fact: Fact, v: &Yaml) -> Result<Cond, String> {
        let name = fact.as_str();
        match fact {
            Fact::Pr => {
                let states: Vec<String> = match v {
                    Yaml::String(s) => s.split('|').map(|x| x.trim().to_string()).collect(),
                    Yaml::Sequence(seq) => seq.iter().map(|x| x.as_str().map(str::to_string).ok_or_else(|| format!("`pr`: {x:?} is not a state"))).collect::<Result<_, _>>()?,
                    _ => return Err("`pr` must be a state or a list of states".into()),
                };
                if states.is_empty() {
                    return Err("`pr` names no state".into());
                }
                if let Some(bad) = states.iter().find(|s| !PR_STATES.contains(&s.as_str())) {
                    return Err(format!("`pr`: unknown state `{bad}` ({})", PR_STATES.join(", ")));
                }
                Ok(Cond::Pr(states))
            }
            Fact::IdenticalToBase | Fact::AtRisk => v.as_bool().map(Cond::Bool).ok_or_else(|| format!("`{name}` must be true or false")),
            _ => {
                let text = match v {
                    Yaml::Number(n) => n.as_u64().map(|n| n.to_string()).ok_or_else(|| format!("`{name}`: {n} is not a whole number"))?,
                    Yaml::String(s) => s.trim().to_string(),
                    _ => return Err(format!("`{name}` must be a number or a comparison like \">=1\"")),
                };
                let (op, rest) = [(">=", Op::Ge), ("<=", Op::Le), ("==", Op::Eq), (">", Op::Gt), ("<", Op::Lt), ("=", Op::Eq)]
                    .into_iter()
                    .find_map(|(p, op)| text.strip_prefix(p).map(|r| (op, r)))
                    .unwrap_or((Op::Eq, text.as_str()));
                let n: u32 = rest.trim().parse().map_err(|_| format!("`{name}`: `{text}` is not a number or a comparison like \">=1\""))?;
                if op == Op::Lt && n == 0 {
                    return Err(format!("`{name}`: `<0` matches nothing"));
                }
                Ok(Cond::Num(op, n))
            }
        }
    }

    fn to_yaml(&self) -> Yaml {
        match self {
            Cond::Num(Op::Eq, n) => Yaml::Number((*n as u64).into()),
            Cond::Num(op, n) => {
                let p = match op {
                    Op::Ge => ">=",
                    Op::Gt => ">",
                    Op::Le => "<=",
                    Op::Lt => "<",
                    Op::Eq => "",
                };
                Yaml::String(format!("{p}{n}"))
            }
            Cond::Pr(states) if states.len() == 1 => Yaml::String(states[0].clone()),
            Cond::Pr(states) => Yaml::String(states.join("|")),
            Cond::Bool(b) => Yaml::Bool(*b),
        }
    }

    fn holds(&self, n: u32) -> bool {
        match self {
            Cond::Num(Op::Eq, x) => n == *x,
            Cond::Num(Op::Ge, x) => n >= *x,
            Cond::Num(Op::Gt, x) => n > *x,
            Cond::Num(Op::Le, x) => n <= *x,
            Cond::Num(Op::Lt, x) => n < *x,
            _ => false,
        }
    }

    /// Whether some value above zero satisfies it.
    fn admits_positive(&self) -> bool {
        match self {
            Cond::Num(Op::Eq, x) => *x > 0,
            Cond::Num(Op::Le, x) => *x >= 1,
            Cond::Num(Op::Lt, x) => *x >= 2,
            Cond::Num(Op::Ge | Op::Gt, _) => true,
            _ => true,
        }
    }
}

/// A habit's situation, in measured facts. A fact the core could not
/// measure (`None`) never matches: unknown is not zero.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct When(pub BTreeMap<Fact, Cond>, pub Option<String>);

impl TryFrom<Mapping> for When {
    type Error = String;

    fn try_from(m: Mapping) -> Result<Self, String> {
        let mut out = BTreeMap::new();
        for (k, v) in m {
            let key = k.as_str().ok_or("`when` keys must be fact names")?;
            let fact = Fact::parse(key).ok_or_else(|| format!("`when`: unknown fact `{key}` (vocabulary: {})", Fact::vocabulary()))?;
            if out.insert(fact, Cond::parse(fact, &v)?).is_some() {
                return Err(format!("`when` names `{}` twice", fact.as_str()));
            }
        }
        if out.is_empty() {
            return Err("`when` names no fact".into());
        }
        Ok(When(out, None))
    }
}

impl From<When> for Mapping {
    fn from(w: When) -> Mapping {
        w.0.iter().map(|(f, c)| (Yaml::String(f.as_str().into()), c.to_yaml())).collect()
    }
}

impl Serialize for When {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        if let Some(prose) = &self.1 { return prose.serialize(s); }
        Mapping::from(self.clone()).serialize(s)
    }
}

impl<'de> Deserialize<'de> for When {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = Yaml::deserialize(d)?;
        match v {
            Yaml::String(prose) if !prose.trim().is_empty() && prose.len() <= 2000 => Ok(When(BTreeMap::new(), Some(prose))),
            Yaml::Mapping(m) => When::try_from(m).map_err(serde::de::Error::custom),
            _ => Err(serde::de::Error::custom("when must be measured facts or nonempty prose (at most 2000 bytes)")),
        }
    }
}

impl When {
    pub fn parse_yaml(text: &str) -> Result<When, String> {
        let m: Mapping = serde_yaml::from_str(text).map_err(|e| e.to_string())?;
        When::try_from(m)
    }

    pub fn matches(&self, f: &Facts) -> bool {
        self.1.is_none() && self.0.iter().all(|(fact, cond)| match (fact, cond) {
            (Fact::Pr, Cond::Pr(states)) => f.pr.as_ref().is_some_and(|p| states.contains(p)),
            (Fact::IdenticalToBase, Cond::Bool(b)) => f.identical_to_base == Some(*b),
            (Fact::AtRisk, Cond::Bool(b)) => at_risk(f) == Some(*b),
            (fact, cond) => {
                let n = match fact {
                    Fact::DaysSinceMerge => f.days_since_merge,
                    Fact::Uncommitted => Some(f.changed),
                    Fact::Untracked => Some(f.untracked),
                    Fact::Ignored => Some(f.ignored),
                    Fact::Unpushed => f.unpushed,
                    Fact::IdleDays => f.idle_days,
                    Fact::BusyPanes => Some(f.busy_panes),
                    Fact::Pr | Fact::IdenticalToBase | Fact::AtRisk => None,
                };
                n.is_some_and(|n| cond.holds(n))
            }
        })
    }

    /// Admits a worktree with something to lose (uncommitted, untracked,
    /// ignored or unpushed work, or a busy pane): such a habit is never `auto`.
    /// `at_risk: true` always admits it; `at_risk: false` pins the four
    /// work facts to zero (busy panes still have to be pinned on their own).
    pub fn admits_risk(&self) -> bool {
        !self.risky_facts().is_empty()
    }

    /// The fact names that admit risk, for messages.
    pub fn risky_facts(&self) -> Vec<&'static str> {
        if self.1.is_some() { return vec!["judgement"]; }
        match self.0.get(&Fact::AtRisk) {
            Some(Cond::Bool(true)) => return vec![Fact::AtRisk.as_str()],
            Some(Cond::Bool(false)) => return self.admits(&[Fact::BusyPanes]),
            _ => {}
        }
        self.admits(&Fact::AT_RISK)
    }

    fn admits(&self, facts: &[Fact]) -> Vec<&'static str> {
        facts.iter().filter(|f| self.0.get(f).is_none_or(Cond::admits_positive)).map(|f| f.as_str()).collect()
    }
}

/// The derived `at_risk` fact: true when uncommitted, untracked, ignored
/// or unpushed work is above zero; false when all four are known to be
/// zero; None when nothing is above zero but git could not count the
/// unpushed commits (unknown is not zero).
pub fn at_risk(f: &Facts) -> Option<bool> {
    if f.changed > 0 || f.untracked > 0 || f.ignored > 0 || f.unpushed.is_some_and(|n| n > 0) {
        return Some(true);
    }
    f.unpushed.map(|_| false)
}

/// The facts are clean enough for anything to delete the worktree on its
/// own: nothing uncommitted, untracked, ignored or unpushed (known to be
/// zero), no busy pane. Checked again on the facts at hand, not only on the
/// habit's `when`.
pub fn nothing_to_lose(f: &Facts) -> bool {
    f.changed == 0 && f.untracked == 0 && f.ignored == 0 && f.unpushed == Some(0) && f.busy_panes == 0
}

// MARK: habits

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Do {
    DeleteWorktree,
    /// A group the user wants left alone: a match keeps every other habit
    /// off the worktree.
    Keep,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    #[default]
    Active,
    /// Kept in place beside its replacement; never matched.
    Superseded,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    /// Ships with seahelm.
    General,
    Inventory,
    #[default]
    Learned,
    User,
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

fn is_zero_usize(n: &usize) -> bool {
    *n == 0
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Evidence {
    #[serde(default)]
    pub approved: u32,
    #[serde(default)]
    pub rejected: u32,
    /// Removals by the user or an agent whose last facts matched.
    #[serde(default)]
    pub manual: u32,
    /// Cards that expired unanswered.
    #[serde(default)]
    pub ignored: u32,
    /// The user's answers about this habit's group on an inventory card,
    /// whatever they answered: one per answer, however many worktrees.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub decisions: u32,
    /// Automatic deletions the user undid.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub undone: u32,
    #[serde(default)]
    pub since: String,
    /// Approvals in a row (a rejection or a decline resets it).
    #[serde(default, skip_serializing_if = "is_zero")]
    pub streak: u32,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub expired_in_row: u32,
    /// `sources` before this index were spent on an earlier level change
    /// or a declined offer; gates count only the ones after it.
    #[serde(default, skip_serializing_if = "is_zero_usize")]
    pub fresh_from: usize,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Habit {
    pub id: String,
    #[serde(default)]
    pub about: String,
    pub when: When,
    #[serde(rename = "do")]
    pub act: Do,
    pub level: HabitLevel,
    #[serde(default)]
    pub status: Status,
    #[serde(default)]
    pub observed: String,
    /// Observation ids counted as manual evidence, oldest first.
    #[serde(default)]
    pub sources: Vec<String>,
    #[serde(default)]
    pub origin: Origin,
    #[serde(default)]
    pub evidence: Evidence,
    #[serde(default)]
    pub examples: Vec<String>,
    /// The day the user's yes on a promotion card gave it a level. A habit
    /// the user approved replaces their `autopilot_autonomy` default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved: Option<String>,
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_' || b == b'.')
}

impl Habit {
    /// The general habit: `cleanup-merged`'s condition (merged, nothing to
    /// lose, idle a day or more), at `ask`.
    pub fn seed(today: &str) -> Habit {
        Habit {
            id: SEED_ID.into(),
            about: ABOUT_CLEANUP.into(),
            when: When::parse_yaml("{pr: merged, uncommitted: 0, untracked: 0, ignored: 0, unpushed: 0, busy_panes: 0, idle_days: \">=1\"}")
                .expect("the seed's when is valid"),
            act: Do::DeleteWorktree,
            level: HabitLevel::Ask,
            status: Status::Active,
            observed: today.into(),
            sources: Vec::new(),
            origin: Origin::General,
            evidence: Evidence { since: today.into(), ..Evidence::default() },
            examples: Vec::new(),
            approved: None,
        }
    }

    pub fn active(&self) -> bool {
        self.status == Status::Active
    }

    fn add_example(&mut self, branch: &str) {
        if branch.is_empty() || self.examples.iter().any(|e| e == branch) {
            return;
        }
        self.examples.push(branch.into());
        if self.examples.len() > tuning::EXAMPLES_CAP {
            self.examples.remove(0);
        }
    }

    fn fresh_sources(&self) -> &[String] {
        &self.sources[self.evidence.fresh_from.min(self.sources.len())..]
    }
}

// MARK: a file of habits

/// One file: a project's habits or the global ones.
#[derive(Clone, Debug, PartialEq)]
pub struct Book {
    pub key: String,
    pub habits: Vec<Habit>,
    /// Entries that did not parse, kept as written so saving loses nothing,
    /// with why.
    pub invalid: Vec<(Yaml, String)>,
    /// What loading changed: a level held at the core's grant or at `ask`.
    pub notes: Vec<String>,
    /// Levels the file said and loading held lower, by id.
    pub written: HashMap<String, HabitLevel>,
    /// The highest level the core granted each habit (`.granted.json`).
    caps: HashMap<String, HabitLevel>,
}

/// A change to a habit, in words for the audit and First Mate's line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub id: String,
    pub from: HabitLevel,
    pub to: HabitLevel,
    pub why: Text,
}

impl Change {
    pub fn line(&self) -> String {
        self.text().en
    }

    /// The line in both languages, for First Mate's timeline and the brief.
    pub fn text(&self) -> Text {
        let up = self.to > self.from;
        Text::new(
            format!("Habit {} {} from {} to {}: {}", self.id, if up { "up" } else { "down" }, self.from.as_str(), self.to.as_str(), self.why.en),
            format!("习惯 {} 从 {} {}到 {}：{}", self.id, self.from.as_str(), if up { "升" } else { "降" }, self.to.as_str(), self.why.get(Lang::Zh)),
        )
    }
}

impl Book {
    pub fn empty(key: &str) -> Book {
        Book { key: key.into(), habits: Vec::new(), invalid: Vec::new(), notes: Vec::new(), written: HashMap::new(), caps: HashMap::new() }
    }

    /// The global book as it starts: the general habit, granted at `ask`.
    pub fn seeded(today: &str) -> Book {
        let mut b = Book::empty(GLOBAL);
        let seed = Habit::seed(today);
        b.caps.insert(seed.id.clone(), seed.level);
        b.habits.push(seed);
        b
    }

    /// Read a file. `granted`: the levels the core granted this file's
    /// habits; a habit the core never granted anything starts at `observe`.
    pub fn parse(key: &str, text: &str, granted: &HashMap<String, HabitLevel>) -> Book {
        let mut b = Book::empty(key);
        b.caps = granted.clone();
        let root: Yaml = match serde_yaml::from_str(text) {
            Ok(Yaml::Null) => return b,
            Ok(v) => v,
            Err(e) => {
                b.invalid.push((Yaml::String(text.into()), format!("not YAML: {e}")));
                return b;
            }
        };
        let Yaml::Sequence(entries) = root else {
            b.invalid.push((root, "a habits file is a list of habits".into()));
            return b;
        };
        for (i, entry) in entries.into_iter().enumerate() {
            let at = |m: String| format!("habit {}: {m}", i + 1);
            let mut h: Habit = match serde_yaml::from_value(entry.clone()) {
                Ok(h) => h,
                Err(e) => {
                    b.invalid.push((entry, at(e.to_string())));
                    continue;
                }
            };
            if !valid_id(&h.id) {
                b.invalid.push((entry, at(format!("id `{}` must be lowercase letters, digits, `-`, `_` or `.`", h.id))));
                continue;
            }
            if b.habits.iter().any(|x| x.id == h.id) {
                b.invalid.push((entry, at(format!("id `{}` is used twice", h.id))));
                continue;
            }
            let cap = b.cap(&h.id);
            let as_written = h.level;
            if h.level > cap {
                b.notes.push(format!("{}: `{}` in the file was not granted by the core; held at {} until the user confirms it", h.id, h.level.as_str(), cap.as_str()));
                h.level = cap;
            }
            if h.level == HabitLevel::Auto && h.when.admits_risk() {
                b.notes.push(format!("{}: its `when` admits {}, so it cannot be auto; held at ask", h.id, h.when.risky_facts().join(", ")));
                h.level = HabitLevel::Ask;
                b.caps.insert(h.id.clone(), HabitLevel::Ask);
            }
            if h.level != as_written {
                b.written.insert(h.id.clone(), as_written);
            }
            b.habits.push(h);
        }
        b
    }

    pub fn to_yaml(&self) -> String {
        // A level raised by hand and not yet confirmed stays in the file as
        // written: saving must not answer the confirmation card for the user.
        let mut seq: Vec<Yaml> = self
            .habits
            .iter()
            .filter_map(|h| match self.written.get(&h.id) {
                Some(w) => serde_yaml::to_value(Habit { level: *w, ..h.clone() }).ok(),
                None => serde_yaml::to_value(h).ok(),
            })
            .collect();
        seq.extend(self.invalid.iter().map(|(raw, _)| raw.clone()));
        if seq.is_empty() {
            return "[]\n".into();
        }
        serde_yaml::to_string(&Yaml::Sequence(seq)).unwrap_or_default()
    }

    fn cap(&self, id: &str) -> HabitLevel {
        self.caps.get(id).copied().unwrap_or(HabitLevel::Observe)
    }

    /// The habit's level as the core honours it: never above what the core
    /// granted, never `auto` for a `when` that admits risk.
    pub fn level(&self, h: &Habit) -> HabitLevel {
        let l = h.level.min(self.cap(&h.id));
        if l == HabitLevel::Auto && h.when.admits_risk() {
            HabitLevel::Ask
        } else {
            l
        }
    }

    pub fn get(&self, id: &str) -> Option<&Habit> {
        self.habits.iter().find(|h| h.id == id)
    }

    fn index(&self, id: &str) -> Option<usize> {
        self.habits.iter().position(|h| h.id == id)
    }

    /// The grants to persist: one per habit in the book.
    pub fn grants(&self) -> BTreeMap<String, HabitLevel> {
        self.habits.iter().map(|h| (h.id.clone(), self.level(h))).collect()
    }

    /// Down one level, never up. Returns the change.
    fn demote(&mut self, id: &str, why: Text) -> Option<Change> {
        let i = self.index(id)?;
        let from = self.level(&self.habits[i]);
        let to = from.down();
        let h = &mut self.habits[i];
        h.level = to;
        h.evidence.streak = 0;
        h.evidence.expired_in_row = 0;
        h.evidence.fresh_from = h.sources.len();
        self.caps.insert(id.to_string(), to);
        // A demotion overrules a raise still waiting for the user's confirmation.
        self.written.remove(id);
        (to != from).then(|| Change { id: id.into(), from, to, why })
    }

    /// A card about this habit approved (one decision, however many
    /// worktrees it covered).
    pub fn approved(&mut self, id: &str, branches: &[String]) {
        if let Some(i) = self.index(id) {
            let h = &mut self.habits[i];
            h.evidence.approved += 1;
            h.evidence.streak += 1;
            h.evidence.expired_in_row = 0;
            for b in branches {
                h.add_example(b);
            }
        }
    }

    /// The user said no on a card of this habit: one level down.
    pub fn rejected(&mut self, id: &str) -> Option<Change> {
        let i = self.index(id)?;
        self.habits[i].evidence.rejected += 1;
        self.demote(id, Text::new("the user said no on its card", "你在它的卡片上选了不"))
    }

    /// A further no in a batch that already took the habit down: counted,
    /// not demoted again (one rejection per card).
    pub fn note_rejected(&mut self, id: &str) {
        if let Some(i) = self.index(id) {
            self.habits[i].evidence.rejected += 1;
        }
    }

    /// The user undid an automatic deletion of this habit's.
    pub fn undone(&mut self, id: &str, branch: &str) -> Option<Change> {
        let i = self.index(id)?;
        self.habits[i].evidence.undone += 1;
        self.demote(id, Text::new(format!("the user checked {branch} out again after First Mate deleted it"), format!("First Mate 删掉 {branch} 后你又把它检出了")))
    }

    /// One of this habit's cards expired unanswered (`brief::expire`):
    /// counted as ignored; the second in a row takes it down.
    pub fn expired(&mut self, id: &str) -> Option<Change> {
        let i = self.index(id)?;
        let e = &mut self.habits[i].evidence;
        e.ignored += 1;
        e.expired_in_row += 1;
        if e.expired_in_row >= tuning::EXPIRIES_TO_DEMOTE {
            return self.demote(id, Text::new("two of its cards went unanswered", "它的卡片连续两次没人回"));
        }
        None
    }

    /// The user turned a promotion down: it waits for fresh evidence.
    pub fn declined(&mut self, id: &str) {
        if let Some(i) = self.index(id) {
            let h = &mut self.habits[i];
            h.evidence.fresh_from = h.sources.len();
            h.evidence.streak = 0;
        }
    }

    /// Count removals by the user or an agent whose last facts match a
    /// deletion habit as `manual` evidence, each once. `applies`: whether a
    /// record is about this book's repo. Then `observe → suggest` for a habit
    /// whose fresh evidence passes the gates — the one move up the core
    /// makes alone, since `suggest` only mentions.
    pub fn count(&mut self, records: &[Record], applies: impl Fn(&Record) -> bool) -> Vec<Change> { self.count_with_n(records, applies, tuning::N) }
    pub fn count_with_n(&mut self, records: &[Record], applies: impl Fn(&Record) -> bool, n: usize) -> Vec<Change> {
        let by_id: HashMap<&str, &Record> = records.iter().map(|r| (r.id.as_str(), r)).collect();
        for r in records.iter().filter(|r| is_manual_removal(r) && applies(r)) {
            let Some(facts) = record_facts(r) else { continue };
            for h in self.habits.iter_mut().filter(|h| h.active() && h.act == Do::DeleteWorktree) {
                if h.sources.contains(&r.id) || !h.when.matches(&facts) {
                    continue;
                }
                h.evidence.manual += 1;
                h.sources.push(r.id.clone());
                h.add_example(&r.branch);
            }
        }
        let mut changes = Vec::new();
        for i in 0..self.habits.len() {
            let h = &self.habits[i];
            if !h.active() || h.act != Do::DeleteWorktree || self.level(h) != HabitLevel::Observe || !gates_pass_n(h.fresh_sources(), &by_id, n.clamp(2,10)) {
                continue;
            }
            let id = h.id.clone();
            let h = &mut self.habits[i];
            h.level = HabitLevel::Suggest;
            h.evidence.fresh_from = h.sources.len();
            self.caps.insert(id.clone(), HabitLevel::Suggest);
            changes.push(Change {
                id,
                from: HabitLevel::Observe,
                to: HabitLevel::Suggest,
                why: Text::new(
                    format!("the user did it {}+ times, on {}+ days, in {}+ worktrees", n, tuning::MIN_DAYS, tuning::MIN_WORKTREES),
                    format!("你在 {}+ 天、{}+ 个 worktree 里做过 {}+ 次", tuning::MIN_DAYS, tuning::MIN_WORKTREES, n),
                ),
            });
        }
        changes
    }

    /// Habits ready to be offered one level up, and the level: `suggest`
    /// with N fresh matching actions (gated as above), `ask` with M
    /// approvals in a row and a `when` safe enough for `auto`.
    pub fn offers_due(&self, records: &[Record]) -> Vec<(String, HabitLevel)> { self.offers_with_thresholds(records, tuning::N, tuning::M) }
    pub fn offers_with_thresholds(&self, records: &[Record], n: usize, m: u32) -> Vec<(String, HabitLevel)> {
        let by_id: HashMap<&str, &Record> = records.iter().map(|r| (r.id.as_str(), r)).collect();
        self.habits
            .iter()
            .filter(|h| h.active() && h.act == Do::DeleteWorktree)
            .filter_map(|h| match self.level(h) {
                HabitLevel::Suggest if gates_pass_n(h.fresh_sources(), &by_id, n.clamp(2,10)) => Some((h.id.clone(), HabitLevel::Ask)),
                HabitLevel::Ask if h.evidence.streak >= m.clamp(3,20) && !h.when.admits_risk() => Some((h.id.clone(), HabitLevel::Auto)),
                _ => None,
            })
            .collect()
    }

    /// Apply the user's yes. The only path to `ask` or `auto`.
    pub fn promote(&mut self, g: Grant, today: &str) -> Result<Change, String> {
        if g.key != self.key {
            return Err(format!("grant for {} applied to {}", g.key, self.key));
        }
        if g.confirm {
            return Err("a confirmation is not a promotion".into());
        }
        let i = self.index(&g.id).ok_or_else(|| format!("no habit {}", g.id))?;
        let from = self.level(&self.habits[i]);
        if from.up() != Some(g.level) {
            return Err(format!("{} is at {}; a grant of {} skips or repeats a level", g.id, from.as_str(), g.level.as_str()));
        }
        let h = &mut self.habits[i];
        if g.level == HabitLevel::Auto && h.when.admits_risk() {
            return Err(format!("{}: its `when` admits {}, so it cannot be auto", g.id, h.when.risky_facts().join(", ")));
        }
        h.level = g.level;
        h.approved = Some(today.into());
        h.evidence.streak = 0;
        h.evidence.fresh_from = h.sources.len();
        self.caps.insert(g.id.clone(), g.level);
        Ok(Change { id: g.id, from, to: g.level, why: Text::new("the user said yes", "你同意了") })
    }

    /// The level a hand edit asks for, if the user is to be asked: what the
    /// file says, but never `auto` for a `when` that admits risk; None when
    /// that is no higher than what the core honours.
    pub fn confirm_target(&self, h: &Habit) -> Option<HabitLevel> {
        let written = *self.written.get(&h.id)?;
        let target = if written == HabitLevel::Auto && h.when.admits_risk() { HabitLevel::Ask } else { written };
        (target > self.level(h)).then_some(target)
    }

    /// Hand-raised levels waiting for the user: (id, asked-for level, honoured level).
    pub fn pending_confirmations(&self) -> Vec<(String, HabitLevel, HabitLevel)> {
        self.habits.iter().filter(|h| h.active()).filter_map(|h| self.confirm_target(h).map(|t| (h.id.clone(), t, self.level(h)))).collect()
    }

    /// The user said yes to a hand-raised level: grant it (more than one
    /// level at once is fine — they asked for exactly this).
    pub fn confirm(&mut self, g: Grant, today: &str) -> Result<Change, String> {
        if g.key != self.key || !g.confirm {
            return Err("not a confirmation of this file".into());
        }
        let i = self.index(&g.id).ok_or_else(|| format!("no habit {}", g.id))?;
        let target = self.confirm_target(&self.habits[i]);
        if target != Some(g.level) {
            return Err(format!("{}: the file no longer asks for {}", g.id, g.level.as_str()));
        }
        let from = self.level(&self.habits[i]);
        let h = &mut self.habits[i];
        h.level = g.level;
        h.approved = Some(today.into());
        h.evidence.streak = 0;
        h.evidence.fresh_from = h.sources.len();
        self.caps.insert(g.id.clone(), g.level);
        self.written.remove(&g.id);
        Ok(Change { id: g.id, from, to: g.level, why: Text::new("the user confirmed the level written in the file", "你确认了文件里写的档位") })
    }

    /// Write the habit an inventory answer names (`inventory`), granted by
    /// that answer. New: added as given. Already there (the inventory
    /// redone): its `when`, `do` and level follow the new answer, and the
    /// answer is added to its evidence — one decision, however many
    /// worktrees it covered. A habit already above the grant (a deletion
    /// habit since raised to `auto`) keeps its level when the answer is
    /// delete again; keep and ask-me-each-time take it down.
    pub(super) fn adopt_proposal(&mut self, h: Habit, g: Grant, today: &str) -> Result<Option<Change>, String> {
        if g.key != self.key || g.id != h.id || g.level != h.level || g.confirm || h.level > HabitLevel::Ask {
            return Err("proposal grant mismatch".into());
        }
        // An edited condition starts with fresh evidence and the level named
        // on this card, even if the previous version had earned auto.
        self.habits.retain(|old| old.id != h.id);
        self.adopt(h, g, today)
    }

    pub fn adopt(&mut self, h: Habit, g: Grant, today: &str) -> Result<Option<Change>, String> {
        if g.key != self.key || g.id != h.id || g.level != h.level || g.confirm {
            return Err(format!("grant for {}/{} does not cover {}/{}", g.key, g.id, self.key, h.id));
        }
        if h.level == HabitLevel::Auto {
            return Err(format!("{}: an inventory answer never grants auto", h.id));
        }
        let Some(i) = self.index(&h.id) else {
            self.caps.insert(h.id.clone(), h.level);
            self.written.remove(&h.id);
            self.habits.push(h);
            return Ok(None);
        };
        let from = self.level(&self.habits[i]);
        let keeps_level = h.act == Do::DeleteWorktree && self.habits[i].act == Do::DeleteWorktree && from > h.level;
        let to = if keeps_level { from } else { h.level };
        let old = &mut self.habits[i];
        old.when = h.when;
        old.act = h.act;
        old.about = h.about;
        old.level = to;
        old.status = Status::Active;
        old.evidence.approved += h.evidence.approved;
        old.evidence.decisions += h.evidence.decisions;
        old.evidence.streak = if h.evidence.approved > 0 && h.act == Do::DeleteWorktree { old.evidence.streak + h.evidence.approved } else { 0 };
        old.evidence.expired_in_row = 0;
        for e in h.examples {
            old.add_example(&e);
        }
        if h.approved.is_some() || to != from {
            old.approved = Some(today.into());
        }
        self.caps.insert(h.id.clone(), to);
        self.written.remove(&h.id);
        Ok((to != from).then(|| Change { id: h.id, from, to, why: Text::new("the user answered the inventory card", "你回答了盘点卡") }))
    }

    /// Keep a habit in place, never matched again: an answer replaced it.
    /// Returns whether it was active.
    pub fn supersede(&mut self, id: &str) -> bool {
        match self.index(id) {
            Some(i) if self.habits[i].active() => {
                self.habits[i].status = Status::Superseded;
                true
            }
            _ => false,
        }
    }

    /// The user said no to a hand-raised level: the next save writes the
    /// granted level back into the file. Returns (written, granted).
    pub fn revert(&mut self, id: &str) -> Option<(HabitLevel, HabitLevel)> {
        let written = self.written.remove(id)?;
        let h = self.get(id)?;
        Some((written, self.level(h)))
    }
}

fn is_manual_removal(r: &Record) -> bool {
    r.kind == observations::kind::WORKTREE_REMOVED && (r.by == "user" || r.by == "agent")
}

fn record_facts(r: &Record) -> Option<Facts> {
    let v = r.fields.get("facts")?;
    if v.is_null() {
        return None;
    }
    serde_json::from_value(v.clone()).ok()
}

/// N actions, on enough distinct days, in enough distinct worktrees. Only
/// sources still in the log count: evidence older than the log's
/// retention has aged out.
fn gates_pass_n(sources: &[String], by_id: &HashMap<&str, &Record>, n: usize) -> bool {
    let live: Vec<&&Record> = sources.iter().filter_map(|s| by_id.get(s.as_str())).collect();
    let days: BTreeSet<&str> = live.iter().map(|r| r.at.get(..10).unwrap_or(&r.at)).collect();
    let worktrees: BTreeSet<&str> = live.iter().map(|r| r.worktree.as_str()).collect();
    live.len() >= n && days.len() >= tuning::MIN_DAYS && worktrees.len() >= tuning::MIN_WORKTREES
}

// MARK: promotion cards

/// Permission to raise one habit: one level (`Book::promote`), or to the
/// level the user wrote in the file (`Book::confirm`, `confirm` set). Only
/// `Offers::answer` makes one, from the user's yes on a card the core raised.
#[derive(Debug, PartialEq, Eq)]
pub struct Grant {
    pub key: String,
    pub id: String,
    pub level: HabitLevel,
    pub confirm: bool,
    _only_from_a_card: (),
}

impl Grant {
    /// The user's answer on an inventory card (`inventory::Cards::answer`,
    /// the only caller): the answer is the consent (D6), so the habit it
    /// writes is granted the level that answer names — at most `ask`.
    pub(super) fn from_inventory_card(key: &str, id: &str, level: HabitLevel) -> Grant {
        Grant { key: key.into(), id: id.into(), level: level.min(HabitLevel::Ask), confirm: false, _only_from_a_card: () }
    }
}

/// A card the core put up about a habit's level: a promotion, or the
/// confirmation of a level written by hand.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Offer {
    pub key: String,
    pub id: String,
    pub level: HabitLevel,
    pub payload: String,
    pub confirm: bool,
}

impl Offer {
    pub fn options(&self) -> Vec<String> {
        if self.confirm {
            vec![confirm_label(self.level), PUT_IT_BACK.into()]
        } else {
            vec![yes_label(self.level), NOT_YET.into()]
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum OfferAnswer {
    Accepted(Grant),
    Declined { key: String, id: String, confirm: bool },
}

#[derive(Default)]
pub struct Offers {
    open: HashMap<String, Offer>,
}

impl Offers {
    /// Record a card about to go up; its payload, which carries a nonce so
    /// no other card can stand in for it: `habit.promote:<key>/<id>:<level>:<nonce>`.
    pub fn raise(&mut self, key: &str, id: &str, level: HabitLevel, nonce: &str) -> Offer {
        self.raise_kind(key, id, level, nonce, false)
    }

    /// A confirmation card for a level written by hand:
    /// `habit.confirm:<key>/<id>:<level>:<nonce>`.
    pub fn raise_confirm(&mut self, key: &str, id: &str, level: HabitLevel, nonce: &str) -> Offer {
        self.raise_kind(key, id, level, nonce, true)
    }

    fn raise_kind(&mut self, key: &str, id: &str, level: HabitLevel, nonce: &str, confirm: bool) -> Offer {
        let prefix = if confirm { CONFIRM_PREFIX } else { PROMOTE_PREFIX };
        let payload = format!("{prefix}{key}/{id}:{}:{nonce}", level.as_str());
        let o = Offer { key: key.into(), id: id.into(), level, payload: payload.clone(), confirm };
        self.open.insert(payload, o.clone());
        o
    }

    pub fn pending(&self, key: &str, id: &str) -> bool {
        self.open.values().any(|o| o.key == key && o.id == id)
    }

    pub fn payloads(&self) -> Vec<String> {
        self.open.keys().cloned().collect()
    }

    pub fn contains(&self, payload: &str) -> bool {
        self.open.contains_key(payload)
    }

    pub fn clear(&mut self) {
        self.open.clear();
    }

    /// Take an offer down unanswered (it expired): no grant, no decline.
    pub fn withdraw(&mut self, payload: &str) -> Option<Offer> {
        self.open.remove(payload)
    }

    /// The user's answer to a card (None: dismissed). Only the yes option
    /// on an offer this core raised makes a `Grant`.
    pub fn answer(&mut self, payload: &str, option: Option<&str>) -> Option<OfferAnswer> {
        let o = self.open.remove(payload)?;
        if option == o.options().first().map(String::as_str) {
            Some(OfferAnswer::Accepted(Grant { key: o.key, id: o.id, level: o.level, confirm: o.confirm, _only_from_a_card: () }))
        } else {
            Some(OfferAnswer::Declined { key: o.key, id: o.id, confirm: o.confirm })
        }
    }
}

pub fn yes_label(level: HabitLevel) -> String {
    format!("{YES_PREFIX}{}", level.as_str())
}

pub fn confirm_label(level: HabitLevel) -> String {
    format!("{YES_PREFIX}keep {}", level.as_str())
}

/// The confirmation card's text: the habit, the level it is held at, the
/// level the file asks for, and the evidence.
pub fn confirm_message(h: &Habit, to: HabitLevel, from: HabitLevel, file: &Path) -> String {
    let e = &h.evidence;
    let mut m = format!(
        "First Mate: the habits file sets \"{}\" to {}, but the core only granted {}. Keep {}?",
        h.id,
        to.as_str(),
        from.as_str(),
        to.as_str()
    );
    m += &format!("\nWhen: {}", describe_when(&h.when));
    m += &format!("\nEvidence: {} approved, {} rejected, {} by hand, {} ignored (since {})", e.approved, e.rejected, e.manual, e.ignored, e.since);
    if !h.examples.is_empty() {
        m += &format!("\nExamples: {}", h.examples.join(", "));
    }
    m += &format!("\nNow: {} (file: {}) · until you answer: {}", to.as_str(), file.display(), from.as_str());
    m
}

/// The promotion card's text: the evidence and examples behind it.
pub fn offer_message(h: &Habit, to: HabitLevel, from: HabitLevel) -> String {
    let e = &h.evidence;
    let mut m = match to {
        HabitLevel::Auto => format!("First Mate: you approved \"{}\" {} times in a row. Let me do it on my own and tell you afterwards?", h.id, e.streak),
        _ => format!("First Mate: you keep doing \"{}\" yourself. Shall I ask you first, with one tap, from now on?", h.id),
    };
    m += &format!("\nWhen: {}", describe_when(&h.when));
    m += &format!("\nEvidence: {} approved, {} rejected, {} by hand, {} ignored (since {})", e.approved, e.rejected, e.manual, e.ignored, e.since);
    if !h.examples.is_empty() {
        m += &format!("\nExamples: {}", h.examples.join(", "));
    }
    m += &format!("\nNow: {} → {}", from.as_str(), to.as_str());
    m
}

pub fn describe_when(w: &When) -> String {
    if let Some(prose) = &w.1 { return prose.clone(); }
    w.0.iter()
        .map(|(f, c)| {
            let v = match c.to_yaml() {
                Yaml::String(s) => s,
                Yaml::Number(n) => n.to_string(),
                Yaml::Bool(b) => b.to_string(),
                _ => String::new(),
            };
            format!("{}: {v}", f.as_str())
        })
        .collect::<Vec<_>>()
        .join(", ")
}

// MARK: precedence

/// What sits above a habit in a repo: its own `.seahelm/automations.yml`
/// (written by a person and shared) caps every habit there, `deny` beating
/// anything; the user's `autopilot_autonomy` default caps a habit the user
/// never approved, and an approved habit's level replaces it — except
/// `deny`, which still silences it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Precedence {
    /// The strictest `delete_worktree` level among the enabled rules of the
    /// repo's own file; None without a file or without such a rule.
    pub repo_cap: Option<RuleLevel>,
    /// The user's `delete_worktree` default.
    pub user_default: RuleLevel,
}

impl Precedence {
    pub fn effective(&self, book: &Book, h: &Habit) -> HabitLevel {
        let mut l = book.level(h);
        if h.approved.is_none() || self.user_default == RuleLevel::Deny {
            l = l.capped_by(self.user_default);
        }
        if let Some(cap) = self.repo_cap {
            l = l.capped_by(cap);
        }
        l
    }
}

/// The repo cap from a repo's rules: the strictest `delete_worktree` level
/// a rule names. None when the repo has no file of its own: the built-in
/// rules are seahelm's, not a person's, and do not cap habits.
pub fn repo_cap(config: &super::rules::Config, has_own_file: bool) -> Option<RuleLevel> {
    if !has_own_file {
        return None;
    }
    config.rules.iter().filter(|r| r.enabled).filter_map(|r| r.autonomy.get(&super::rules::Action::DeleteWorktree).copied()).max()
}

/// The habit that decides a worktree, and at what level.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Decision {
    pub key: String,
    pub id: String,
    pub level: HabitLevel,
}

/// Match measured facts against the books (the repo's first, then the
/// global one). A matching `keep` habit leaves the worktree alone; else the
/// deletion habit with the highest effective level decides (the repo's on
/// a tie).
pub fn decide(facts: &Facts, books: &[&Book], prec: &Precedence) -> Option<Decision> {
    let mut best: Option<Decision> = None;
    for b in books {
        for h in b.habits.iter().filter(|h| h.active() && h.when.matches(facts)) {
            match h.act {
                Do::Keep => return None,
                Do::DeleteWorktree => {
                    let level = prec.effective(b, h);
                    if best.as_ref().is_none_or(|d| level > d.level) {
                        best = Some(Decision { key: b.key.clone(), id: h.id.clone(), level });
                    }
                }
            }
        }
    }
    best
}

// MARK: the store

/// `first-mate/habits/`.
#[derive(Clone, Debug)]
pub struct Store {
    pub dir: PathBuf,
}

const GRANTED: &str = ".granted.json";
const SEAL: &str = ".granted.seal.json";

/// What `.granted.seal.json` holds.
enum Sealed {
    Intact(String),
    Missing,
    Broken,
}
const REPOS: &str = ".repos.json";
const HISTORY: &str = ".history";

impl Store {
    pub fn new(dir: PathBuf) -> Self {
        Store { dir }
    }

    pub fn default_dir() -> PathBuf {
        super::pane::dir().join("habits")
    }

    pub fn path(&self, key: &str) -> PathBuf {
        self.dir.join(format!("{key}.yml"))
    }

    fn granted_all(&self) -> BTreeMap<String, BTreeMap<String, HabitLevel>> {
        serde_json::from_str(&self.granted_text()).unwrap_or_default()
    }

    /// Compare `.granted.json` with the seal now (First Mate's tick), so a
    /// change shows even when nothing reads the grants for a while.
    pub fn check_grants(&self) {
        let _ = self.granted_text();
    }

    /// `.granted.json` as the core last wrote it. A file that differs (or is
    /// gone) is written back, and the change reported (`take_tamper_reports`).
    fn granted_text(&self) -> String {
        let _guard = seal::LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let path = self.dir.join(GRANTED);
        let on_disk = std::fs::read_to_string(&path).ok();
        let known = match seal::remembered(&path) {
            Some(k) => Some(k),
            None => match self.read_seal() {
                Sealed::Intact(t) => Some(t),
                Sealed::Missing => None,
                Sealed::Broken => {
                    // Nothing the seal says can be believed: start over from
                    // nothing, which only lowers levels, and say so once.
                    let _ = std::fs::create_dir_all(&self.dir);
                    let _ = write_atomic(&path, "{}");
                    self.write_seal("{}");
                    seal::report(
                        &self.dir,
                        Text::new(
                            format!(
                                "The seal on First Mate's granted habit levels ({}) was altered, so the core can no longer tell which levels you granted. \
                                 Every habit is back to observe: First Mate only watches until you approve a level again on a card.",
                                self.dir.join(SEAL).display()
                            ),
                            format!(
                                "First Mate 习惯授权档位的封印（{}）被改动过，core 已无法分辨哪些档位是你批准的。所有习惯退回 observe：在你再次在卡片上批准之前，First Mate 只观察。",
                                self.dir.join(SEAL).display()
                            ),
                        ),
                    );
                    return "{}".into();
                }
            },
        };
        match (known, on_disk) {
            (Some(k), Some(d)) if k == d => d,
            (Some(k), on_disk) => {
                let what = if on_disk.is_some() { "was changed by something other than the core" } else { "was deleted" };
                let what_zh = if on_disk.is_some() { "被 core 以外的东西改动了" } else { "被删除了" };
                let _ = std::fs::create_dir_all(&self.dir);
                let restored = write_atomic(&path, &k).is_ok();
                self.write_seal(&k);
                seal::report(
                    &self.dir,
                    Text::new(
                        format!(
                            "First Mate's granted habit levels ({}) {what}; {}. Levels only go up through a card you answer.",
                            path.display(),
                            if restored { "put back to the core's version" } else { "could not be put back — the core keeps using its own version" }
                        ),
                        format!(
                            "First Mate 的习惯授权档位（{}）{what_zh}；{}。档位只能通过你回答的卡片升高。",
                            path.display(),
                            if restored { "已恢复为 core 的版本" } else { "无法恢复，core 继续使用自己的版本" }
                        ),
                    ),
                );
                k
            }
            // Before the seal existed (an upgrade): the file as found is the
            // core's from here on.
            (None, Some(d)) => {
                self.write_seal(&d);
                d
            }
            (None, None) => String::new(),
        }
    }

    /// The seal on disk. One that does not match its own digest was altered
    /// too.
    fn read_seal(&self) -> Sealed {
        let Ok(text) = std::fs::read_to_string(self.dir.join(SEAL)) else { return Sealed::Missing };
        let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        match v.get("text").and_then(Value::as_str) {
            Some(t) if v.get("sha256").and_then(Value::as_str) == Some(seal::digest(t).as_str()) => Sealed::Intact(t.to_string()),
            _ => Sealed::Broken,
        }
    }

    fn write_seal(&self, text: &str) {
        seal::remember(&self.dir.join(GRANTED), text);
        let doc = json!({"sha256": seal::digest(text), "text": text});
        let _ = write_atomic(&self.dir.join(SEAL), &serde_json::to_string_pretty(&doc).unwrap_or_default());
    }

    /// A book from its file. The global one, before it was ever written, is
    /// the seed (not written: reading never writes).
    pub fn load(&self, key: &str, today: &str) -> Book {
        match std::fs::read_to_string(self.path(key)) {
            Ok(text) => {
                let granted: HashMap<String, HabitLevel> = self.granted_all().remove(key).unwrap_or_default().into_iter().collect();
                Book::parse(key, &text, &granted)
            }
            Err(_) if key == GLOBAL => Book::seeded(today),
            Err(_) => Book::empty(key),
        }
    }

    /// Write the global seed once: a user who deletes it from the file does
    /// not get it back.
    pub fn ensure_seed(&self, today: &str, now: f64) -> std::io::Result<bool> {
        if self.path(GLOBAL).exists() {
            return Ok(false);
        }
        self.save(&Book::seeded(today), now).map(|_| true)
    }

    /// Write a book, keeping the file it replaces under `.history/`, and its
    /// grants. A grant is never raised here beyond what the book honours.
    pub fn save(&self, book: &Book, now: f64) -> std::io::Result<()> {
        std::fs::create_dir_all(self.dir.join(HISTORY))?;
        let path = self.path(&book.key);
        let text = book.to_yaml();
        if let Ok(old) = std::fs::read_to_string(&path) {
            if old == text {
                return self.write_grants(book);
            }
            let ms = (now * 1000.0) as u64;
            let mut dest = self.dir.join(HISTORY).join(format!("{}.{ms}.yml", book.key));
            let mut n = 1;
            while dest.exists() {
                dest = self.dir.join(HISTORY).join(format!("{}.{ms}-{n}.yml", book.key));
                n += 1;
            }
            std::fs::write(dest, old)?;
        }
        write_atomic(&path, &text)?;
        self.write_grants(book)
    }

    fn write_grants(&self, book: &Book) -> std::io::Result<()> {
        let mut all = self.granted_all();
        all.insert(book.key.clone(), book.grants());
        let text = serde_json::to_string_pretty(&all).unwrap_or_default();
        let _guard = seal::LOCK.lock().unwrap_or_else(|e| e.into_inner());
        write_atomic(&self.dir.join(GRANTED), &text)?;
        self.write_seal(&text);
        Ok(())
    }

    /// Put back the file as it was before the last write. Grants only come
    /// down with it: an undo never raises a level. (`seahelm habit undo`
    /// and "撤销" arrive with phase 6.)
    #[allow(dead_code)]
    pub fn undo(&self, key: &str, today: &str) -> std::io::Result<bool> {
        let prefix = format!("{key}.");
        let mut versions: Vec<PathBuf> = std::fs::read_dir(self.dir.join(HISTORY))
            .map(|d| d.filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with(&prefix))).collect())
            .unwrap_or_default();
        versions.sort_by_key(|p| history_stamp(p, &prefix));
        let Some(last) = versions.pop() else { return Ok(false) };
        let text = std::fs::read_to_string(&last)?;
        let current = self.load(key, today);
        let mut restored = Book::parse(key, &text, &current.caps);
        restored.notes.clear();
        write_atomic(&self.path(key), &text)?;
        // Each restored habit's grant is the lower of the two.
        for h in &restored.habits {
            let now_level = current.get(&h.id).map(|c| current.level(c)).unwrap_or(HabitLevel::Observe);
            let l = restored.level(h).min(now_level);
            restored.caps.insert(h.id.clone(), l);
        }
        std::fs::remove_file(&last)?;
        self.write_grants(&restored)?;
        Ok(true)
    }

    pub fn remember_repo(&self, key: &str, repo: &str) {
        let mut all = self.repos();
        if all.get(key).map(String::as_str) == Some(repo) {
            return;
        }
        all.insert(key.into(), repo.into());
        let _ = std::fs::create_dir_all(&self.dir);
        let _ = write_atomic(&self.dir.join(REPOS), &serde_json::to_string_pretty(&all).unwrap_or_default());
    }

    pub fn repos(&self) -> BTreeMap<String, String> {
        std::fs::read_to_string(self.dir.join(REPOS)).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
    }

    /// Every book on disk (the global one first, seeded if never written).
    pub fn all(&self, today: &str) -> Vec<Book> {
        let mut keys: Vec<String> = std::fs::read_dir(&self.dir)
            .map(|d| {
                d.filter_map(|e| e.ok())
                    .filter_map(|e| e.file_name().to_str().and_then(|n| n.strip_suffix(".yml")).map(str::to_string))
                    .filter(|k| !k.starts_with('.') && k != GLOBAL)
                    .collect()
            })
            .unwrap_or_default();
        keys.sort();
        let mut out = vec![self.load(GLOBAL, today)];
        out.extend(keys.iter().map(|k| self.load(k, today)));
        out
    }
}

#[allow(dead_code)]
fn history_stamp(p: &Path, prefix: &str) -> (u64, u64) {
    let name = p.file_name().and_then(|n| n.to_str()).unwrap_or_default();
    let stem = name.strip_prefix(prefix).and_then(|s| s.strip_suffix(".yml")).unwrap_or_default();
    let (ms, n) = stem.split_once('-').unwrap_or((stem, "0"));
    (ms.parse().unwrap_or(0), n.parse().unwrap_or(0))
}

/// What the core last wrote to each `.granted.json`, for the process: every
/// `Store` (First Mate's, the sweep thread's, `habits.list`'s) checks
/// against the same memory.
mod seal {
    use std::collections::HashMap;
    use std::path::{Path, PathBuf};
    use std::sync::{Mutex, OnceLock};

    use sha2::{Digest, Sha256};

    use super::Text;

    /// One check-and-restore at a time.
    pub static LOCK: Mutex<()> = Mutex::new(());

    fn known() -> &'static Mutex<HashMap<PathBuf, String>> {
        static K: OnceLock<Mutex<HashMap<PathBuf, String>>> = OnceLock::new();
        K.get_or_init(Default::default)
    }

    fn reports() -> &'static Mutex<Vec<(PathBuf, Text)>> {
        static R: OnceLock<Mutex<Vec<(PathBuf, Text)>>> = OnceLock::new();
        R.get_or_init(Default::default)
    }

    pub fn remembered(path: &Path) -> Option<String> {
        known().lock().unwrap_or_else(|e| e.into_inner()).get(path).cloned()
    }

    pub fn remember(path: &Path, text: &str) {
        known().lock().unwrap_or_else(|e| e.into_inner()).insert(path.to_path_buf(), text.to_string());
    }

    /// A core that just started: nothing in memory.
    #[cfg(test)]
    pub fn forget(path: &Path) {
        known().lock().unwrap_or_else(|e| e.into_inner()).remove(path);
    }

    pub fn digest(text: &str) -> String {
        Sha256::digest(text.as_bytes()).iter().map(|b| format!("{b:02x}")).collect()
    }

    pub fn report(dir: &Path, text: Text) {
        eprintln!("seahelm-core: security: {}", text.en);
        reports().lock().unwrap_or_else(|e| e.into_inner()).push((dir.to_path_buf(), text));
    }

    /// Reports for one habits directory (None: all of them).
    pub fn take(dir: Option<&Path>) -> Vec<Text> {
        let mut all = reports().lock().unwrap_or_else(|e| e.into_inner());
        let (mine, rest): (Vec<_>, Vec<_>) = std::mem::take(&mut *all).into_iter().partition(|(d, _)| dir.is_none_or(|x| x == d));
        *all = rest;
        mine.into_iter().map(|(_, t)| t).collect()
    }
}

/// Changes to `.granted.json` the core caught and undid since last asked,
/// for First Mate to tell the user.
pub fn take_tamper_reports(dir: Option<&Path>) -> Vec<Text> {
    seal::take(dir)
}

fn write_atomic(path: &Path, text: &str) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path)
}

/// A repo's file name: its directory's name and a hash of its path, so two
/// checkouts called `app` do not share habits. FNV-1a: stable across Rust
/// versions, unlike `DefaultHasher`.
pub fn repo_key(repo: &str) -> String {
    let path = observations::norm(repo);
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in path.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    let name: String = Path::new(&path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("repo")
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c.to_ascii_lowercase() } else { '-' })
        .take(40)
        .collect();
    format!("{name}-{:08x}", (h ^ (h >> 32)) as u32)
}

// MARK: habits.list

/// `habits.list {repo?}`: every book (or one repo's and the global one),
/// each habit with the level the core honours and, for a repo, the
/// effective level after its rules and the user's default. Read-only.
pub fn list_json(store: &Store, repo: Option<&str>, today: &str, prec_for: impl Fn(&str) -> Precedence) -> Value {
    let repos = store.repos();
    let books = match repo {
        Some(r) => {
            let key = repo_key(r);
            vec![store.load(GLOBAL, today), store.load(&key, today)]
        }
        None => store.all(today),
    };
    let out: Vec<Value> = books
        .iter()
        .map(|b| {
            let repo_path = if b.key == GLOBAL { None } else { repo.map(str::to_string).or_else(|| repos.get(&b.key).cloned()) };
            let prec = repo_path.as_deref().map(&prec_for);
            let habits: Vec<Value> = b
                .habits
                .iter()
                .map(|h| {
                    let mut v = serde_json::to_value(h).unwrap_or(Value::Null);
                    v["level"] = json!(b.level(h).as_str());
                    if let Some(w) = b.written.get(&h.id) {
                        v["written_level"] = json!(w.as_str());
                    }
                    if let Some(t) = b.confirm_target(h) {
                        v["awaiting_confirmation"] = json!(t.as_str());
                    }
                    v["can_be_auto"] = json!(!h.when.admits_risk());
                    if let Some(p) = &prec {
                        v["effective_level"] = json!(p.effective(b, h).as_str());
                    }
                    v
                })
                .collect();
            json!({
                "file": store.path(&b.key),
                "key": b.key,
                "repo": repo_path,
                "habits": habits,
                "invalid": b.invalid.iter().map(|(_, why)| why.clone()).collect::<Vec<_>>(),
                "notes": b.notes,
            })
        })
        .collect();
    json!({"books": out, "dir": store.dir})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::first_mate::observations::{By, Record};

    #[test]
    fn at_risk_is_derived_and_the_safety_rule_knows_it() {
        let base = Facts { pr: Some("merged".into()), unpushed: Some(0), ..Facts::default() };
        assert_eq!(at_risk(&base), Some(false));
        for f in [Facts { changed: 1, ..base.clone() }, Facts { untracked: 1, ..base.clone() }, Facts { ignored: 1, ..base.clone() }, Facts { unpushed: Some(2), ..base.clone() }] {
            assert_eq!(at_risk(&f), Some(true), "{f:?}");
        }
        let unknown = Facts { unpushed: None, ..base.clone() };
        assert_eq!(at_risk(&unknown), None, "unknown is not zero");
        assert_eq!(at_risk(&Facts { changed: 1, ..unknown.clone() }), Some(true));

        let yes = When::parse_yaml("{pr: merged, at_risk: true}").unwrap();
        let no = When::parse_yaml("{pr: merged, at_risk: false, busy_panes: 0}").unwrap();
        assert!(yes.matches(&Facts { ignored: 1, ..base.clone() }) && !yes.matches(&base) && !yes.matches(&unknown));
        assert!(no.matches(&base) && !no.matches(&unknown) && !no.matches(&Facts { changed: 1, ..base.clone() }));
        assert!(When::parse_yaml("{at_risk: 1}").is_err());

        // true admits risk; false pins the four work facts, busy panes still count.
        assert_eq!(yes.risky_facts(), vec!["at_risk"]);
        assert!(!no.admits_risk());
        assert_eq!(When::parse_yaml("{pr: merged, at_risk: false}").unwrap().risky_facts(), vec!["busy_panes"]);
        // `at_risk: true` overrides facts written as zero beside it.
        assert!(When::parse_yaml("{at_risk: true, uncommitted: 0, untracked: 0, ignored: 0, unpushed: 0, busy_panes: 0}").unwrap().admits_risk());

        // Written as auto with at_risk: true, granted auto: still held at ask.
        let text = "- id: risky\n  when: { pr: merged, at_risk: true, busy_panes: 0 }\n  do: delete_worktree\n  level: auto\n";
        let b = Book::parse("k", text, &granted(&[("risky", HabitLevel::Auto)]));
        assert_eq!(b.level(b.get("risky").unwrap()), HabitLevel::Ask);
        let text = "- id: clean\n  when: { pr: merged, at_risk: false, busy_panes: 0 }\n  do: delete_worktree\n  level: auto\n";
        let b = Book::parse("k", text, &granted(&[("clean", HabitLevel::Auto)]));
        assert_eq!(b.level(b.get("clean").unwrap()), HabitLevel::Auto);
    }

    const DAY: f64 = 86_400.0;
    const NOW: f64 = 1_793_000_000.0;
    const TODAY: &str = "2026-10-26";

    fn clean_merged() -> Facts {
        Facts { pr: Some("merged".into()), pr_number: Some(7), unpushed: Some(0), idle_days: Some(3), days_since_merge: Some(3), ..Facts::default() }
    }

    fn granted(pairs: &[(&str, HabitLevel)]) -> HashMap<String, HabitLevel> {
        pairs.iter().map(|(k, l)| (k.to_string(), *l)).collect()
    }

    const FILE: &str = r#"
- id: delete-merged-clean
  about: worktree.cleanup
  when: { pr: merged, days_since_merge: ">=1", uncommitted: 0, untracked: 0, ignored_files: 0, unpushed: 0, busy_panes: 0 }
  do: delete_worktree
  level: ask
  status: active
  observed: 2026-11-05
  sources: [obs-1, obs-2]
  origin: inventory
  evidence: { approved: 5, rejected: 0, manual: 3, ignored: 0, since: 2026-11-05 }
  examples: [feat/island-pill, fix/web-question-details]
- id: leave-open-prs
  when: { pr: "open|draft" }
  do: keep
  level: observe
"#;

    #[test]
    fn parses_the_docs_format() {
        let b = Book::parse("seahelm-1", FILE, &granted(&[("delete-merged-clean", HabitLevel::Ask)]));
        assert!(b.invalid.is_empty(), "{:?}", b.invalid);
        assert_eq!(b.habits.len(), 2);
        let h = &b.habits[0];
        assert_eq!((h.act, h.level, h.origin, h.evidence.approved), (Do::DeleteWorktree, HabitLevel::Ask, Origin::Inventory, 5));
        assert_eq!(h.when.0.get(&Fact::DaysSinceMerge), Some(&Cond::Num(Op::Ge, 1)));
        assert_eq!(h.when.0.get(&Fact::Ignored), Some(&Cond::Num(Op::Eq, 0)), "ignored_files is ignored");
        assert_eq!(b.habits[1].when.0.get(&Fact::Pr), Some(&Cond::Pr(vec!["open".into(), "draft".into()])));
        assert!(h.when.matches(&clean_merged()));
        assert!(!h.when.matches(&Facts { unpushed: None, ..clean_merged() }), "unknown is not zero");
        assert!(!h.when.matches(&Facts { ignored: 1, ..clean_merged() }));
        assert!(!h.when.matches(&Facts { pr: Some("closed".into()), ..clean_merged() }));

        // Written back and read again: the same habits.
        let again = Book::parse("seahelm-1", &b.to_yaml(), &b.caps);
        assert_eq!(again.habits, b.habits);
    }

    #[test]
    fn comparisons() {
        let w = When::parse_yaml("{idle_days: \">=3\", days_since_merge: \"<7\", unpushed: \"<=0\", busy_panes: \"=0\", untracked: \"==0\", uncommitted: \">0\"}").unwrap();
        let f = Facts { idle_days: Some(3), days_since_merge: Some(6), unpushed: Some(0), changed: 1, ..Facts::default() };
        assert!(w.matches(&f));
        assert!(!w.matches(&Facts { idle_days: Some(2), ..f.clone() }));
        assert!(!w.matches(&Facts { days_since_merge: Some(7), ..f.clone() }));
        assert!(!w.matches(&Facts { changed: 0, ..f }));
        assert!(When::parse_yaml("{identical_to_base: true}").unwrap().matches(&Facts { identical_to_base: Some(true), ..Facts::default() }));
    }

    #[test]
    fn rejects_what_is_not_the_vocabulary() {
        let err = |t: &str| When::parse_yaml(t).unwrap_err();
        assert!(err("{relevance: high}").contains("unknown fact `relevance`"));
        assert!(err("{idle_days: \"about 3\"}").contains("not a number"));
        assert!(err("{idle_days: \"<0\"}").contains("matches nothing"));
        assert!(err("{pr: shipped}").contains("unknown state `shipped`"));
        assert!(err("{identical_to_base: 1}").contains("true or false"));
        assert!(err("{}").contains("names no fact"));
        assert!(err("{ignored: 0, ignored_files: 0}").contains("twice"));

        // A bad entry is reported and kept as written; the good ones load.
        let text = "- id: ok\n  when: {pr: merged}\n  do: delete_worktree\n  level: observe\n- id: Bad Id\n  when: {pr: merged}\n  do: delete_worktree\n  level: ask\n- id: vague\n  when: {pr: merged, vibe: done}\n  do: delete_worktree\n  level: ask\n- id: ok\n  when: {pr: closed}\n  do: keep\n  level: observe\n";
        let b = Book::parse("k", text, &HashMap::new());
        assert_eq!(b.habits.len(), 1);
        assert_eq!(b.invalid.len(), 3);
        assert!(b.invalid[0].1.contains("habit 2: id `Bad Id`"), "{:?}", b.invalid);
        assert!(b.invalid[1].1.contains("unknown fact `vibe`"), "{:?}", b.invalid);
        assert!(b.invalid[2].1.contains("used twice"));
        let saved = b.to_yaml();
        assert!(saved.contains("Bad Id") && saved.contains("vibe"), "nothing the user wrote is lost:\n{saved}");
    }

    #[test]
    fn safety_rule_on_load_and_on_promotion() {
        // Granted auto by the core, but the `when` lets ignored files through.
        let text = "- id: risky\n  when: {pr: merged, uncommitted: 0, untracked: 0, unpushed: 0, busy_panes: 0}\n  do: delete_worktree\n  level: auto\n";
        let b = Book::parse("k", text, &granted(&[("risky", HabitLevel::Auto)]));
        assert_eq!(b.habits[0].level, HabitLevel::Ask);
        assert!(b.notes[0].contains("admits ignored"), "{:?}", b.notes);
        assert_eq!(b.grants()["risky"], HabitLevel::Ask);

        for (w, risky) in [
            ("{pr: merged, uncommitted: 0, untracked: 0, ignored: 0, unpushed: 0, busy_panes: 0}", false),
            ("{pr: merged, uncommitted: \"<1\", untracked: \"<=0\", ignored: 0, unpushed: 0, busy_panes: 0}", false),
            ("{pr: merged, uncommitted: \"<=1\", untracked: 0, ignored: 0, unpushed: 0, busy_panes: 0}", true),
            ("{pr: merged, uncommitted: 0, untracked: 0, ignored: 0, unpushed: \">=0\", busy_panes: 0}", true),
            ("{pr: merged, uncommitted: 0, untracked: 0, ignored: 0, unpushed: 0}", true),
        ] {
            assert_eq!(When::parse_yaml(w).unwrap().admits_risk(), risky, "{w}");
        }

        // An in-memory auto on a risky habit is still honoured as ask.
        let mut b = Book::seeded(TODAY);
        b.habits[0].when = When::parse_yaml("{pr: merged}").unwrap();
        b.caps.insert(SEED_ID.into(), HabitLevel::Auto);
        b.habits[0].level = HabitLevel::Auto;
        assert_eq!(b.level(&b.habits[0]), HabitLevel::Ask);

        // And a grant to auto is refused.
        let mut b = Book::seeded(TODAY);
        b.habits[0].when = When::parse_yaml("{pr: merged, unpushed: 0}").unwrap();
        let mut offers = Offers::default();
        let o = offers.raise(GLOBAL, SEED_ID, HabitLevel::Auto, "n1");
        let Some(OfferAnswer::Accepted(g)) = offers.answer(&o.payload, Some("Yes, auto")) else { panic!() };
        assert!(b.promote(g, TODAY).unwrap_err().contains("cannot be auto"));
        assert_eq!(b.level(&b.habits[0]), HabitLevel::Ask);

        assert!(nothing_to_lose(&clean_merged()));
        assert!(!nothing_to_lose(&Facts { unpushed: None, ..clean_merged() }));
        assert!(!nothing_to_lose(&Facts { busy_panes: 1, ..clean_merged() }));
    }

    #[test]
    fn a_level_the_core_did_not_grant_is_not_honoured() {
        // Someone (First Mate with a file tool, a script) wrote auto into the file.
        let text = FILE.replace("level: ask", "level: auto");
        let b = Book::parse("k", &text, &granted(&[("delete-merged-clean", HabitLevel::Ask)]));
        assert_eq!(b.habits[0].level, HabitLevel::Ask);
        assert!(b.notes[0].contains("not granted by the core"));
        // A habit added by hand, never granted anything, starts at observe.
        let b = Book::parse("k", &text, &HashMap::new());
        assert_eq!(b.habits[0].level, HabitLevel::Observe);
        // Lowering by hand is honoured.
        let low = FILE.replace("level: ask", "level: suggest");
        let b = Book::parse("k", &low, &granted(&[("delete-merged-clean", HabitLevel::Ask)]));
        assert_eq!(b.level(&b.habits[0]), HabitLevel::Suggest);
        assert_eq!(b.grants()["delete-merged-clean"], HabitLevel::Suggest, "and lowers the grant when saved");
    }

    #[test]
    fn a_level_raised_by_hand_waits_for_the_users_confirmation() {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store::new(tmp.path().join("habits"));
        store.ensure_seed(TODAY, NOW).unwrap();
        // The user (or anything) edits the seed from ask to auto by hand.
        let text = std::fs::read_to_string(store.path(GLOBAL)).unwrap().replace("level: ask", "level: auto");
        std::fs::write(store.path(GLOBAL), &text).unwrap();
        let mut b = store.load(GLOBAL, TODAY);
        assert_eq!(b.level(&b.habits[0]), HabitLevel::Ask, "honoured at the grant until answered");
        assert_eq!(b.pending_confirmations(), vec![(SEED_ID.to_string(), HabitLevel::Auto, HabitLevel::Ask)]);
        // Saving meanwhile (evidence counted) keeps the user's edit in the file.
        b.approved(SEED_ID, &[]);
        store.save(&b, NOW + 1.0).unwrap();
        assert!(std::fs::read_to_string(store.path(GLOBAL)).unwrap().contains("level: auto"));
        assert_eq!(store.load(GLOBAL, TODAY).pending_confirmations().len(), 1);

        let mut offers = Offers::default();
        let o = offers.raise_confirm(GLOBAL, SEED_ID, HabitLevel::Auto, "c1");
        assert!(o.payload.starts_with("habit.confirm:_global/delete-merged-clean:auto:"));
        assert_eq!(o.options(), vec!["Yes, keep auto", "No, put it back"]);
        let msg = confirm_message(&b.habits[0], HabitLevel::Auto, HabitLevel::Ask, &store.path(GLOBAL));
        assert!(msg.contains("sets \"delete-merged-clean\" to auto, but the core only granted ask") && msg.contains("Evidence: 1 approved"), "{msg}");

        // No: the file goes back to the granted level.
        let Some(OfferAnswer::Declined { confirm: true, .. }) = offers.answer(&o.payload, Some(PUT_IT_BACK)) else { panic!() };
        assert_eq!(b.revert(SEED_ID), Some((HabitLevel::Auto, HabitLevel::Ask)));
        store.save(&b, NOW + 2.0).unwrap();
        assert!(std::fs::read_to_string(store.path(GLOBAL)).unwrap().contains("level: ask"));
        assert!(store.load(GLOBAL, TODAY).pending_confirmations().is_empty());

        // Yes: granted, two levels at once if that is what the file says.
        let text = std::fs::read_to_string(store.path(GLOBAL)).unwrap().replace("level: ask", "level: auto");
        std::fs::write(store.path(GLOBAL), &text).unwrap();
        let mut b = store.load(GLOBAL, TODAY);
        b.habits[0].level = HabitLevel::Observe;
        b.caps.insert(SEED_ID.into(), HabitLevel::Observe);
        let o = offers.raise_confirm(GLOBAL, SEED_ID, HabitLevel::Auto, "c2");
        let Some(OfferAnswer::Accepted(g)) = offers.answer(&o.payload, Some("Yes, keep auto")) else { panic!() };
        assert!(g.confirm);
        let c = b.confirm(g, TODAY).unwrap();
        assert_eq!((c.from, c.to), (HabitLevel::Observe, HabitLevel::Auto));
        store.save(&b, NOW + 3.0).unwrap();
        let b = store.load(GLOBAL, TODAY);
        assert_eq!(b.level(&b.habits[0]), HabitLevel::Auto);
        assert!(b.notes.is_empty() && b.pending_confirmations().is_empty());
    }

    #[test]
    fn confirmations_and_promotions_do_not_stand_in_for_each_other() {
        let text = "- id: risky\n  when: {pr: merged}\n  do: delete_worktree\n  level: auto\n";
        let mut b = Book::parse("k", text, &granted(&[("risky", HabitLevel::Observe)]));
        // A risky `when` written as auto is offered at ask at most.
        assert_eq!(b.pending_confirmations(), vec![("risky".to_string(), HabitLevel::Ask, HabitLevel::Observe)]);
        let mut offers = Offers::default();
        let p = offers.raise("k", "risky", HabitLevel::Suggest, "p");
        let Some(OfferAnswer::Accepted(g)) = offers.answer(&p.payload, Some("Yes, suggest")) else { panic!() };
        assert!(b.confirm(g, TODAY).is_err(), "a promotion's yes does not confirm");
        let c = offers.raise_confirm("k", "risky", HabitLevel::Ask, "c");
        let Some(OfferAnswer::Accepted(g)) = offers.answer(&c.payload, Some("Yes, keep ask")) else { panic!() };
        assert!(b.promote(g, TODAY).is_err(), "a confirmation's yes does not promote");
        // A demotion overrules a pending hand raise.
        let mut b = Book::parse("k", &text.replace("level: auto", "level: ask"), &granted(&[("risky", HabitLevel::Suggest)]));
        assert_eq!(b.pending_confirmations().len(), 1);
        b.rejected("risky");
        assert!(b.pending_confirmations().is_empty());
        assert!(b.to_yaml().contains("level: observe"));
    }

    #[test]
    fn promotion_only_through_the_users_yes_on_the_cores_card() {
        let mut b = Book::seeded(TODAY);
        b.habits[0].level = HabitLevel::Suggest;
        b.caps.insert(SEED_ID.into(), HabitLevel::Suggest);
        let mut offers = Offers::default();

        // No card was raised: a payload made up elsewhere is nothing.
        assert_eq!(offers.answer("habit.promote:_global/delete-merged-clean:ask:x", Some("Yes, ask")), None);
        // Raised, answered with anything but the yes: declined, no grant.
        let o = offers.raise(GLOBAL, SEED_ID, HabitLevel::Ask, "n1");
        assert!(o.payload.starts_with("habit.promote:_global/delete-merged-clean:ask:"));
        assert!(offers.pending(GLOBAL, SEED_ID));
        assert_eq!(offers.answer(&o.payload, Some(NOT_YET)), Some(OfferAnswer::Declined { key: GLOBAL.into(), id: SEED_ID.into(), confirm: false }));
        assert_eq!(offers.answer(&o.payload, Some("Yes, ask")), None, "an answered card is spent");
        let o = offers.raise(GLOBAL, SEED_ID, HabitLevel::Ask, "n2");
        assert!(matches!(offers.answer(&o.payload, None), Some(OfferAnswer::Declined { .. })), "dismissed is no");

        // The yes: a grant, applied once, one level.
        let o = offers.raise(GLOBAL, SEED_ID, HabitLevel::Ask, "n3");
        let Some(OfferAnswer::Accepted(g)) = offers.answer(&o.payload, Some("Yes, ask")) else { panic!() };
        let c = b.promote(g, TODAY).unwrap();
        assert_eq!((c.from, c.to), (HabitLevel::Suggest, HabitLevel::Ask));
        assert_eq!(b.habits[0].approved.as_deref(), Some(TODAY));

        // A grant that skips a level is refused.
        let mut fresh = Book::seeded(TODAY);
        fresh.habits[0].level = HabitLevel::Observe;
        fresh.caps.insert(SEED_ID.into(), HabitLevel::Observe);
        let o = offers.raise(GLOBAL, SEED_ID, HabitLevel::Ask, "n4");
        let Some(OfferAnswer::Accepted(g)) = offers.answer(&o.payload, Some("Yes, ask")) else { panic!() };
        assert!(fresh.promote(g, TODAY).is_err());

        // Writing a higher level in memory without a grant changes nothing the core honours.
        b.habits[0].level = HabitLevel::Auto;
        assert_eq!(b.level(&b.habits[0]), HabitLevel::Ask);
        assert_eq!(b.grants()[SEED_ID], HabitLevel::Ask);
    }

    #[test]
    fn demotion_is_automatic() {
        let mut b = Book::seeded(TODAY);
        b.caps.insert(SEED_ID.into(), HabitLevel::Auto);
        b.habits[0].level = HabitLevel::Auto;
        let c = b.undone(SEED_ID, "feat/x").unwrap();
        assert_eq!((c.from, c.to), (HabitLevel::Auto, HabitLevel::Ask));
        assert_eq!(b.habits[0].evidence.undone, 1);
        assert_eq!(b.grants()[SEED_ID], HabitLevel::Ask);

        b.approved(SEED_ID, &["feat/a".into()]);
        assert_eq!(b.habits[0].evidence.streak, 1);
        let c = b.rejected(SEED_ID).unwrap();
        assert_eq!((c.from, c.to), (HabitLevel::Ask, HabitLevel::Suggest));
        assert_eq!(b.habits[0].evidence.streak, 0);

        assert_eq!(b.expired(SEED_ID), None, "one expiry is not enough");
        let c = b.expired(SEED_ID).unwrap();
        assert_eq!((c.from, c.to), (HabitLevel::Suggest, HabitLevel::Observe));
        assert_eq!(b.habits[0].evidence.ignored, 2);
        assert_eq!(b.rejected(SEED_ID), None, "observe is the floor");
        assert!(c.line().contains("down from suggest to observe"));
    }

    fn removal(id: u64, at: f64, worktree: &str, by: By, facts: &Facts) -> Record {
        let mut r = Record::new(observations::kind::WORKTREE_REMOVED, by).with("facts", serde_json::to_value(facts).unwrap());
        r.id = format!("obs-{id}");
        r.at = super::super::engine::iso8601(at);
        r.repo = "/r/repo".into();
        r.worktree = worktree.into();
        r.branch = format!("b/{}", worktree.rsplit('/').next().unwrap());
        r
    }

    fn observe_book() -> Book {
        let mut b = Book::seeded(TODAY);
        b.habits[0].level = HabitLevel::Observe;
        b.caps.insert(SEED_ID.into(), HabitLevel::Observe);
        b
    }

    #[test]
    fn evidence_is_counted_once_and_gated() {
        let f = clean_merged();
        let dirty = Facts { untracked: 2, ..clean_merged() };
        let mut b = observe_book();
        let mut recs = vec![
            removal(1, NOW, "/r/a", By::User, &f),
            removal(2, NOW + 60.0, "/r/b", By::Agent, &f),
            removal(3, NOW + 120.0, "/r/c", By::FirstMate, &f),
            removal(4, NOW + 180.0, "/r/d", By::User, &dirty),
            removal(5, NOW + 240.0, "/r/e", By::User, &f),
        ];
        let changes = b.count(&recs, |_| true);
        let h = &b.habits[0];
        assert_eq!(h.evidence.manual, 3, "user and agent, matching facts only");
        assert_eq!(h.sources, vec!["obs-1", "obs-2", "obs-5"]);
        assert_eq!(h.examples, vec!["b/a", "b/b", "b/e"]);
        assert!(changes.is_empty(), "three on one day is not enough");
        assert_eq!(b.count(&recs, |_| true), vec![]);
        assert_eq!(b.habits[0].evidence.manual, 3, "counted once");

        // A fourth on another day: N=3 over two days and two worktrees.
        recs.push(removal(6, NOW + DAY, "/r/f", By::User, &f));
        let changes = b.count(&recs, |_| true);
        assert_eq!(changes.len(), 1);
        assert_eq!((changes[0].from, changes[0].to), (HabitLevel::Observe, HabitLevel::Suggest));
        assert_eq!(b.level(&b.habits[0]), HabitLevel::Suggest);
        assert!(b.offers_due(&recs).is_empty(), "the evidence that raised it is spent");

        // Three more by hand on two days: suggest → ask is offered (not applied).
        recs.push(removal(7, NOW + 2.0 * DAY, "/r/g", By::User, &f));
        recs.push(removal(8, NOW + 2.0 * DAY, "/r/h", By::User, &f));
        recs.push(removal(9, NOW + 3.0 * DAY, "/r/i", By::User, &f));
        assert!(b.count(&recs, |_| true).is_empty());
        assert_eq!(b.offers_due(&recs), vec![(SEED_ID.to_string(), HabitLevel::Ask)]);
        assert_eq!(b.level(&b.habits[0]), HabitLevel::Suggest);
        b.declined(SEED_ID);
        assert!(b.offers_due(&recs).is_empty(), "declined: waits for fresh evidence");

        // Other repos' records do not count for a repo's book.
        let mut b = observe_book();
        b.count(&recs, |r| r.repo == "/r/other");
        assert_eq!(b.habits[0].evidence.manual, 0);
    }

    #[test]
    fn the_same_worktree_twice_does_not_pass_the_gate() {
        let f = clean_merged();
        let mut b = observe_book();
        let recs: Vec<Record> = (0..4).map(|i| removal(i, NOW + i as f64 * DAY, "/r/same", By::User, &f)).collect();
        assert!(b.count(&recs, |_| true).is_empty());
    }

    #[test]
    fn auto_is_offered_after_m_approvals_in_a_row() {
        let mut b = Book::seeded(TODAY);
        for _ in 0..tuning::M - 1 {
            b.approved(SEED_ID, &[]);
        }
        assert!(b.offers_due(&[]).is_empty());
        b.approved(SEED_ID, &[]);
        assert_eq!(b.offers_due(&[]), vec![(SEED_ID.to_string(), HabitLevel::Auto)]);
        let mut offers = Offers::default();
        let o = offers.raise(GLOBAL, SEED_ID, HabitLevel::Auto, "n");
        let msg = offer_message(&b.habits[0], HabitLevel::Auto, HabitLevel::Ask);
        assert!(msg.contains("approved \"delete-merged-clean\" 5 times") && msg.contains("Evidence: 5 approved"), "{msg}");
        let Some(OfferAnswer::Accepted(g)) = offers.answer(&o.payload, Some(&yes_label(HabitLevel::Auto))) else { panic!() };
        b.promote(g, TODAY).unwrap();
        assert_eq!(b.level(&b.habits[0]), HabitLevel::Auto);
    }

    #[test]
    fn precedence() {
        let mut b = Book::seeded(TODAY);
        let ask = Precedence { repo_cap: None, user_default: RuleLevel::Ask };
        assert_eq!(ask.effective(&b, &b.habits[0]), HabitLevel::Ask);
        // Granted auto, approved by the user: replaces an `ask` default…
        b.caps.insert(SEED_ID.into(), HabitLevel::Auto);
        b.habits[0].level = HabitLevel::Auto;
        b.habits[0].approved = Some(TODAY.into());
        assert_eq!(ask.effective(&b, &b.habits[0]), HabitLevel::Auto);
        // …but not a `deny`.
        assert_eq!(Precedence { repo_cap: None, user_default: RuleLevel::Deny }.effective(&b, &b.habits[0]), HabitLevel::Observe);
        // The repo's own rules cap it, deny winning.
        assert_eq!(Precedence { repo_cap: Some(RuleLevel::Ask), user_default: RuleLevel::Auto }.effective(&b, &b.habits[0]), HabitLevel::Ask);
        assert_eq!(Precedence { repo_cap: Some(RuleLevel::Deny), user_default: RuleLevel::Auto }.effective(&b, &b.habits[0]), HabitLevel::Observe);
        // Never approved: the user's default caps it.
        b.habits[0].approved = None;
        assert_eq!(ask.effective(&b, &b.habits[0]), HabitLevel::Ask);

        // The cap comes only from a repo's own file.
        let own = super::super::rules::Config::parse("rules:\n  - name: c\n    on: pr.merged\n    autonomy: { delete_worktree: deny }\n    brief: b\n").unwrap();
        assert_eq!(repo_cap(&own, true), Some(RuleLevel::Deny));
        assert_eq!(repo_cap(&super::super::rules::Config::built_in(), false), None);
    }

    #[test]
    fn keep_wins_and_the_highest_level_decides() {
        let mut repo = Book::empty("r");
        let text = "- id: keep-drafts\n  when: {pr: draft}\n  do: keep\n  level: observe\n- id: closed-old\n  when: {pr: closed, idle_days: \">=30\", unpushed: 0}\n  do: delete_worktree\n  level: suggest\n";
        repo = Book::parse(&repo.key, text, &granted(&[("closed-old", HabitLevel::Suggest)]));
        let global = Book::seeded(TODAY);
        let prec = Precedence { repo_cap: None, user_default: RuleLevel::Ask };
        let books = [&repo, &global];
        let d = decide(&clean_merged(), &books, &prec).unwrap();
        assert_eq!((d.key.as_str(), d.id.as_str(), d.level), (GLOBAL, SEED_ID, HabitLevel::Ask));
        assert_eq!(decide(&Facts { pr: Some("draft".into()), ..clean_merged() }, &books, &prec), None);
        let closed = Facts { pr: Some("closed".into()), idle_days: Some(40), ..clean_merged() };
        assert_eq!(decide(&closed, &books, &prec).unwrap().id, "closed-old");
        assert_eq!(decide(&Facts { untracked: 1, ..clean_merged() }, &books, &prec), None);
    }

    #[test]
    fn store_keeps_history_and_undo_never_raises() {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store::new(tmp.path().join("habits"));
        // Before anything is written, the global book is the seed, unwritten.
        assert_eq!(store.load(GLOBAL, TODAY).habits[0].id, SEED_ID);
        assert!(!store.path(GLOBAL).exists());
        assert!(store.ensure_seed(TODAY, NOW).unwrap());
        assert!(!store.ensure_seed(TODAY, NOW).unwrap(), "seeded once");
        let mut b = store.load(GLOBAL, TODAY);
        assert_eq!(b.level(&b.habits[0]), HabitLevel::Ask, "the seed is granted ask");

        b.rejected(SEED_ID);
        store.save(&b, NOW + 1.0).unwrap();
        assert_eq!(store.load(GLOBAL, TODAY).habits[0].level, HabitLevel::Suggest);
        let history: Vec<_> = std::fs::read_dir(tmp.path().join("habits/.history")).unwrap().collect();
        assert_eq!(history.len(), 1, "the version before is kept");

        // Undo puts the file back, but the grant stays at suggest.
        assert!(store.undo(GLOBAL, TODAY).unwrap());
        let b = store.load(GLOBAL, TODAY);
        assert_eq!(b.habits[0].level, HabitLevel::Suggest);
        assert!(std::fs::read_to_string(store.path(GLOBAL)).unwrap().contains("level: ask"));
        assert!(!store.undo(GLOBAL, TODAY).unwrap(), "nothing more to undo");

        // A user who deletes the seed does not get it back.
        std::fs::write(store.path(GLOBAL), "[]\n").unwrap();
        assert!(!store.ensure_seed(TODAY, NOW).unwrap());
        assert!(store.load(GLOBAL, TODAY).habits.is_empty());
    }

    /// The grants the core wrote, as a map.
    fn grants_on_disk(store: &Store) -> Value {
        serde_json::from_str(&std::fs::read_to_string(store.dir.join(GRANTED)).unwrap_or_default()).unwrap_or(Value::Null)
    }

    #[test]
    fn a_tampered_grant_is_put_back_and_reported() {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store::new(tmp.path().join("habits"));
        store.ensure_seed(TODAY, NOW).unwrap();
        assert_eq!(grants_on_disk(&store)[GLOBAL][SEED_ID], "ask");
        assert!(take_tamper_reports(Some(&store.dir)).is_empty());

        // First Mate's shell grants itself auto, file and all.
        let forged = r#"{"_global": {"delete-merged-clean": "auto"}}"#;
        std::fs::write(store.dir.join(GRANTED), forged).unwrap();
        std::fs::write(store.path(GLOBAL), std::fs::read_to_string(store.path(GLOBAL)).unwrap().replace("level: ask", "level: auto")).unwrap();
        let b = store.load(GLOBAL, TODAY);
        assert_eq!(b.level(&b.habits[0]), HabitLevel::Ask, "held at what the core granted");
        assert_eq!(grants_on_disk(&store)[GLOBAL][SEED_ID], "ask", "the file is the core's again");
        let reports = take_tamper_reports(Some(&store.dir));
        assert_eq!(reports.len(), 1, "{reports:?}");
        assert!(reports[0].contains("was changed by something other than the core") && reports[0].contains("put back"), "{}", reports[0]);
        // Once put back, nothing more to say.
        store.check_grants();
        assert!(take_tamper_reports(Some(&store.dir)).is_empty());

        // Deleted: put back too.
        std::fs::remove_file(store.dir.join(GRANTED)).unwrap();
        store.check_grants();
        assert_eq!(grants_on_disk(&store)[GLOBAL][SEED_ID], "ask");
        assert!(take_tamper_reports(Some(&store.dir))[0].contains("was deleted"));

        // The core's own writes are not tampering.
        let mut b = store.load(GLOBAL, TODAY);
        b.rejected(SEED_ID);
        store.save(&b, NOW + 1.0).unwrap();
        assert_eq!(grants_on_disk(&store)[GLOBAL][SEED_ID], "suggest");
        assert!(take_tamper_reports(Some(&store.dir)).is_empty());
    }

    #[test]
    fn the_seal_outlives_a_restart() {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store::new(tmp.path().join("habits"));
        store.ensure_seed(TODAY, NOW).unwrap();
        let granted = store.dir.join(GRANTED);
        // Tampered while the core was down: the seal on disk still knows.
        std::fs::write(&granted, r#"{"_global": {"delete-merged-clean": "auto"}}"#).unwrap();
        seal::forget(&granted);
        store.check_grants();
        assert_eq!(grants_on_disk(&store)[GLOBAL][SEED_ID], "ask");
        assert_eq!(take_tamper_reports(Some(&store.dir)).len(), 1);

        // Both changed, the seal's digest not recomputed: the seal is not
        // believed, and every grant starts over.
        let forged = r#"{"_global": {"delete-merged-clean": "auto"}}"#;
        std::fs::write(&granted, forged).unwrap();
        std::fs::write(store.dir.join(SEAL), json!({"sha256": seal::digest("{}"), "text": forged}).to_string()).unwrap();
        seal::forget(&granted);
        let b = store.load(GLOBAL, TODAY);
        assert_eq!(b.level(&b.habits[0]), HabitLevel::Observe);
        assert_eq!(grants_on_disk(&store), json!({}));
        let reports = take_tamper_reports(Some(&store.dir));
        assert_eq!(reports.len(), 1, "one note, not two: {reports:?}");
        assert!(reports[0].contains("seal") && reports[0].contains("back to observe") && reports[0].contains("approve a level again"), "{}", reports[0]);
        // Sealed afresh: nothing more to say.
        seal::forget(&granted);
        store.check_grants();
        assert!(take_tamper_reports(Some(&store.dir)).is_empty());
    }

    #[test]
    fn grants_from_before_the_seal_are_adopted() {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store::new(tmp.path().join("habits"));
        std::fs::create_dir_all(&store.dir).unwrap();
        std::fs::write(store.dir.join(GRANTED), r#"{"_global": {"delete-merged-clean": "ask"}}"#).unwrap();
        store.check_grants();
        assert!(take_tamper_reports(Some(&store.dir)).is_empty());
        assert!(store.dir.join(SEAL).exists());
        std::fs::write(store.dir.join(GRANTED), r#"{"_global": {"delete-merged-clean": "auto"}}"#).unwrap();
        store.check_grants();
        assert_eq!(grants_on_disk(&store)[GLOBAL][SEED_ID], "ask");
    }

    #[test]
    fn repo_keys_are_stable_and_distinct() {
        assert_eq!(repo_key("/nonexistent/w/app"), repo_key("/nonexistent/w/app/"));
        assert_ne!(repo_key("/nonexistent/a/app"), repo_key("/nonexistent/b/app"));
        assert!(repo_key("/nonexistent/w/My App").starts_with("my-app-"));
    }

    #[test]
    fn list_shows_levels_as_honoured() {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store::new(tmp.path().join("habits"));
        let key = repo_key("/nonexistent/r");
        std::fs::create_dir_all(&store.dir).unwrap();
        std::fs::write(store.path(&key), FILE.replace("level: ask", "level: auto")).unwrap();
        store.remember_repo(&key, "/nonexistent/r");
        let v = list_json(&store, None, TODAY, |_| Precedence { repo_cap: Some(RuleLevel::Deny), user_default: RuleLevel::Ask });
        let books = v["books"].as_array().unwrap();
        assert_eq!(books[0]["key"], GLOBAL);
        assert_eq!(books[0]["habits"][0]["level"], "ask");
        assert_eq!(books[1]["repo"], "/nonexistent/r");
        let h = &books[1]["habits"][0];
        assert_eq!((h["level"].as_str(), h["written_level"].as_str(), h["effective_level"].as_str()), (Some("observe"), Some("auto"), Some("observe")));
        assert_eq!(h["can_be_auto"], true);
    }
    #[test]
    fn editing_an_auto_habit_only_grants_the_ask_shown_on_the_card() {
        let mut b = Book::seeded(TODAY);
        b.caps.insert(SEED_ID.into(), HabitLevel::Auto);
        b.habits[0].level = HabitLevel::Auto;
        let mut replacement = Habit::seed(TODAY);
        replacement.when = serde_yaml::from_str("docs PRs no longer needed").unwrap();
        let grant = Grant::from_inventory_card(GLOBAL, SEED_ID, HabitLevel::Ask);
        b.adopt_proposal(replacement, grant, TODAY).unwrap();
        assert_eq!(b.level(&b.habits[0]), HabitLevel::Ask);
        assert!(!b.habits[0].when.matches(&clean_merged()));
    }

}
