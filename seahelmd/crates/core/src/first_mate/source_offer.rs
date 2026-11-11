//! Offering a task source where the user already works on issues (autonomy
//! D36). Phase 8's sources were only ever added with `seahelm task-source
//! add`; in field use the user worked a week on one repo's issues — issue
//! links pasted into new worktrees, `issue 11326` as the task — while the
//! only source configured was another repo's.
//!
//! So: when a worktree is made for an issue (its task names one, or its
//! branch starts with one) in a repo with a GitHub remote and no task
//! source, First Mate offers once to watch that repo's issues — assigned to
//! the user (the default), or all of them, or not. Asked once per repo, an
//! answer or not; only the user's answer adds a source, so the core never
//! adds one on its own.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

use super::observations::{self, Record};

/// Card payloads: `task-source.offer:<n>`.
pub const PREFIX: &str = "task-source.offer";
/// `first-mate/source-offers.json`.
pub const FILE: &str = "source-offers.json";

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct State {
    /// The newest observation already looked at (`obs-<ms>`). Empty: none
    /// yet, so the first look only moves it to the end — history is not
    /// offered for.
    #[serde(default)]
    pub cursor: String,
    /// Per repo (main checkout): what came of the offer — `offered`,
    /// `assigned`, `all`, `declined`.
    #[serde(default)]
    pub asked: BTreeMap<String, String>,
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

    /// Worktrees made since the cursor, moving it past them. The first call
    /// returns nothing.
    pub fn new_worktrees(&mut self, records: &[Record]) -> Vec<Record> {
        let Some(last) = records.last() else { return Vec::new() };
        if self.cursor.is_empty() {
            self.cursor = last.id.clone();
            return Vec::new();
        }
        let after = obs_number(&self.cursor);
        let out = records
            .iter()
            .filter(|r| obs_number(&r.id) > after && r.kind == observations::kind::WORKTREE_CREATED)
            .cloned()
            .collect();
        if obs_number(&last.id) > after {
            self.cursor = last.id.clone();
        }
        out
    }
}

fn obs_number(id: &str) -> u64 {
    id.strip_prefix("obs-").and_then(|n| n.parse().ok()).unwrap_or(0)
}

/// The GitHub repo (`owner/repo`) a new worktree's issue belongs to, when its
/// task or branch names one: an issue link to one of `remotes`, `issue 12` /
/// `#12` in the task, or a branch whose last part starts with the number
/// (`fix/11657-…`, `task/issue-11326`). None when the repo has no GitHub
/// remote or nothing names an issue.
pub fn issue_repo(prompt: &str, branch: &str, remotes: &[String]) -> Option<String> {
    let first = remotes.first()?;
    if let Some((linked, _)) = super::routing::issue_link(prompt) {
        // A link to another repo's issue is not about this one.
        return remotes.iter().find(|r| r.eq_ignore_ascii_case(&linked)).cloned();
    }
    static WORDS: OnceLock<regex::Regex> = OnceLock::new();
    static BRANCH: OnceLock<regex::Regex> = OnceLock::new();
    let words = WORDS.get_or_init(|| regex::Regex::new(r"(?i)(?:\bissues?\s*#?\s*|(?:^|\s)#)\d+\b").unwrap());
    let branch_re = BRANCH.get_or_init(|| regex::Regex::new(r"(?i)^(?:issue[-_/]?)?\d+(?:-|$)").unwrap());
    let tail = branch.trim().rsplit('/').next().unwrap_or_default();
    (words.is_match(prompt) || branch_re.is_match(tail)).then(|| first.clone())
}

impl super::FirstMate {
    /// Look at the worktrees made since the last look, and offer a source
    /// for the first repo that qualifies (one card at a time).
    pub(super) fn maybe_offer_source(&mut self, now: f64) {
        let records = observations::read_records(&self.dir.join(observations::FILE_NAME));
        let before = self.source_offers.clone();
        for r in self.source_offers.new_worktrees(&records) {
            if r.repo.is_empty() || r.by == "first_mate" || !self.source_offer_cards.is_empty() {
                continue;
            }
            let repo = observations::norm(&r.repo);
            if self.source_offers.asked.contains_key(&repo) || super::task_sources::has_source(&self.dir, &repo) {
                continue;
            }
            let prompt = r.fields.get("prompt").and_then(serde_json::Value::as_str).unwrap_or_default();
            let Some(github) = issue_repo(prompt, &r.branch, &super::routing::remotes(&repo)) else { continue };
            self.raise_source_offer(&repo, &github, now);
        }
        if self.source_offers != before {
            self.source_offers.save(&self.dir);
        }
    }

    fn raise_source_offer(&mut self, repo: &str, github: &str, now: f64) {
        let lang = self.config.language;
        let id = self.mint(PREFIX);
        let name = Path::new(repo).file_name().and_then(|n| n.to_str()).unwrap_or(repo);
        let message = lang.pick(
            &format!("You are working on {name}'s issues. Watch {github} for issues to bring into the daily brief?"),
            &format!("你在处理 {name} 的 issue。要我关注 {github}，把 issue 放进每日简报吗？"),
        ).to_string();
        let options = vec![
            lang.pick("Issues assigned to me", "关注指派给我的").to_string(),
            lang.pick("All open issues", "关注全部").to_string(),
            lang.pick("No thanks", "不用").to_string(),
        ];
        // Answering, not proactive: it follows a worktree the user just made,
        // so they are at the desk, and it waits on nothing else.
        self.put_card(seahelm_core_registry::cards::CardKind::Proposal, &id, message, options, super::budget::Class::Answering, now);
        self.log(super::engine::Entry::new(now, "approval", format!("offered a task source: {github} for {repo}")));
        self.source_offers.asked.insert(repo.to_string(), "offered".into());
        self.source_offer_cards.insert(id, (repo.to_string(), github.to_string()));
    }

    /// The user's answer to an offer. Any answer but a watch — dismissing
    /// included — is a no: the repo is not asked again.
    pub(super) fn answer_source_offer(&mut self, payload: &str, option: Option<&str>, now: f64) -> bool {
        let Some((repo, github)) = self.source_offer_cards.remove(payload) else { return false };
        let lang = self.config.language;
        let watch = match option {
            Some("choice:0") => Some(true),
            Some("choice:1") => Some(false),
            _ => None,
        };
        let outcome = match watch {
            Some(assigned) => match super::task_sources::add_github(&self.dir, &repo, &github, assigned) {
                Ok(()) => {
                    let whose = if assigned { lang.pick("issues assigned to you", "指派给你的 issue") } else { lang.pick("all open issues", "全部未关闭的 issue") };
                    self.core.first_mate_line(&lang.pick(
                        &format!("Watching {github}: {whose}, read every 30 minutes; candidates go into the daily brief. Nothing is written back to GitHub."),
                        &format!("开始关注 {github}：{whose}，每 30 分钟读取一次，候选任务放进每日简报。不会往 GitHub 写任何东西。"),
                    ));
                    if assigned { "assigned" } else { "all" }
                }
                Err(e) => {
                    self.core.first_mate_line(&format!("{}: {e}", lang.pick("Could not add the task source", "未能添加任务来源")));
                    "failed"
                }
            },
            None => "declined",
        };
        self.log(super::engine::Entry::new(now, "approval", format!("task source offer for {repo}: {outcome}")));
        self.source_offers.asked.insert(repo, outcome.into());
        self.source_offers.save(&self.dir);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(id: &str, kind: &str) -> Record {
        Record { id: id.into(), kind: kind.into(), ..Record::default() }
    }

    #[test]
    fn issues_are_named_by_link_words_or_branch() {
        let remotes = vec!["betlysaas/betly".to_string()];
        let r = |p: &str, b: &str| issue_repo(p, b, &remotes);
        assert_eq!(r("https://github.com/betlysaas/betly/issues/11230", "task/x").as_deref(), Some("betlysaas/betly"));
        assert_eq!(r("issue 11326", "task/whatever").as_deref(), Some("betlysaas/betly"));
        assert_eq!(r("修一下 #42 的问题", "task/a").as_deref(), Some("betlysaas/betly"));
        assert_eq!(r("", "fix/11657-https-github-com-betlysaas").as_deref(), Some("betlysaas/betly"));
        assert_eq!(r("", "task/issue-11326-48-https").as_deref(), Some("betlysaas/betly"));
        // Not an issue.
        assert_eq!(r("渠道对账模块优化", "task/agent"), None);
        assert_eq!(r("bump to v2", "release/2.0"), None);
        assert_eq!(r("see foo#3x", "task/cai-wu"), None);
        // Another repo's issue, or no GitHub remote at all.
        assert_eq!(r("https://github.com/other/repo/issues/1", "fix/1-x"), None);
        assert_eq!(issue_repo("issue 12", "fix/12", &[]), None);
    }

    fn git(dir: &Path, args: &[&str]) {
        assert!(std::process::Command::new("git").arg("-C").arg(dir).args(args).output().unwrap().status.success());
    }

    fn append(dir: &Path, r: &Record) {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new().create(true).append(true).open(dir.join(observations::FILE_NAME)).unwrap();
        writeln!(f, "{}", serde_json::to_string(r).unwrap()).unwrap();
    }

    fn created(id: &str, repo: &str, branch: &str, prompt: &str) -> Record {
        let mut r = rec(id, observations::kind::WORKTREE_CREATED);
        r.repo = repo.into();
        r.branch = branch.into();
        r.by = "user".into();
        r.fields.insert("prompt".into(), serde_json::json!(prompt));
        r
    }

    #[test]
    fn an_issue_worktree_offers_a_source_once_and_a_yes_adds_it() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        let repo = dir.join("saas");
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-b", "main"]);
        git(&repo, &["remote", "add", "origin", "git@github.com:org/saas.git"]);
        let repo = repo.to_string_lossy().into_owned();
        let core = crate::core::Core::for_test(dir);
        core.ensure_first_mate_pane(&dir.to_string_lossy());
        let (tx, _) = std::sync::mpsc::channel();
        let mut fm = super::super::FirstMate::new(core, tx, dir.into(), dir.join("habits"));
        fm.running = true;

        // What was there before First Mate looked is history.
        append(dir, &created("obs-1", &repo, "fix/7-old", "issue 7"));
        fm.maybe_offer_source(1.0);
        assert!(fm.source_offer_cards.is_empty());

        // A worktree that names no issue is not one.
        append(dir, &created("obs-2", &repo, "task/agent", "渠道对账模块优化"));
        fm.maybe_offer_source(2.0);
        assert!(fm.source_offer_cards.is_empty());

        append(dir, &created("obs-3", &repo, "task/issue-11326", "issue 11326"));
        fm.maybe_offer_source(3.0);
        let (id, (offered_repo, github)) = fm.source_offer_cards.iter().next().map(|(k, v)| (k.clone(), v.clone())).expect("an offer");
        assert_eq!((offered_repo.as_str(), github.as_str()), (observations::norm(&repo).as_str(), "org/saas"));
        assert_eq!(fm.source_offers.asked[&observations::norm(&repo)], "offered");

        fm.answered(&id, Some("Issues assigned to me"), None, 4.0);
        assert!(super::super::task_sources::has_source(dir, &repo));
        assert_eq!(fm.source_offers.asked[&observations::norm(&repo)], "assigned");
        let listed = super::super::task_sources::rpc_at(dir, "task-source.list", &serde_json::json!({"repo": observations::norm(&repo)}), &super::super::task_sources::Live).unwrap();
        assert_eq!(listed["sources"][0]["github"], "org/saas");
        assert_eq!(listed["sources"][0]["assigned_to_me"], true);

        // Asked once: another issue worktree there raises nothing.
        append(dir, &created("obs-4", &repo, "fix/12-y", "issue 12"));
        fm.maybe_offer_source(5.0);
        assert!(fm.source_offer_cards.is_empty());
        assert_eq!(State::load(dir).cursor, "obs-4");
    }

    #[test]
    fn a_no_is_kept_and_adds_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        let repo = dir.join("r");
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-b", "main"]);
        git(&repo, &["remote", "add", "origin", "https://github.com/o/r.git"]);
        let repo = repo.to_string_lossy().into_owned();
        let core = crate::core::Core::for_test(dir);
        core.ensure_first_mate_pane(&dir.to_string_lossy());
        let (tx, _) = std::sync::mpsc::channel();
        let mut fm = super::super::FirstMate::new(core, tx, dir.into(), dir.join("habits"));
        fm.running = true;
        append(dir, &rec("obs-1", "card.answered"));
        fm.maybe_offer_source(1.0);
        append(dir, &created("obs-2", &repo, "fix/3-z", ""));
        fm.maybe_offer_source(2.0);
        let id = fm.source_offer_cards.keys().next().cloned().expect("an offer");
        fm.answered(&id, None, None, 3.0);
        assert!(!super::super::task_sources::has_source(dir, &repo));
        assert_eq!(State::load(dir).asked[&observations::norm(&repo)], "declined");
    }

    #[test]
    fn only_worktrees_made_after_the_first_look_count() {
        let mut s = State::default();
        let old = vec![rec("obs-1", observations::kind::WORKTREE_CREATED), rec("obs-2", "worktree.removed")];
        assert!(s.new_worktrees(&old).is_empty());
        assert_eq!(s.cursor, "obs-2");
        let mut more = old.clone();
        more.push(rec("obs-3", observations::kind::WORKTREE_CREATED));
        more.push(rec("obs-4", "card.answered"));
        let new = s.new_worktrees(&more);
        assert_eq!(new.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), vec!["obs-3"]);
        assert_eq!(s.cursor, "obs-4");
        assert!(s.new_worktrees(&more).is_empty());
    }
}
