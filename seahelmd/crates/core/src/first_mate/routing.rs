//! Project routing uses the user's words, never a model's assertion of intent.
use super::{
    habits::{self, Do, HabitLevel},
    rules::{Action, Level},
    FirstMate, Gate,
};
use serde_json::{json, Value};
use std::path::Path;

pub fn main_repo(path: &str) -> String {
    super::facts::git(Path::new(path), &["rev-parse", "--path-format=absolute", "--git-common-dir"])
        .and_then(|p| Path::new(p.trim()).parent().map(|p| p.to_string_lossy().into_owned()))
        .unwrap_or_else(|| path.into())
}
pub fn words(text: &str) -> String {
    text.split_whitespace().map(|s| s.to_lowercase()).collect::<Vec<_>>().join(" ")
}
pub fn names(text: &str, name: &str) -> bool {
    let text = text.to_lowercase();
    let name = name.to_lowercase();
    !name.is_empty()
        && text.match_indices(&name).any(|(i, _)| {
            let word = |c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-';
            text[..i].chars().next_back().is_none_or(|c| !word(c)) && text[i + name.len()..].chars().next().is_none_or(|c| !word(c))
        })
}
pub fn issue_link(text: &str) -> Option<(String, u64)> {
    for word in text.split_whitespace() {
        let url = word.trim_matches(|c: char| matches!(c, '(' | ')' | '<' | '>' | ',' | '.'));
        let Some(path) = url.strip_prefix("https://github.com/") else { continue };
        let parts: Vec<_> = path.split('/').collect();
        if parts.len() >= 4 && ["issues", "pull"].contains(&parts[2]) {
            if let Ok(n) = parts[3].split(['?', '#']).next().unwrap_or_default().parse() {
                return Some((format!("{}/{}", parts[0], parts[1]).to_lowercase(), n));
            }
        }
    }
    None
}
/// Issue tokens have a task/issue prefix or begin the branch, never a version/path/SHA digit run.
pub fn issue_number_in(name: &str, n: u64) -> bool {
    let name = name.trim().trim_start_matches("refs/heads/").trim_start_matches("refs/remotes/");
    let tail = name.strip_prefix("origin/").unwrap_or(name);
    let token = tail
        .strip_prefix("fix/")
        .or_else(|| tail.strip_prefix("feat/"))
        .or_else(|| tail.strip_prefix("issue/"))
        .or_else(|| tail.strip_prefix("issue-"))
        .unwrap_or(tail);
    token.strip_prefix(&n.to_string()).is_some_and(|rest| rest.is_empty() || rest.starts_with('-'))
}
/// Derive the issue position from the learned template, escaping every literal.
/// A template without {n} cannot identify an issue; {slug} follows branch_name's vocabulary.
pub fn issue_branch_matches(name: &str, n: u64, template: Option<&str>) -> bool {
    if issue_number_in(name, n) {
        return true;
    }
    let Some(template) = template.filter(|t| t.contains("{n}")) else {
        return false;
    };
    let pattern = regex::escape(template)
        .replace(r"\{n\}", &n.to_string())
        .replace(r"\{slug\}", r"[a-z0-9]+(?:-[a-z0-9]+)*");
    let Ok(re) = regex::Regex::new(&format!("^(?:{pattern})$")) else {
        return false;
    };
    let name = name.trim().trim_start_matches("refs/heads/").trim_start_matches("refs/remotes/");
    re.is_match(name.strip_prefix("origin/").unwrap_or(name))
}
pub fn remotes(repo: &str) -> Vec<String> {
    super::facts::git(Path::new(repo), &["remote", "-v"])
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split_whitespace().nth(1).and_then(crate::pr::github_repo))
        .collect()
}
pub fn linked_issue(text: &str, repo_remotes: &[String]) -> Option<(String, u64)> {
    issue_link(text).filter(|(owner_repo, _)| repo_remotes.iter().any(|r| r.eq_ignore_ascii_case(owner_repo)))
}
fn closes(body: &str, n: u64) -> bool {
    let re = regex::Regex::new(r"(?i)\b(?:closes|fixes|resolves)\s+#([0-9]+)\b").unwrap();
    let found = re.captures_iter(body).any(|c| c[1].parse::<u64>().ok() == Some(n));
    found
}
pub fn duplicate_issue(repo: &str, n: u64, branches: &str, worktrees: &str, prs: &[Value], template: Option<&str>) -> Option<String> {
    for wt in crate::discovery::parse_porcelain(worktrees) {
        if let Some(b) = wt.branch.filter(|b| issue_branch_matches(b, n, template)) {
            return Some(format!("{} ({b})", wt.path));
        }
    }
    if let Some(branch) = branches.lines().find(|b| issue_branch_matches(b, n, template)) {
        return Some(branch.into());
    }
    for row in prs {
        let pr = row.get("pr").unwrap_or(row);
        if row["repo"].as_str().is_some_and(|r| r.eq_ignore_ascii_case(repo))
            && matches!(pr["state"].as_str(), Some("open" | "draft" | "merged"))
            && closes(pr["body"].as_str().unwrap_or_default(), n)
        {
            return Some(format!("PR #{} {}", pr["number"], pr["url"].as_str().unwrap_or_default()));
        }
    }
    None
}
/// Requested repo first, then lexical evidence in approved aliases/descriptions.
pub fn rank_projects(mut projects: Vec<Value>, requested: &str, text: &str) -> Vec<Value> {
    let text = words(text);
    projects.sort_by_key(|p| {
        let requested = p["repo"].as_str().is_some_and(|r| super::same_path(r, requested));
        let alias = p["aliases"].as_array().into_iter().flatten().filter_map(Value::as_str).any(|a| names(&text, a));
        let score = p["description"]
            .as_str()
            .unwrap_or_default()
            .split_whitespace()
            .filter(|w| w.len() > 2 && names(&text, w))
            .count();
        (std::cmp::Reverse(requested), std::cmp::Reverse(alias), std::cmp::Reverse(score))
    });
    projects.truncate(3);
    projects
}
pub fn mandate(text: &str, name: &str, aliases: &[String], remote: Option<&str>) -> bool {
    names(text, name)
        || aliases.iter().any(|a| names(text, a))
        || issue_link(text).is_some_and(|(r, _)| remote.is_some_and(|remote| r.eq_ignore_ascii_case(remote)))
}
impl FirstMate {
    pub(super) fn project_list(&self) -> Value {
        let today = super::clock::Local::at(seahelm_core_types::now()).day_key();
        json!(self
            .all_repos()
            .into_iter()
            .map(|repo| {
                let book = self.habits.load(&habits::repo_key(&repo), &today);
                let aliases: Vec<_> = book
                    .habits
                    .iter()
                    .filter(|h| h.active() && h.act == Do::Route && h.about.starts_with("project.alias:") && book.level(h) >= HabitLevel::Ask)
                    .map(|h| h.about.trim_start_matches("project.alias:").to_string())
                    .collect();
                let memory = self.memory.context(&repo);
                let description = memory.lines().next().map(str::to_string).unwrap_or_else(|| {
                    ["README.md", "README", "readme.md"]
                        .iter()
                        .find_map(|f| std::fs::read_to_string(Path::new(&repo).join(f)).ok())
                        .map(|s| {
                            s.split("\n\n")
                                .find(|p| !p.trim().is_empty() && !p.trim().starts_with('#'))
                                .unwrap_or_default()
                                .replace('\n', " ")
                                .chars()
                                .take(240)
                                .collect()
                        })
                        .unwrap_or_default()
                });
                json!({"repo":repo, "name":super::short(&repo), "description":description, "aliases":aliases})
            })
            .collect::<Vec<_>>())
    }
    pub(super) fn route_gate(&mut self, params: &Value, now: f64) -> Option<Gate> {
        if !self.user_spoke || self.level(Action::StartAgent) == Level::Deny {
            return None;
        }
        if self.route_used || self.route_pending {
            let summary = super::lang::route_once();
            return Some(self.route_card(params, &summary, now));
        }
        let repo = main_repo(params["repo_path"].as_str().unwrap_or_default());
        if !self.all_repos().iter().any(|r| super::same_path(r, &repo)) {
            return Some(Gate::Deny(super::lang::route_unknown().get(self.config.language).into()));
        }
        // User defaults and repo rules remain hard deny boundaries.
        if self.config_for(&repo).is_err() {
            return Some(Gate::Deny(super::lang::route_unknown().get(self.config.language).into()));
        }
        let config = self.config_for(&repo).ok()?;
        let repo_cap = Path::new(&repo)
            .join(super::rules::RELATIVE_PATH)
            .exists()
            .then(|| config.autonomy(Action::StartAgent, None));
        if repo_cap == Some(Level::Deny) {
            return Some(Gate::Deny(super::lang::route_unknown().get(self.config.language).into()));
        }
        let book = self.habits.load(&habits::repo_key(&repo), &super::clock::Local::at(now).day_key());
        let aliases: Vec<String> = book
            .habits
            .iter()
            .filter(|h| h.active() && h.act == Do::Route && h.about.starts_with("project.alias:") && book.level(h) >= HabitLevel::Ask)
            .filter_map(|h| h.when.route_words().map(str::to_string))
            .collect();
        let remotes = remotes(&repo);
        if let Some((owner_repo, n)) = linked_issue(&self.route_text, &remotes) {
            let branches = super::facts::git(Path::new(&repo), &["branch", "-a", "--format=%(refname:short)"]).unwrap_or_default();
            let worktrees = super::facts::git(Path::new(&repo), &["worktree", "list", "--porcelain"]).unwrap_or_default();
            if let Some(place) = duplicate_issue(
                &owner_repo,
                n,
                &branches,
                &worktrees,
                &self.core.known_prs(),
                self.memory.value(&repo, "branch naming").as_deref(),
            ) {
                let t = super::lang::issue_existing(n, &place);
                self.core.first_mate_line(t.get(self.config.language));
                return Some(Gate::Deny(t.get(self.config.language).into()));
            }
        }
        let named = mandate(&self.route_text, &super::short(&repo), &aliases, None) || remotes.iter().any(|r| mandate(&self.route_text, "", &[], Some(r)));
        let automatic = book
            .habits
            .iter()
            .any(|h| h.active() && h.act == Do::Route && book.level(h) == HabitLevel::Auto && h.when.route_words() == Some(words(&self.route_text).as_str()));
        if named || automatic {
            if repo_cap == Some(Level::Ask) {
                return Some(self.route_card(params, &super::lang::route_confirm(), now));
            }
            self.route_pending = true;
            return Some(Gate::Allow);
        }
        let projects = self.project_list();
        let ranked = rank_projects(projects.as_array().cloned().unwrap_or_default(), &repo, &self.route_text);
        let options: Vec<Value> = ranked
            .iter()
            .map(|project| json!({"label": project["name"], "action":"worktree.create", "params":{"repo_path":project["repo"],"prompt":params["prompt"]}}))
            .collect();
        let summary = super::lang::route_choose();
        match self.propose(summary.get(self.config.language), &options, now) {
            Ok(v) => Some(Gate::Queued(v["card"].as_str().unwrap_or_default().into())),
            Err(e) => Some(Gate::Deny(e.message)),
        }
    }
    fn route_card(&mut self, params: &Value, summary: &super::lang::Text, now: f64) -> Gate {
        let option = json!({"label":super::short(params["repo_path"].as_str().unwrap_or_default()),"action":"worktree.create","params":params});
        match self.propose(summary.get(self.config.language), &[option], now) {
            Ok(v) => Gate::Queued(v["card"].as_str().unwrap_or_default().into()),
            Err(e) => Gate::Deny(e.message),
        }
    }
    pub(super) fn route_pick(&mut self, repo: &str, text: &str, card: &str, now: f64) {
        if text.is_empty() {
            return;
        }
        let repo = main_repo(repo);
        let today = super::clock::Local::at(now).day_key();
        let id = habits::route_id(&words(text));
        for other in self.all_repos().into_iter().filter(|r| !super::same_path(r, &repo)) {
            let mut book = self.habits.load(&habits::repo_key(&other), &today);
            if let Some(change) = book.rejected(&id) {
                self.save_book(&book, now);
                self.report_change(&change, now);
            }
        }
        let mut book = self.habits.load(&habits::repo_key(&repo), &today);
        book.route_pick_with_n(&words(text), &today, card, self.budget.tuned.n);
        self.save_book(&book, now);
        self.learn(now);
        self.offer_alias(&repo, text, card, now);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_user_names_aliases_or_matching_links_mandate() {
        assert!(mandate("修复 seahelm 的登录", "seahelm", &[], None));
        assert!(!mandate("seahelm-other", "seahelm", &[], None));
        assert!(mandate("fix https://github.com/Org/Repo/issues/42", "local", &[], Some("org/repo")));
        assert!(!mandate("https://github.com/other/repo/pull/42", "local", &[], Some("org/repo")));
        assert!(mandate("修复 船长", "local", &["船长".into()], None));
        assert!(issue_number_in("fix/42-login", 42));
        assert!(!issue_number_in("fix/142-login", 42));
    }
}

/// A hypothesis only: the user must approve the short name on its own card.
fn alias_matches_project(alias: &str, project: &Value) -> bool {
    let name = project["name"].as_str().unwrap_or_default().to_lowercase();
    name.split(|c: char| !c.is_alphanumeric()).any(|part| part == alias)
        || names(&name, alias)
        || names(project["description"].as_str().unwrap_or_default(), alias)
        || project["aliases"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .any(|a| names(a, alias))
}
fn short_alias(text: &str, repo: &str, projects: &[Value]) -> Option<String> {
    let stop = [
        "fix",
        "fixes",
        "update",
        "updates",
        "add",
        "adds",
        "change",
        "changes",
        "make",
        "makes",
        "create",
        "build",
        "implement",
        "remove",
        "delete",
        "improve",
        "refactor",
        "repair",
        "new",
        "please",
        "help",
        "the",
        "a",
        "an",
        "in",
        "to",
        "for",
        "and",
        "with",
        "from",
        "this",
        "that",
        "its",
        "our",
        "your",
        "my",
        "their",
        "some",
        "all",
        "can",
        "could",
        "should",
        "would",
        "login",
        "bug",
        "issue",
        "error",
        "feature",
        "code",
        "test",
        "tests",
        "dependencies",
        "dependency",
        "version",
        "readme",
        "修复",
        "更新",
        "修改",
        "添加",
        "帮我",
        "增加",
        "新增",
        "实现",
        "创建",
        "删除",
        "调整",
        "优化",
        "一下",
        "这个",
        "功能",
        "问题",
    ];
    let text = words(text).replace([',', '，', '。'], " ");
    let mut candidates: Vec<_> = text
        .split_whitespace()
        .filter(|s| !s.contains(['\'', '’']) && !s.contains("://"))
        .map(|s| {
            let cut = ["修复", "新增", "添加", "增加", "加个", "更新", "修改", "的", "登录"]
                .iter()
                .filter_map(|v| s.find(v))
                .min()
                .unwrap_or(s.len());
            s[..cut].trim_matches(|c: char| !c.is_alphanumeric() && c != '-').to_string()
        })
        .filter(|s| {
            let len = s.chars().count();
            (2..=16).contains(&len)
                && (!s.is_ascii() || len >= 3)
                && !s.chars().all(|c| c.is_ascii_digit())
                && !stop.contains(&s.as_str())
                && s != &super::short(repo).to_lowercase()
                && projects.iter().filter(|p| alias_matches_project(s, p)).take(2).count() <= 1
        })
        .collect();
    // Prefer a name component or noun grounded in the target's description.
    candidates.sort_by_key(|s| {
        std::cmp::Reverse(
            projects
                .iter()
                .any(|p| p["repo"].as_str().is_some_and(|r| super::same_path(r, repo)) && alias_matches_project(s, p)),
        )
    });
    candidates.into_iter().next()
}
impl FirstMate {
    pub(super) fn offer_alias(&mut self, repo: &str, text: &str, source: &str, now: f64) {
        let projects = self.project_list();
        let Some(alias) = short_alias(text, repo, projects.as_array().map(Vec::as_slice).unwrap_or_default()) else {
            return;
        };
        let book = self.habits.load(&habits::repo_key(repo), &super::clock::Local::at(now).day_key());
        let id = format!("alias-{}", habits::route_id(&alias));
        if book.get(&id).is_some() || self.alias_pending.values().any(|(r, a, _)| r == repo && a == &alias) {
            return;
        }
        let payload = self.mint("autopilot-alias");
        let message = super::lang::alias_offer(&alias, repo);
        self.put_card(
            seahelm_core_registry::cards::CardKind::Approval,
            &payload,
            message.get(self.config.language).into(),
            vec![super::APPROVE.into(), super::REJECT.into()],
            super::budget::Class::Answering,
            now,
        );
        self.alias_pending.insert(payload, (repo.into(), alias, source.into()));
    }
    pub(super) fn answer_alias(&mut self, payload: &str, option: Option<&str>, now: f64) -> bool {
        let Some((repo, alias, source)) = self.alias_pending.remove(payload) else {
            return false;
        };
        if option != Some("approve") {
            return true;
        }
        let today = super::clock::Local::at(now).day_key();
        let mut book = self.habits.load(&habits::repo_key(&repo), &today);
        let mut habit = habits::Habit::seed(&today);
        habit.id = format!("alias-{}", habits::route_id(&alias));
        habit.about = format!("project.alias:{alias}");
        habit.when = habits::When::parse_yaml(&format!("request_words: {}", serde_json::to_string(&alias).unwrap())).unwrap();
        habit.act = Do::Route;
        habit.level = HabitLevel::Ask;
        habit.origin = habits::Origin::Learned;
        habit.sources = vec![source, payload.into()];
        habit.approved = Some(today.clone());
        let grant = habits::Grant::from_alias_card(&book.key, &habit.id);
        if book.adopt(habit, grant, &today).is_ok() {
            self.save_book(&book, now);
        }
        true
    }
}

#[cfg(test)]
mod gate_tests {
    use super::*;
    use crate::{
        core::Core,
        first_mate::{Msg, APPROVE, REJECT},
    };
    use std::sync::mpsc;
    fn git(repo: &Path, args: &[&str]) {
        let out = std::process::Command::new("git").arg("-C").arg(repo).args(args).output().unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    }
    fn fixture(dir: &Path, name: &str) -> (FirstMate, String) {
        let repo = dir.join(name);
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-b", "main"]);
        git(
            &repo,
            &[
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "--allow-empty",
                "-m",
                "init",
            ],
        );
        git(&repo, &["remote", "add", "origin", "https://github.com/org/repo.git"]);
        let core = Core::for_test(dir);
        core.ensure_first_mate_pane(&dir.to_string_lossy());
        let (tx, _) = mpsc::channel();
        let mut fm = FirstMate::new(core, tx, dir.into(), dir.join("habits"));
        fm.running = true;
        fm.user_spoke = true;
        fm.route_text = format!("fix {name}");
        let repo = repo.to_string_lossy().into_owned();
        fm.test_repos = Some(vec![repo.clone()]);
        (fm, repo)
    }
    #[test]
    fn mandate_is_consumed_by_success_not_gate_and_second_start_is_a_card() {
        let tmp = tempfile::tempdir().unwrap();
        let (mut fm, repo) = fixture(tmp.path(), "project");
        let p = json!({"repo_path":repo,"prompt":"fix login"});
        assert_eq!(fm.route_gate(&p, 1.), Some(Gate::Allow));
        assert!(!fm.route_used);
        fm.handle(Msg::CreateFailed);
        assert!(!fm.route_pending);
        assert_eq!(fm.route_gate(&p, 2.), Some(Gate::Allow));
        fm.did_run("worktree.create", &json!({"worktree_path":"/scratch/new"}));
        assert!(fm.route_used);
        let Some(Gate::Queued(card)) = fm.route_gate(&p, 3.) else { panic!() };
        assert!(fm.proposals.contains_key(&card));
    }
    #[test]
    fn repo_ask_success_also_consumes_the_turn_and_candidates_keep_requested_repo() {
        let tmp = tempfile::tempdir().unwrap();
        let (mut fm, repo) = fixture(tmp.path(), "project");
        std::fs::create_dir_all(Path::new(&repo).join(".seahelm")).unwrap();
        std::fs::write(Path::new(&repo).join(".seahelm/automations.yml"), "autonomy: {start_agent: ask}\nrules: []\n").unwrap();
        let p = json!({"repo_path":repo,"prompt":"fix login"});
        // The repo's ask cap produces a regular approval, whose successful result spends the mandate.
        assert!(matches!(fm.route_gate(&p, 1.), Some(Gate::Queued(_))));
        fm.did_run("worktree.create", &json!({"worktree_path":"/scratch/approved"}));
        assert!(matches!(fm.route_gate(&p, 2.), Some(Gate::Queued(_))));
        fm.route_used = false;
        fm.route_text = "unmapped request".into();
        fm.test_repos = Some(vec!["/nonexistent/a".into(), "/nonexistent/b".into(), "/nonexistent/c".into(), repo.clone()]);
        let Some(Gate::Queued(card)) = fm.route_gate(&p, 3.) else { panic!() };
        assert_eq!(fm.proposals[&card].options[0].params["repo_path"], repo);
        assert_eq!(fm.proposals[&card].options.len(), 3);
    }
    #[test]
    fn issue_gate_ignores_shas_versions_paths_and_other_repo_links() {
        let tmp = tempfile::tempdir().unwrap();
        let (mut fm, repo) = fixture(tmp.path(), "path-42");
        git(Path::new(&repo), &["branch", "v42.0"]);
        fm.route_text = "https://github.com/org/repo/issues/42".into();
        let p = json!({"repo_path":repo,"prompt":fm.route_text});
        assert_eq!(fm.route_gate(&p, 1.), Some(Gate::Allow));
        fm.handle(Msg::CreateFailed);
        git(Path::new(&repo), &["branch", "fix/42-login"]);
        assert!(matches!(fm.route_gate(&p, 2.), Some(Gate::Deny(_))));
        fm.route_text = "path-42 https://github.com/other/repo/issues/42".into();
        assert_eq!(fm.route_gate(&p, 3.), Some(Gate::Allow));
    }
    #[test]
    fn outside_edit_card_reject_restores_then_note_is_writable_and_accept_is_exact() {
        let tmp = tempfile::tempdir().unwrap();
        let (mut fm, repo) = fixture(tmp.path(), "project");
        fm.memory.note(&repo, "goal: trusted", "user").unwrap();
        let path = fm.memory.dir.join(format!("{}.md", habits::repo_key(&repo)));
        let original = std::fs::read_to_string(&path).unwrap();
        std::fs::write(&path, original.replace("trusted", "outside")).unwrap();
        fm.check_memory_edits(1.);
        assert_eq!(fm.memory_pending.len(), 1);
        let card = fm.memory_pending.keys().next().unwrap().clone();
        assert_eq!(fm.core.cards_with_payloads(|p| p == card).len(), 1);
        fm.check_memory_edits(2.);
        assert_eq!(fm.memory_pending.len(), 1);
        fm.core.drop_card_payload(&card);
        fm.answered(&card, Some(REJECT), None, 3.);
        assert!(fm.memory_pending.is_empty());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
        fm.memory.note(&repo, "goal: next", "user").unwrap();
        let next = std::fs::read_to_string(&path).unwrap();
        std::fs::write(&path, next.replace("next", "confirmed")).unwrap();
        fm.check_memory_edits(4.);
        let card = fm.memory_pending.keys().next().unwrap().clone();
        fm.core.drop_card_payload(&card);
        fm.answered(&card, Some(APPROVE), None, 5.);
        assert!(fm.memory_pending.is_empty());
        assert!(fm.memory.context(&repo).contains("confirmed"));
    }
    #[test]
    fn short_alias_needs_its_own_card_then_mandates_a_new_request() {
        let tmp = tempfile::tempdir().unwrap();
        let (mut fm, repo) = fixture(tmp.path(), "project");
        fm.offer_alias(&repo, "官网 修复 登录", "candidate-card", 1.);
        let card = fm.alias_pending.keys().next().unwrap().clone();
        assert_eq!(fm.alias_pending[&card].1, "官网");
        let p = json!({"repo_path":repo,"prompt":"new feature"});
        fm.route_text = "官网 新功能".into();
        assert!(matches!(fm.route_gate(&p, 2.), Some(Gate::Queued(_))));
        fm.answered(&card, Some(APPROVE), None, 3.);
        assert_eq!(fm.route_gate(&p, 4.), Some(Gate::Allow));
    }
    #[test]
    fn localized_memory_and_alias_cards_keep_their_approval_identity() {
        let tmp=tempfile::tempdir().unwrap(); let (mut fm,repo)=fixture(tmp.path(),"project");
        fm.config.language=super::super::lang::Lang::Zh;
        fm.offer_alias(&repo,"官网","picked-project",1.);
        let card=fm.alias_pending.keys().next().unwrap().clone();
        let choices=&fm.card_options[&card];
        assert_eq!(choices[0].key,"approve"); assert_eq!(choices[0].label,"批准");
        let label=choices[0].label.clone(); fm.answered(&card,Some(&label),None,2.);
        assert!(fm.alias_pending.is_empty());
        fm.route_text="官网 新功能".into();
        assert_eq!(fm.route_gate(&json!({"repo_path":repo,"prompt":"new feature"}),3.),Some(Gate::Allow));
        fm.memory.note(&repo,"goal: trusted","user").unwrap();
        let path=fm.memory.dir.join(format!("{}.md",habits::repo_key(&repo)));
        let original=std::fs::read_to_string(&path).unwrap();
        std::fs::write(&path,original.replace("trusted","confirmed")).unwrap();
        fm.check_memory_edits(4.); let card=fm.memory_pending.keys().next().unwrap().clone();
        let label=fm.card_options[&card][0].label.clone(); assert_eq!(label,"批准");
        fm.answered(&card,Some(&label),None,5.);
        assert!(fm.memory.context(&repo).contains("confirmed"));
    }

    #[test]
    fn ranks_requested_then_alias_then_description_matches() {
        let projects = vec![
            json!({"repo":"/nonexistent/a","description":"ordinary repo"}),
            json!({"repo":"/nonexistent/b","aliases":["官网"]}),
            json!({"repo":"/nonexistent/c","description":"login service"}),
            json!({"repo":"/nonexistent/d","description":"requested"}),
        ];
        let ranked = rank_projects(projects, "/nonexistent/d", "官网 login");
        assert_eq!(
            ranked.iter().map(|p| p["repo"].as_str().unwrap()).collect::<Vec<_>>(),
            vec!["/nonexistent/d", "/nonexistent/b", "/nonexistent/c"]
        );
        assert_eq!(short_alias("官网加个页面", "/nonexistent/d", &[]).as_deref(), Some("官网"));
    }

    #[test]
    fn learned_templates_identify_the_issue_position_without_digit_false_positives() {
        for (template, branch) in [
            ("bug/{n}-{slug}", "bug/42-login"),
            ("work/issue-{n}/{slug}", "work/issue-42/login"),
            ("bug.v2/{slug}-{n}", "bug.v2/login-42"),
        ] {
            assert!(issue_branch_matches(branch, 42, Some(template)));
            assert!(!issue_branch_matches(branch, 142, Some(template)));
            assert!(!issue_branch_matches(&branch.replace("42", "142"), 42, Some(template)));
        }
        assert!(!issue_branch_matches("bugXv2/login-42", 42, Some("bug.v2/{slug}-{n}")));
        assert!(!issue_branch_matches("release/v42", 42, Some("release/{slug}")));
        let tmp = tempfile::tempdir().unwrap();
        let (mut fm, repo) = fixture(tmp.path(), "project");
        let root = main_repo(&repo);
        fm.memory.note(&root, "branch naming: bug/{n}-{slug}", "user").unwrap();
        git(Path::new(&repo), &["branch", "bug/42-login"]);
        fm.route_text = "https://github.com/org/repo/issues/42".into();
        assert!(matches!(fm.route_gate(&json!({"repo_path":repo,"prompt":fm.route_text}),1.),Some(Gate::Deny(place)) if place.contains("bug/42-login")));
        let worktrees = "worktree /scratch/real-place\nHEAD 42abc\nbranch refs/heads/bug/42-login\n";
        assert!(duplicate_issue("org/repo", 42, "", worktrees, &[], Some("bug/{n}-{slug}"))
            .unwrap()
            .contains("/scratch/real-place"));
    }

    #[test]
    fn alias_guesses_skip_verbs_possessives_short_and_ambiguous_words() {
        let projects = vec![
            json!({"repo":"/nonexistent/shop","name":"team-storefront","description":"commerce checkout shared"}),
            json!({"repo":"/nonexistent/docs","name":"documentation","description":"shared manuals"}),
        ];
        assert!(short_alias("update fix add change make seahelm's ui it go", "/nonexistent/shop", &projects).is_none());
        assert_eq!(
            short_alias("change shared storefront", "/nonexistent/shop", &projects).as_deref(),
            Some("storefront")
        );
        assert!(short_alias("shared", "/nonexistent/shop", &projects).is_none());
        assert_eq!(short_alias("fix unknown checkout", "/nonexistent/shop", &projects).as_deref(), Some("checkout"));
        let tmp = tempfile::tempdir().unwrap();
        let (mut fm, repo) = fixture(tmp.path(), "project");
        let other = tmp.path().join("other");
        std::fs::create_dir(&other).unwrap();
        std::fs::write(Path::new(&repo).join("README.md"), "shared commerce").unwrap();
        std::fs::write(other.join("README.md"), "shared documentation").unwrap();
        fm.test_repos = Some(vec![repo.clone(), other.to_string_lossy().into_owned()]);
        fm.offer_alias(&repo, "shared", "model-option", 1.);
        fm.offer_alias(&repo, "update seahelm’s ui", "model-option", 2.);
        assert!(fm.alias_pending.is_empty());
    }

    #[test]
    fn linked_checkout_reads_branch_convention_by_the_main_repo_key() {
        let tmp = tempfile::tempdir().unwrap();
        let (fm, repo) = fixture(tmp.path(), "project");
        let linked = tmp.path().join("linked");
        git(Path::new(&repo), &["worktree", "add", "-b", "scratch", linked.to_str().unwrap()]);
        let root = main_repo(&repo);
        fm.memory.note(&root, "branch naming: bug/{n}-{slug}", "user").unwrap();
        assert_eq!(main_repo(linked.to_str().unwrap()), root);
        assert_eq!(
            fm.memory.value(&main_repo(linked.to_str().unwrap()), "branch naming").as_deref(),
            Some("bug/{n}-{slug}")
        );
        assert!(!fm.memory.pointer(&root).contains("bug/{n}"));
    }

    #[test]
    fn dedupe_matches_issue_tokens_and_closing_prs_only() {
        for branch in ["fix/42-login", "42-login", "issue-42", "origin/fix/42-x"] {
            assert!(issue_number_in(branch, 42));
        }
        for branch in ["release/42", "v42.0", "fix/142-x", "/scratch/42/repo", "HEAD 42abcdef"] {
            assert!(!issue_number_in(branch, 42));
        }
        let porcelain = "worktree /scratch/42\nHEAD 42abcdef\nbranch refs/heads/main\n";
        assert!(duplicate_issue("o/r", 42, "v42.0", porcelain, &[], None).is_none());
        let pr = json!({"repo":"o/r","pr":{"number":99,"state":"open","body":"Closes #42","url":"https://github.com/o/r/pull/99"}});
        assert!(duplicate_issue("o/r", 42, "", porcelain, &[pr.clone()], None).unwrap().contains("PR #99"));
        assert!(duplicate_issue("other/r", 42, "", "", &[pr.clone()], None).is_none());
        let mut closed = pr.clone();
        closed["pr"]["state"] = json!("closed");
        assert!(duplicate_issue("o/r", 42, "", "", &[closed], None).is_none());
        let mut unrelated = pr;
        unrelated["pr"]["body"] = json!("Discuss #42, fixes #142");
        assert!(duplicate_issue("o/r", 42, "", "", &[unrelated], None).is_none());
        assert!(linked_issue("https://github.com/other/r/issues/42", &["o/r".into()]).is_none());
    }
}
