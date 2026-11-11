//! Asking for a busy project's final goal (autonomy D37). Project memory
//! (phase 7) is written only when the user says "remember …" to First Mate;
//! in field use only one rule ever got there, and the two projects the user
//! made 13 and 11 worktrees in that week had no goal at all — the user talks
//! goals with the agents in panes, where First Mate does not listen.
//!
//! So: a project with `BUSY_WORKTREES` or more worktrees made in the last
//! `BUSY_DAYS` and nothing in its memory gets one proactive card — tell First
//! Mate the goal / later / don't. "Tell" starts a First Mate turn that asks
//! for the goal in one line and stores the user's own words with
//! `seahelm memory note <repo> "goal: …"`; the core never writes a goal it
//! inferred. Later (or dismissing) asks again after `LATER_DAYS`; don't is
//! for good.

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

use super::observations::{self, Record};

/// Card payloads: `project.goal-<n>`.
pub const PREFIX: &str = "project.goal";
/// `first-mate/goal-offers.json`.
pub const FILE: &str = "goal-offers.json";
pub const BUSY_WORKTREES: usize = 3;
pub const BUSY_DAYS: f64 = 7.0;
pub const LATER_DAYS: f64 = 14.0;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Asked {
    /// `offered`, `asked` (the user said they would tell), `later`, `declined`.
    pub status: String,
    pub at: f64,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct State {
    /// Per repo (main checkout).
    #[serde(default)]
    pub asked: BTreeMap<String, Asked>,
}

impl State {
    pub fn load(dir: &Path) -> State {
        std::fs::read_to_string(dir.join(FILE)).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
    }

    pub fn save(&self, dir: &Path) {
        let path = dir.join(FILE);
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, serde_json::to_string_pretty(self).unwrap_or_default()).is_ok() {
            let _ = std::fs::rename(&tmp, &path);
        }
    }

    /// Whether `repo` may be asked now: never asked, or "later" long enough ago.
    pub fn may_ask(&self, repo: &str, now: f64) -> bool {
        match self.asked.get(repo) {
            None => true,
            Some(a) => a.status == "later" && now - a.at >= LATER_DAYS * 86_400.0,
        }
    }
}

/// Repos with at least `BUSY_WORKTREES` worktrees made in the `BUSY_DAYS`
/// before `now` (not counting First Mate's own or research runs), busiest
/// first.
pub fn busy_repos(records: &[Record], now: f64) -> Vec<String> {
    let since = super::engine::iso8601(now - BUSY_DAYS * 86_400.0);
    let mut count: BTreeMap<String, usize> = BTreeMap::new();
    for r in records {
        if r.kind == observations::kind::WORKTREE_CREATED && !r.repo.is_empty() && r.at.as_str() > since.as_str()
            && r.by != "first_mate" && !r.by.starts_with("research")
        {
            *count.entry(observations::norm(&r.repo)).or_default() += 1;
        }
    }
    let mut busy: Vec<(String, usize)> = count.into_iter().filter(|(_, n)| *n >= BUSY_WORKTREES).collect();
    busy.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    busy.into_iter().map(|(r, _)| r).collect()
}

/// What First Mate is told when the user agrees to give the goal.
pub fn ask_prompt(repo: &str) -> String {
    format!(
        "[seahelm event] project.goal\nProject: {repo}\n\
         The user agreed to tell you this project's final goal. Ask them for it in one short line, \
         in the language they use with you. When they answer, store their own words with \
         seahelm memory note {repo} \"goal: <their words>\" — nothing you inferred, and nothing \
         if they do not answer."
    )
}

impl super::FirstMate {
    /// One card for the busiest project with no memory that may be asked.
    pub(super) fn maybe_offer_goal(&mut self, now: f64) {
        if !self.goal_cards.is_empty() {
            return;
        }
        let records = observations::read_records(&self.dir.join(observations::FILE_NAME));
        let repo = busy_repos(&records, now).into_iter().find(|repo| {
            self.goal_offers.may_ask(repo, now) && self.memory.show(repo)["text"].as_str().is_none_or(|t| t.trim().is_empty())
        });
        let Some(repo) = repo else { return };
        let lang = self.config.language;
        let name = Path::new(&repo).file_name().and_then(|n| n.to_str()).unwrap_or(&repo).to_string();
        let id = self.mint(PREFIX);
        let message = lang.pick(
            &format!("You are busy in {name}, and I know nothing of where it is going. What is its final goal? I will remember it and tell every agent there."),
            &format!("你最近常在 {name} 干活，但我不知道这个项目最终要做成什么。告诉我它的最终目标？我会记下来，并告诉在那里工作的每个 agent。"),
        ).to_string();
        let options = vec![
            lang.pick("Tell you the goal", "说一下目标").to_string(),
            lang.pick("Later", "以后再说").to_string(),
            lang.pick("Don't ask for this one", "这个项目不用记").to_string(),
        ];
        self.put_card(seahelm_core_registry::cards::CardKind::Proposal, &id, message, options, super::budget::Class::Proactive, now);
        self.log(super::engine::Entry::new(now, "approval", format!("asked for the goal of {repo}")));
        self.goal_offers.asked.insert(repo.clone(), Asked { status: "offered".into(), at: now });
        self.goal_offers.save(&self.dir);
        self.goal_cards.insert(id, repo);
    }

    /// The user's answer. Tell starts a turn that asks; later, or a dismissal,
    /// waits `LATER_DAYS`; don't is for good.
    pub(super) fn answer_goal(&mut self, payload: &str, option: Option<&str>, now: f64) -> bool {
        let Some(repo) = self.goal_cards.remove(payload) else { return false };
        let status = match option {
            Some("choice:0") => {
                self.tell(&ask_prompt(&repo));
                "asked"
            }
            Some("choice:1") | None => "later",
            _ => "declined",
        };
        self.log(super::engine::Entry::new(now, "approval", format!("goal of {repo}: {status}")));
        self.goal_offers.asked.insert(repo, Asked { status: status.into(), at: now });
        self.goal_offers.save(&self.dir);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: f64 = 86_400.0;
    const NOW: f64 = 1_794_000_000.0;

    fn created(repo: &str, at: f64, by: &str) -> Record {
        Record {
            id: format!("obs-{}", (at * 1000.0) as u64),
            at: super::super::engine::iso8601(at),
            kind: observations::kind::WORKTREE_CREATED.into(),
            repo: repo.into(),
            by: by.into(),
            ..Record::default()
        }
    }

    #[test]
    fn busy_means_three_worktrees_this_week_not_counting_first_mates() {
        let records = vec![
            created("/w/a", NOW - DAY, "user"),
            created("/w/a", NOW - 2.0 * DAY, "agent"),
            created("/w/a", NOW - 3.0 * DAY, "user"),
            created("/w/b", NOW - DAY, "user"),
            created("/w/b", NOW - 2.0 * DAY, "first_mate"),
            created("/w/b", NOW - 3.0 * DAY, "research:mux-news"),
            created("/w/c", NOW - DAY, "user"),
            created("/w/c", NOW - 2.0 * DAY, "user"),
            created("/w/c", NOW - 8.0 * DAY, "user"),
        ];
        assert_eq!(busy_repos(&records, NOW), vec!["/w/a".to_string()]);
    }

    #[test]
    fn later_asks_again_after_two_weeks_and_declined_never() {
        let mut s = State::default();
        assert!(s.may_ask("/w/a", NOW));
        s.asked.insert("/w/a".into(), Asked { status: "later".into(), at: NOW });
        assert!(!s.may_ask("/w/a", NOW + 13.0 * DAY));
        assert!(s.may_ask("/w/a", NOW + 14.0 * DAY));
        for status in ["declined", "asked", "offered"] {
            s.asked.insert("/w/a".into(), Asked { status: status.into(), at: NOW });
            assert!(!s.may_ask("/w/a", NOW + 100.0 * DAY));
        }
    }

    #[test]
    fn the_prompt_asks_and_stores_only_the_users_words() {
        let p = ask_prompt("/w/saas");
        assert!(p.contains("seahelm memory note /w/saas \"goal: <their words>\""));
        assert!(p.contains("nothing you inferred"));
    }

    fn mate(dir: &Path) -> super::super::FirstMate {
        let core = crate::core::Core::for_test(dir);
        core.ensure_first_mate_pane(&dir.to_string_lossy());
        let (tx, _) = std::sync::mpsc::channel();
        let mut fm = super::super::FirstMate::new(core, tx, dir.into(), dir.join("habits"));
        fm.running = true;
        fm
    }

    fn write_records(dir: &Path, records: &[Record]) {
        let text: String = records.iter().map(|r| serde_json::to_string(r).unwrap() + "\n").collect();
        std::fs::write(dir.join(observations::FILE_NAME), text).unwrap();
    }

    #[test]
    fn a_busy_project_without_memory_gets_one_card_and_answers_stick() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        let repo = dir.join("saas").to_string_lossy().into_owned();
        let now = seahelm_core_types::now();
        write_records(dir, &[created(&repo, now - DAY, "user"), created(&repo, now - 2.0 * DAY, "user"), created(&repo, now - 3.0 * DAY, "agent")]);
        let mut fm = mate(dir);

        fm.maybe_offer_goal(now);
        let id = fm.goal_cards.keys().next().cloned().expect("a goal card");
        // One at a time.
        fm.maybe_offer_goal(now);
        assert_eq!(fm.goal_cards.len(), 1);

        fm.answered(&id, Some("choice:1"), None, now);
        assert!(fm.goal_cards.is_empty());
        assert_eq!(State::load(dir).asked[&observations::norm(&repo)].status, "later");
        // Not again for two weeks.
        fm.maybe_offer_goal(now + DAY);
        assert!(fm.goal_cards.is_empty());

        // A project that already has memory is not asked.
        let tmp2 = tempfile::tempdir().unwrap();
        let dir2 = tmp2.path();
        let repo2 = dir2.join("seahelm").to_string_lossy().into_owned();
        write_records(dir2, &[created(&repo2, now - DAY, "user"), created(&repo2, now - 2.0 * DAY, "user"), created(&repo2, now - 3.0 * DAY, "user")]);
        let mut fm2 = mate(dir2);
        fm2.memory.note(&observations::norm(&repo2), "goal: a terminal for agents", "user").unwrap();
        fm2.maybe_offer_goal(now);
        assert!(fm2.goal_cards.is_empty());
    }
}
