//! Project routing uses the user's words, never a model's assertion of intent.
use super::{
    habits::{self, Do, HabitLevel},
    memory,
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
pub fn issue_number_in(name: &str, n: u64) -> bool {
    name.split(|c: char| !c.is_ascii_digit()).any(|s| s == n.to_string())
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
                    .filter(|h| h.active() && h.act == Do::Route && book.level(h) == HabitLevel::Auto)
                    .map(|h| h.about.trim_start_matches("project.route:").to_string())
                    .collect();
                let memory = memory::Store::local().context(&repo);
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
        if self.route_used {
            return Some(Gate::Deny(super::lang::route_once().get(self.config.language).into()));
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
            .filter(|h| h.active() && h.act == Do::Route && book.level(h) == HabitLevel::Auto)
            .filter_map(|h| h.when.route_words().map(str::to_string))
            .collect();
        let remotes: Vec<String> = super::facts::git(Path::new(&repo), &["remote", "-v"])
            .unwrap_or_default()
            .lines()
            .filter_map(|l| l.split_whitespace().nth(1).and_then(crate::pr::github_repo))
            .collect();
        if let Some((owner_repo, n)) = issue_link(&self.route_text) {
            if remotes.iter().any(|r| r.eq_ignore_ascii_case(&owner_repo)) {
                let branches = super::facts::git(Path::new(&repo), &["branch", "-a", "--format=%(refname:short)"]).unwrap_or_default();
                let worktrees = super::facts::git(Path::new(&repo), &["worktree", "list", "--porcelain"]).unwrap_or_default();
                let existing = branches.lines().chain(worktrees.lines()).find(|line| issue_number_in(line, n));
                if let Some(existing) = existing {
                    let t = super::lang::issue_existing(n, existing);
                    self.core.first_mate_line(t.get(self.config.language));
                    return Some(Gate::Deny(t.get(self.config.language).into()));
                }
                for row in self.core.known_prs() {
                    if row["repo"].as_str().is_some_and(|r| r.eq_ignore_ascii_case(&owner_repo))
                        && (issue_number_in(row["branch"].as_str().unwrap_or_default(), n)
                            || (self.route_text.contains(&format!("/pull/{n}")) && row["pr"]["number"].as_u64() == Some(n)))
                    {
                        let t = super::lang::issue_existing(n, row["worktree_path"].as_str().unwrap_or_default());
                        self.core.first_mate_line(t.get(self.config.language));
                        return Some(Gate::Deny(t.get(self.config.language).into()));
                    }
                }
            }
        }
        let named = mandate(&self.route_text, &super::short(&repo), &aliases, None) || remotes.iter().any(|r| mandate(&self.route_text, "", &[], Some(r)));
        let automatic = book
            .habits
            .iter()
            .any(|h| h.active() && h.act == Do::Route && book.level(h) == HabitLevel::Auto && h.when.route_words() == Some(words(&self.route_text).as_str()));
        if named || automatic {
            if repo_cap == Some(Level::Ask) {
                return None;
            }
            self.route_used = true;
            return Some(Gate::Allow);
        }
        let projects = self.project_list();
        let options: Vec<Value> = projects
            .as_array()
            .into_iter()
            .flatten()
            .take(3)
            .map(|project| {
                json!({
                    "label": project["name"], "action":"worktree.create", "params":{"repo_path":project["repo"], "prompt":params["prompt"]}
                })
            })
            .collect();
        let summary = super::lang::route_choose();
        match self.propose(summary.get(self.config.language), &options, now) {
            Ok(v) => Some(Gate::Queued(v["card"].as_str().unwrap_or_default().into())),
            Err(e) => Some(Gate::Deny(e.message)),
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
        book.route_pick(&words(text), &today, card);
        self.save_book(&book, now);
        self.learn(now);
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
