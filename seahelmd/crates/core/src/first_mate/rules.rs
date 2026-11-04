//! A repo's `.seahelm/automations.yml`, or the built-in rules when it has
//! none (`AutomationRules.swift`). Same file, same keys: a repo's rules mean
//! the same to the core as they did to the app.

use std::collections::BTreeMap;
use std::path::Path;

use serde_yaml::Value as Yaml;

use super::clock::Local;
use super::cron::Cron;

/// What First Mate may do on its own.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Action {
    /// Type into another pane (`seahelm pane run/send`).
    MessagePane,
    /// A new worktree with an agent on it (`seahelm worktree create`).
    StartAgent,
    /// Remove a worktree (`seahelm worktree delete`).
    DeleteWorktree,
}

impl Action {
    pub const ALL: [Action; 3] = [Action::MessagePane, Action::StartAgent, Action::DeleteWorktree];

    pub fn as_str(self) -> &'static str {
        match self {
            Action::MessagePane => "message_pane",
            Action::StartAgent => "start_agent",
            Action::DeleteWorktree => "delete_worktree",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Action::ALL.into_iter().find(|a| a.as_str() == s)
    }
}

/// Ordered by strictness: the strictest of several applies.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Level {
    Auto,
    Ask,
    Deny,
}

impl Level {
    pub fn as_str(self) -> &'static str {
        match self {
            Level::Auto => "auto",
            Level::Ask => "ask",
            Level::Deny => "deny",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "auto" => Some(Level::Auto),
            "ask" => Some(Level::Ask),
            "deny" => Some(Level::Deny),
            _ => None,
        }
    }
}

pub type Autonomy = BTreeMap<Action, Level>;

/// What an action does when neither a rule nor the user says otherwise.
pub fn default_autonomy() -> Autonomy {
    [(Action::MessagePane, Level::Auto), (Action::StartAgent, Level::Ask), (Action::DeleteWorktree, Level::Ask)].into()
}

/// The defaults with the user's choices (`config.json` `autopilot_autonomy`)
/// laid over them.
pub fn defaults_overriding(raw: &BTreeMap<String, String>) -> Autonomy {
    let mut map = default_autonomy();
    for (k, v) in raw {
        if let (Some(a), Some(l)) = (Action::parse(k), Level::parse(v)) {
            map.insert(a, l);
        }
    }
    map
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Trigger {
    CiFailed,
    PrMerged,
    /// A cron expression.
    Schedule(String),
}

impl Trigger {
    pub fn event_name(&self) -> &'static str {
        match self {
            Trigger::CiFailed => "ci.failed",
            Trigger::PrMerged => "pr.merged",
            Trigger::Schedule(_) => "schedule",
        }
    }
}

/// `when: { branch: … }`: an exact name, a glob (`feat/*`), or either
/// negated with a leading `!`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BranchFilter(pub String);

impl BranchFilter {
    pub fn matches(&self, branch: &str) -> bool {
        match self.0.strip_prefix('!') {
            Some(glob) => !glob_match(glob, branch),
            None => glob_match(&self.0, branch),
        }
    }
}

/// `fnmatch` without flags: `*` and `?` match any character, `/` included;
/// `[…]` is a set, `[!…]` its complement.
fn glob_match(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let t: Vec<char> = text.chars().collect();
    fn go(p: &[char], t: &[char]) -> bool {
        match p.first() {
            None => t.is_empty(),
            Some('*') => (0..=t.len()).any(|i| go(&p[1..], &t[i..])),
            Some('?') => !t.is_empty() && go(&p[1..], &t[1..]),
            Some('[') => {
                let Some(close) = p.iter().skip(1).position(|&c| c == ']').map(|i| i + 1) else {
                    return t.first() == Some(&'[') && go(&p[1..], &t[1..]);
                };
                let Some(&c) = t.first() else { return false };
                let (neg, set) = match p[1] {
                    '!' => (true, &p[2..close]),
                    _ => (false, &p[1..close]),
                };
                let mut hit = false;
                let mut i = 0;
                while i < set.len() {
                    if i + 2 < set.len() && set[i + 1] == '-' {
                        hit |= set[i] <= c && c <= set[i + 2];
                        i += 3;
                    } else {
                        hit |= set[i] == c;
                        i += 1;
                    }
                }
                hit != neg && go(&p[close + 1..], &t[1..])
            }
            Some(&c) => t.first() == Some(&c) && go(&p[1..], &t[1..]),
        }
    }
    go(&p, &t)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rule {
    pub name: String,
    pub trigger: Trigger,
    pub branch: Option<BranchFilter>,
    /// Per PR per day; None = unlimited.
    pub max_attempts: Option<u32>,
    pub autonomy: Autonomy,
    pub brief: String,
    /// `enabled: false` keeps a rule written down without it firing.
    pub enabled: bool,
}

/// `"23:00-08:00"`: may wrap midnight.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct QuietHours {
    start: u32,
    end: u32,
}

impl QuietHours {
    pub fn parse(text: &str) -> Option<Self> {
        let (a, b) = text.split_once('-')?;
        let minute = |s: &str| -> Option<u32> {
            let (h, m) = s.trim().split_once(':')?;
            let (h, m) = (h.parse::<u32>().ok()?, m.parse::<u32>().ok()?);
            (h < 24 && m < 60).then_some(h * 60 + m)
        };
        Some(QuietHours { start: minute(a)?, end: minute(b)? })
    }

    pub fn contains(&self, t: &Local) -> bool {
        let m = t.minute_of_day();
        if self.start == self.end {
            false
        } else if self.start < self.end {
            m >= self.start && m < self.end
        } else {
            m >= self.start || m < self.end
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Settings {
    pub max_concurrent_agents: Option<u32>,
    /// Percent of the Claude/Codex 5h window above which no agent is started.
    pub pause_above_usage: Option<f64>,
    pub quiet_hours: Option<QuietHours>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    pub settings: Settings,
    pub rules: Vec<Rule>,
    /// The user's defaults (`autopilot_autonomy`), laid under every rule.
    pub defaults: Autonomy,
}

pub const RELATIVE_PATH: &str = ".seahelm/automations.yml";

impl Config {
    /// What a repo without a file of its own gets.
    pub fn built_in() -> Self {
        let rule = |name: &str, trigger, branch: Option<&str>, max, autonomy: &[(Action, Level)], brief: &str, enabled| Rule {
            name: name.into(),
            trigger,
            branch: branch.map(|b| BranchFilter(b.into())),
            max_attempts: max,
            autonomy: autonomy.iter().copied().collect(),
            brief: brief.into(),
            enabled,
        };
        Config {
            settings: Settings::default(),
            defaults: default_autonomy(),
            rules: vec![
                rule(
                    "fix-ci",
                    Trigger::CiFailed,
                    Some("!main"),
                    Some(2),
                    &[(Action::MessagePane, Level::Auto), (Action::StartAgent, Level::Ask)],
                    "PR #{{pr}} on {{branch}} failed CI. Read why with `gh run view --log-failed` \
                     (or `gh pr checks {{pr}}`). If the worktree's agent is idle, tell it what broke and \
                     ask it to fix and push; if it is busy, wait for it; if there is none, start one.",
                    true,
                ),
                rule(
                    "cleanup-merged",
                    Trigger::PrMerged,
                    None,
                    None,
                    &[(Action::DeleteWorktree, Level::Ask)],
                    "PR #{{pr}} ({{branch}}) has been merged. If the worktree has no uncommitted or \
                     unpushed work and its panes are idle, delete it; otherwise say what is left.",
                    true,
                ),
                // Off until the user turns it on: it wakes First Mate every
                // weekday morning for every project, and that is not free.
                rule(
                    "triage-issues",
                    Trigger::Schedule("0 9 * * 1-5".into()),
                    None,
                    None,
                    &[(Action::StartAgent, Level::Ask)],
                    "Morning triage for {{repo}}. With `gh issue list --state open --label P0,P1 \
                     --json number,title,labels,assignees,updatedAt` (and without the label filter if that \
                     finds nothing urgent), find the open issues most worth starting now. Skip any already \
                     being worked on — `seahelm pane list` shows the worktrees, and a branch or PR naming \
                     the issue counts. Pick at most three, say in one line each why, and offer them with \
                     `seahelm propose` so the user can start one with a tap.",
                    false,
                ),
            ],
        }
    }

    /// The level for `action` under `rule` (None = a conversation, not a rule).
    pub fn autonomy(&self, action: Action, rule: Option<&Rule>) -> Level {
        rule.and_then(|r| r.autonomy.get(&action))
            .or_else(|| self.defaults.get(&action))
            .copied()
            .or_else(|| default_autonomy().get(&action).copied())
            .unwrap_or(Level::Ask)
    }

    pub fn rules_for(&self, trigger: &Trigger) -> impl Iterator<Item = &Rule> {
        let trigger = trigger.clone();
        self.rules.iter().filter(move |r| r.enabled && r.trigger == trigger)
    }

    pub fn parse(text: &str) -> Result<Self, String> {
        let root: Yaml = serde_yaml::from_str(text).map_err(|e| e.to_string())?;
        let map = root.as_mapping().ok_or("automations.yml must be a mapping with `rules:`")?;
        let get = |m: &serde_yaml::Mapping, k: &str| m.get(Yaml::String(k.into())).cloned();

        let mut settings = Settings::default();
        if let Some(fm) = get(map, "first_mate").and_then(|v| v.as_mapping().cloned()) {
            if let Some(b) = get(&fm, "budget").and_then(|v| v.as_mapping().cloned()) {
                settings.max_concurrent_agents = get(&b, "max_concurrent_agents").and_then(|v| v.as_u64()).map(|n| n as u32);
                settings.pause_above_usage = get(&b, "pause_above_usage").and_then(|v| v.as_f64());
            }
            settings.quiet_hours = get(&fm, "quiet_hours").and_then(|v| v.as_str().and_then(QuietHours::parse));
        }

        let mut rules = Vec::new();
        let raw = get(map, "rules").and_then(|v| v.as_sequence().cloned()).unwrap_or_default();
        for (i, r) in raw.iter().enumerate() {
            let err = |m: &str| format!("rule {}: {m}", i + 1);
            let r = r.as_mapping().ok_or_else(|| err("not a mapping"))?;
            let name = get(r, "name").and_then(|v| v.as_str().map(str::to_string)).filter(|n| !n.is_empty()).ok_or_else(|| err("missing name"))?;
            let trigger = match get(r, "on") {
                Some(Yaml::String(s)) if s == "ci.failed" => Trigger::CiFailed,
                Some(Yaml::String(s)) if s == "pr.merged" => Trigger::PrMerged,
                Some(Yaml::Mapping(on)) => {
                    let cron = get(&on, "schedule").and_then(|v| v.as_str().map(str::to_string)).ok_or_else(|| err("`on` mapping needs `schedule`"))?;
                    if Cron::parse(&cron).is_none() {
                        return Err(err(&format!("`{cron}` is not a five-field cron expression")));
                    }
                    Trigger::Schedule(cron)
                }
                _ => return Err(err("unknown `on` (ci.failed, pr.merged or {schedule: …})")),
            };
            let brief = get(r, "brief").and_then(|v| v.as_str().map(str::to_string)).filter(|b| !b.trim().is_empty()).ok_or_else(|| err("missing brief"))?;
            let mut autonomy = Autonomy::new();
            if let Some(a) = get(r, "autonomy").and_then(|v| v.as_mapping().cloned()) {
                for (k, v) in a {
                    let key = k.as_str().unwrap_or_default().to_string();
                    let action = Action::parse(&key).ok_or_else(|| err(&format!("unknown action `{key}`")))?;
                    let level = v.as_str().and_then(Level::parse).ok_or_else(|| err(&format!("`{key}` must be auto, ask or deny")))?;
                    autonomy.insert(action, level);
                }
            }
            rules.push(Rule {
                name,
                trigger,
                branch: get(r, "when")
                    .and_then(|w| w.as_mapping().cloned())
                    .and_then(|w| get(&w, "branch"))
                    .and_then(|b| b.as_str().map(|s| BranchFilter(s.into()))),
                max_attempts: get(r, "max_attempts").and_then(|v| v.as_u64()).map(|n| n as u32),
                autonomy,
                brief,
                enabled: get(r, "enabled").and_then(|v| v.as_bool()).unwrap_or(true),
            });
        }
        Ok(Config { settings, rules, defaults: default_autonomy() })
    }

    /// The repo's own file, else the built-in rules. A file that does not
    /// parse stops the repo's automation rather than falling back: rules
    /// someone wrote and got wrong must not silently become the defaults.
    pub fn load(repo: &Path) -> Result<Self, String> {
        match std::fs::read_to_string(repo.join(RELATIVE_PATH)) {
            Err(_) => Ok(Self::built_in()),
            Ok(text) => Self::parse(&text).map_err(|e| format!("{RELATIVE_PATH}: {e}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn branch_filters() {
        assert!(BranchFilter("feat/*".into()).matches("feat/a/b"));
        assert!(!BranchFilter("feat/*".into()).matches("fix/a"));
        assert!(BranchFilter("!main".into()).matches("task/x"));
        assert!(!BranchFilter("!main".into()).matches("main"));
        assert!(BranchFilter("release-[0-9]*".into()).matches("release-2.1"));
        assert!(!BranchFilter("release-[!0-9]*".into()).matches("release-2.1"));
    }

    #[test]
    fn quiet_hours_wrap_midnight() {
        let q = QuietHours::parse("23:00-08:00").unwrap();
        let at = |hour, minute| Local { year: 2026, month: 1, day: 1, hour, minute, weekday: 4 };
        assert!(q.contains(&at(23, 30)) && q.contains(&at(7, 59)));
        assert!(!q.contains(&at(8, 0)) && !q.contains(&at(12, 0)));
        assert!(QuietHours::parse("25:00-08:00").is_none());
    }

    #[test]
    fn parses_a_repos_file() {
        let c = Config::parse(
            r#"
first_mate:
  budget: { max_concurrent_agents: 2, pause_above_usage: 80 }
  quiet_hours: "22:00-07:00"
rules:
  - name: fix-ci
    on: ci.failed
    when: { branch: "!main" }
    max_attempts: 3
    autonomy: { message_pane: auto, start_agent: deny }
    brief: Fix {{pr}}.
  - name: nightly
    on: { schedule: "0 2 * * *" }
    enabled: false
    brief: Look around.
"#,
        )
        .unwrap();
        assert_eq!(c.settings.max_concurrent_agents, Some(2));
        assert_eq!(c.settings.pause_above_usage, Some(80.0));
        assert!(c.settings.quiet_hours.is_some());
        assert_eq!(c.rules[0].autonomy.get(&Action::StartAgent), Some(&Level::Deny));
        assert_eq!(c.rules[0].max_attempts, Some(3));
        assert_eq!(c.rules[1].trigger, Trigger::Schedule("0 2 * * *".into()));
        assert_eq!(c.rules_for(&Trigger::Schedule("0 2 * * *".into())).count(), 0);
        assert_eq!(c.rules_for(&Trigger::CiFailed).count(), 1);
    }

    #[test]
    fn bad_files_say_which_rule() {
        let e = Config::parse("rules:\n  - name: x\n    on: push\n    brief: b\n").unwrap_err();
        assert!(e.starts_with("rule 1: unknown `on`"), "{e}");
        let e = Config::parse("rules:\n  - name: x\n    on: ci.failed\n    brief: b\n    autonomy: { merge: auto }\n").unwrap_err();
        assert!(e.contains("unknown action `merge`"), "{e}");
        let e = Config::parse("rules:\n  - name: x\n    on: { schedule: \"9 * *\" }\n    brief: b\n").unwrap_err();
        assert!(e.contains("not a five-field cron"), "{e}");
        assert!(Config::parse("- a\n- b\n").is_err());
    }

    #[test]
    fn autonomy_falls_back_rule_then_user_then_default() {
        let mut c = Config::built_in();
        let fix = c.rules[0].clone();
        assert_eq!(c.autonomy(Action::StartAgent, Some(&fix)), Level::Ask);
        assert_eq!(c.autonomy(Action::DeleteWorktree, Some(&fix)), Level::Ask);
        c.defaults.insert(Action::DeleteWorktree, Level::Deny);
        assert_eq!(c.autonomy(Action::DeleteWorktree, Some(&fix)), Level::Deny);
        assert_eq!(c.autonomy(Action::MessagePane, None), Level::Auto);
    }
}
