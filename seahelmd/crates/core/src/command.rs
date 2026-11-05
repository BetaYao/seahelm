//! The command language's side effects, done by the core
//! (`seahelm_core_command::Host`): the fleet as it can be named, typing
//! into panes, starting worktrees, reading panes, talking to First Mate.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use seahelm_core_command::{FleetIndex, Host, PaneRef, RepoRef, WorktreeRef};
use seahelm_core_messages::Message;

use crate::core::Core;
use crate::first_mate::facts::git;

pub struct CoreHost<'a>(pub &'a Core);

const GIT_FRESH: Duration = Duration::from_secs(300);

impl CoreHost<'_> {
    /// A worktree's repo root and branch, read with git and kept a while.
    fn git_info(&self, path: &str) -> (String, String) {
        if let Some((repo, branch, at)) = self.0.git_cache.lock().unwrap_or_else(|e| e.into_inner()).get(path) {
            if at.elapsed() < GIT_FRESH {
                return (repo.clone(), branch.clone());
            }
        }
        let dir = Path::new(path);
        let repo = git(dir, &["rev-parse", "--path-format=absolute", "--git-common-dir"])
            .and_then(|c| Path::new(c.trim()).parent().map(|p| p.to_string_lossy().into_owned()))
            .unwrap_or_default();
        let branch = git(dir, &["rev-parse", "--abbrev-ref", "HEAD"]).map(|b| b.trim().to_string()).filter(|b| b != "HEAD").unwrap_or_default();
        self.0.git_cache.lock().unwrap_or_else(|e| e.into_inner()).insert(path.into(), (repo.clone(), branch.clone(), Instant::now()));
        (repo, branch)
    }
}

fn base(path: &str) -> String {
    Path::new(path).file_name().and_then(|n| n.to_str()).unwrap_or(path).to_string()
}

impl Host for CoreHost<'_> {
    fn fleet(&self) -> FleetIndex {
        let infos = self.0.pane_infos();
        let mut handles = self.0.handles.lock().unwrap_or_else(|e| e.into_inner());
        let panes: Vec<PaneRef> = infos
            .iter()
            .map(|(p, title)| PaneRef {
                handle: handles.handle(&p.id),
                key: p.id.clone(),
                project: p.project.clone(),
                branch: p.branch.clone(),
                worktree_path: p.worktree_path.clone(),
                kind: p.agent_type.display_name().to_string(),
                title: title.clone(),
                status: p.status,
                last_message: p.last_message.clone(),
            })
            .collect();
        drop(handles);
        let first_mate_dir = crate::first_mate::pane::dir().to_string_lossy().into_owned();
        let mut repos: BTreeMap<String, RepoRef> = BTreeMap::new();
        let mut worktrees = Vec::new();
        let mut live: Vec<String> = self.0.live_worktrees().into_iter().filter(|w| *w != first_mate_dir).collect();
        live.sort();
        for path in live {
            let (repo, branch) = self.git_info(&path);
            if repo.is_empty() {
                continue;
            }
            repos.entry(repo.clone()).or_insert_with(|| RepoRef { name: base(&repo), path: repo.clone() });
            worktrees.push(WorktreeRef { repo: base(&repo), branch, is_main: Path::new(&repo) == Path::new(&path), path });
        }
        FleetIndex { panes, worktrees, repos: repos.into_values().collect() }
    }

    fn send_text(&self, pane_key: &str, text: &str) -> bool {
        self.0.act("pane.run", &json!({"pane_id": pane_key, "command": text})).is_ok()
    }

    fn create_worktree(&self, repo_path: &str, task: &str) -> Result<String, String> {
        let params = json!({"repo_path": repo_path, "prompt": task});
        let r = self.0.act("worktree.create", &params).map_err(|e| e.message)?;
        // `/new` is the user's own line, from the desktop or a chat.
        self.0.note_performed("worktree.create", &params, &r, crate::first_mate::observations::By::User, Some("command"), None, None);
        r.get("worktree_path").and_then(Value::as_str).map(str::to_string).ok_or_else(|| "no worktree path".into())
    }

    fn transcript(&self, pane_key: &str) -> Option<String> {
        let r = self.0.act("pane.read", &json!({"pane_id": pane_key, "lines": 60})).ok()?;
        r.get("text").and_then(Value::as_str).map(str::to_string)
    }

    fn messages(&self, pane_key: &str) -> Vec<Message> {
        self.0.messages_of(pane_key)
    }

    fn activity(&self, pane_key: &str) -> Vec<String> {
        self.0
            .pane_infos()
            .into_iter()
            .find(|(p, _)| p.id == pane_key)
            .map(|(p, _)| {
                p.activity_events
                    .iter()
                    .map(|a| format!("{}{}{}", if a.is_error { "✕ " } else { "" }, a.tool, if a.detail.is_empty() { String::new() } else { format!(" — {}", a.detail) }))
                    .collect()
            })
            .unwrap_or_default()
    }

    fn first_mate_available(&self) -> bool {
        self.0.first_mate().is_some_and(|fm| fm.state().get("enabled").and_then(Value::as_bool) == Some(true))
    }

    fn say_to_first_mate(&self, text: &str) -> bool {
        self.0.first_mate().is_some_and(|fm| fm.say(text.to_string()))
    }
}
