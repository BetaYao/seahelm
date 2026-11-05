//! The core finds worktrees itself, so it knows the fleet with every client
//! closed (docs/first-mate-autonomy.md, phase 3a). Without this the core's
//! worktree set was the app's 2 s mirror (`worktrees.set`) plus the panes,
//! and a worktree made while the app was closed was never seen: no
//! `worktree.created` observation, no PR, nothing for a sweep to measure.
//!
//! Two parts:
//!
//! - **The repo set** (`core-repos.json` in the config directory): every
//!   repository the core has ever seen — the repos of the worktrees clients
//!   list and panes sit in, plus the projects the app (`config.json`
//!   `workspace_paths`) and the GPUI client (`gpui-projects.json`) keep. It
//!   is persisted, so a core restarted with the app closed still knows them.
//!   It only grows; a repo whose directory has stopped being a repository is
//!   dropped, one whose directory is missing (a volume that dropped out) is
//!   kept and skipped.
//! - **The scan**: every `EVERY`, off the RPC path on a thread of its own,
//!   `git worktree list --porcelain` for every repo in the set. Prunable and
//!   missing entries are skipped, and so are the integration checkout and
//!   the paths the app refuses to auto-add (`TabCoordinator.isEphemeralRepoPath`
//!   / `isToolStateRepoPath`): throwaway directories and tools' own hidden
//!   state.
//!
//! `Core::live_worktrees` is the app's list ∪ panes ∪ this scan. The app's
//! list stays authoritative for layout (`registry.reorder`, `pr.list`'s
//! users); the scan only adds.

use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;

use crate::core::Core;
use crate::first_mate::facts;

pub const FILE_NAME: &str = "core-repos.json";
/// How often every repo is listed. Worktrees change on the scale of hours;
/// the observer only needs to see a creation before the user forgets it.
pub const EVERY: Duration = Duration::from_secs(2 * 60);
/// The first scan waits for the app's first `worktrees.set` (2 s cadence),
/// so its repos seed the set before the set is listed.
const FIRST_SCAN_AFTER: Duration = Duration::from_secs(10);

/// One entry of `git worktree list --porcelain`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Entry {
    pub path: String,
    /// `refs/heads/` stripped; None when detached.
    pub branch: Option<String>,
    pub bare: bool,
    /// git says the worktree's directory is gone (`prunable gitdir file
    /// points to non-existent location`).
    pub prunable: bool,
}

/// Parse `git worktree list --porcelain`: blank-line separated records,
/// the first being the main checkout.
pub fn parse_porcelain(text: &str) -> Vec<Entry> {
    let mut out = Vec::new();
    let mut cur: Option<Entry> = None;
    for line in text.lines() {
        if let Some(path) = line.strip_prefix("worktree ") {
            if let Some(e) = cur.take() {
                out.push(e);
            }
            cur = Some(Entry { path: path.to_string(), ..Entry::default() });
            continue;
        }
        let Some(e) = cur.as_mut() else { continue };
        if let Some(r) = line.strip_prefix("branch ") {
            e.branch = Some(r.strip_prefix("refs/heads/").unwrap_or(r).to_string());
        } else if line == "bare" {
            e.bare = true;
        } else if line == "prunable" || line.starts_with("prunable ") {
            e.prunable = true;
        } else if line.is_empty() {
            out.extend(cur.take());
        }
    }
    out.extend(cur);
    out
}

/// What the scan leaves out.
#[derive(Clone, Debug, Default)]
pub struct Filter {
    /// Integration checkouts (`integration-worktrees.json` values), canonical.
    pub integration: HashSet<String>,
    /// Throwaway roots (`/tmp`, `/var/folders`, `$TMPDIR`, caches), canonical,
    /// without `/private`.
    pub ephemeral_roots: Vec<String>,
}

impl Filter {
    /// The filter for this machine: the app's integration checkouts and the
    /// app's throwaway roots.
    pub fn live(config_dir: &Path) -> Self {
        let integration = std::fs::read_to_string(config_dir.join("integration-worktrees.json"))
            .ok()
            .and_then(|t| serde_json::from_str::<serde_json::Map<String, Value>>(&t).ok())
            .map(|m| m.values().filter_map(Value::as_str).map(canon).collect())
            .unwrap_or_default();
        let mut roots: Vec<String> = ["/tmp", "/var/folders", "/var/tmp"].iter().map(|r| strip_private(&canon(r))).collect();
        roots.push(strip_private(&canon(&std::env::temp_dir().to_string_lossy())));
        if let Some(home) = std::env::var_os("HOME") {
            roots.push(strip_private(&canon(&Path::new(&home).join("Library/Caches").to_string_lossy())));
        }
        roots.retain(|r| r != "/" && !r.is_empty());
        roots.sort();
        roots.dedup();
        Filter { integration, ephemeral_roots: roots }
    }

    /// `TabCoordinator.isEphemeralRepoPath`: under a directory the OS hands
    /// out for throwaway work.
    pub fn is_ephemeral(&self, path: &str) -> bool {
        let p = strip_private(&canon(path));
        self.ephemeral_roots.iter().any(|r| p == *r || p.starts_with(&format!("{r}/")))
    }

    /// Whether a repository may join the set: not throwaway, not a tool's
    /// state (`isToolStateRepoPath`: any hidden path component).
    pub fn admits_repo(&self, repo: &str) -> bool {
        !self.is_ephemeral(repo) && !has_hidden_component(&canon(repo), false)
    }

    /// Whether a listed worktree counts. Hidden components are allowed only
    /// as `.claude/worktrees/` (Claude Code's EnterWorktree puts its
    /// worktrees there, inside the repo, and the app tracks them).
    pub fn admits_worktree(&self, path: &str) -> bool {
        let c = canon(path);
        !self.integration.contains(&c) && !self.is_ephemeral(&c) && !has_hidden_component(&c, true)
    }
}

fn has_hidden_component(path: &str, allow_claude_worktrees: bool) -> bool {
    let parts: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    parts.iter().enumerate().any(|(i, p)| {
        p.starts_with('.') && !(allow_claude_worktrees && *p == ".claude" && parts.get(i + 1) == Some(&"worktrees"))
    })
}

/// The path with symlinks resolved when it exists, else as written without
/// a trailing slash.
pub fn canon(path: &str) -> String {
    let trimmed = if path.len() > 1 { path.trim_end_matches('/') } else { path };
    Path::new(trimmed).canonicalize().map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|_| trimmed.to_string())
}

fn strip_private(path: &str) -> String {
    path.strip_prefix("/private/").map(|p| format!("/{p}")).unwrap_or_else(|| path.to_string())
}

/// The worktrees of one repo worth tracking: present on disk, not prunable,
/// not bare, admitted by `filter`. Canonical paths. The main checkout is
/// included, as the app's list includes it. None when git could not list.
pub fn worktrees_of(repo: &str, filter: &Filter, list: impl Fn(&str) -> Option<String>) -> Option<Vec<String>> {
    let text = list(repo)?;
    Some(
        parse_porcelain(&text)
            .into_iter()
            .filter(|e| !e.bare && !e.prunable && Path::new(&e.path).join(".git").exists())
            .map(|e| canon(&e.path))
            .filter(|p| filter.admits_worktree(p))
            .collect(),
    )
}

fn git_worktree_list(repo: &str) -> Option<String> {
    facts::git(Path::new(repo), &["worktree", "list", "--porcelain"])
}

/// A worktree's repository: its main checkout (the parent of the common
/// git dir). None for anything not in a non-bare repository.
pub fn repo_of(worktree: &str) -> Option<String> {
    let common = facts::git(Path::new(worktree), &["rev-parse", "--path-format=absolute", "--git-common-dir"])?;
    let common = Path::new(common.trim());
    if common.file_name()? != ".git" {
        return None;
    }
    Some(canon(&common.parent()?.to_string_lossy()))
}

// MARK: the repo set

/// Every repository the core has seen, persisted as a sorted JSON array.
pub struct RepoSet {
    path: PathBuf,
    repos: BTreeSet<String>,
}

impl RepoSet {
    pub fn open(path: PathBuf) -> Self {
        let repos = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str::<Vec<String>>(&t).ok())
            .unwrap_or_default()
            .into_iter()
            .collect();
        RepoSet { path, repos }
    }

    pub fn repos(&self) -> Vec<String> {
        self.repos.iter().cloned().collect()
    }

    /// Add `repo` (canonical); whether it was new.
    pub fn add(&mut self, repo: &str) -> bool {
        self.repos.insert(canon(repo))
    }

    pub fn remove(&mut self, repo: &str) -> bool {
        self.repos.remove(repo)
    }

    /// Write the set, atomically.
    pub fn save(&self) -> std::io::Result<()> {
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_string_pretty(&self.repos())?)?;
        std::fs::rename(&tmp, &self.path)
    }
}

/// The projects the clients keep: the app's `workspace_paths` and the GPUI
/// client's `gpui-projects.json`.
pub fn client_projects(config_dir: &Path) -> Vec<String> {
    let mut out = Vec::new();
    if let Some(v) = std::fs::read_to_string(config_dir.join("config.json")).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()) {
        if let Some(a) = v.get("workspace_paths").and_then(Value::as_array) {
            out.extend(a.iter().filter_map(Value::as_str).map(str::to_string));
        }
    }
    if let Some(a) = std::fs::read_to_string(config_dir.join("gpui-projects.json")).ok().and_then(|t| serde_json::from_str::<Vec<Value>>(&t).ok()) {
        // Strings, or objects with a `path`.
        out.extend(a.iter().filter_map(|v| v.as_str().or_else(|| v.get("path").and_then(Value::as_str))).map(str::to_string));
    }
    out
}

/// One scan: add the repos of `seeds` (worktrees or repo roots) to `set`,
/// drop repos that stopped being repositories, and list every repo's
/// worktrees. `repo_of` / `list` are git in production. Returns the
/// worktrees found (canonical, sorted) and whether `set` changed.
pub fn scan(
    set: &mut RepoSet,
    seeds: &[String],
    filter: &Filter,
    repo_of: impl Fn(&str) -> Option<String>,
    list: impl Fn(&str) -> Option<String>,
) -> (Vec<String>, bool) {
    let mut changed = false;
    let mut found: BTreeSet<String> = BTreeSet::new();
    let list_repo = |repo: &str, set: &mut RepoSet, found: &mut BTreeSet<String>| -> bool {
        let dir = Path::new(repo);
        if !dir.exists() {
            // The volume dropped out or the repo moved: keep it, skip it.
            return false;
        }
        match worktrees_of(repo, filter, &list) {
            Some(wts) => {
                found.extend(wts);
                false
            }
            // The directory is there but is no repository any more.
            None if !dir.join(".git").exists() => set.remove(repo),
            None => false,
        }
    };
    for repo in set.repos() {
        changed |= list_repo(&repo, set, &mut found);
    }
    // Seeds already found (a known repo's worktree) or known (a repo root)
    // need no git; the rest are asked for their repo once each scan.
    for seed in seeds {
        let c = canon(seed);
        if found.contains(&c) || set.repos.contains(&c) {
            continue;
        }
        let Some(repo) = repo_of(&c) else { continue };
        if filter.admits_repo(&repo) && set.add(&repo) {
            changed = true;
            list_repo(&repo, set, &mut found);
        }
    }
    (found.into_iter().collect(), changed)
}

/// The discovery thread: every `EVERY`, seed the repo set from what clients
/// list and panes sit in, list every repo, and hand the result to the core.
pub fn spawn(core: Arc<Core>) {
    let _ = std::thread::Builder::new().name("seahelm-core-discovery".into()).spawn(move || {
        let config_dir = crate::rpc::config_dir();
        let mut set = RepoSet::open(config_dir.join(FILE_NAME));
        std::thread::sleep(FIRST_SCAN_AFTER);
        loop {
            let filter = Filter::live(&config_dir);
            let mut seeds = client_projects(&config_dir);
            seeds.extend(core.client_worktrees());
            let (found, changed) = scan(&mut set, &seeds, &filter, repo_of, git_worktree_list);
            if changed {
                if let Err(e) = set.save() {
                    eprintln!("seahelm-core: cannot write {}: {e}", config_dir.join(FILE_NAME).display());
                }
            }
            core.set_discovered(found);
            std::thread::sleep(EVERY);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn git(dir: &Path, args: &[&str]) {
        let ok = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .output()
            .unwrap()
            .status
            .success();
        assert!(ok, "git {args:?}");
    }

    /// A repo with one commit under `root/name`.
    fn repo(root: &Path, name: &str) -> PathBuf {
        let r = root.join(name);
        std::fs::create_dir_all(&r).unwrap();
        git(&r, &["init", "-q", "-b", "main"]);
        git(&r, &["commit", "-q", "--allow-empty", "-m", "init"]);
        r
    }

    fn s(p: &Path) -> String {
        canon(&p.to_string_lossy())
    }

    /// tempfile names its directories `.tmpXXXX`, which the tool-state
    /// guard would refuse.
    fn tempdir() -> tempfile::TempDir {
        tempfile::Builder::new().prefix("disc").tempdir().unwrap()
    }

    /// No ephemeral roots: the tests themselves live under `$TMPDIR`.
    fn open_filter() -> Filter {
        Filter::default()
    }

    #[test]
    fn porcelain_parses_branches_detached_bare_and_prunable() {
        let text = "worktree /r/main\nHEAD aaa\nbranch refs/heads/main\n\n\
                    worktree /r/wt-a\nHEAD bbb\nbranch refs/heads/feat/a\n\n\
                    worktree /r/wt-d\nHEAD ccc\ndetached\n\n\
                    worktree /r/gone\nHEAD ddd\nbranch refs/heads/old\nprunable gitdir file points to non-existent location\n\n\
                    worktree /r/bare.git\nbare\n";
        let e = parse_porcelain(text);
        assert_eq!(e.len(), 5);
        assert_eq!(e[1], Entry { path: "/r/wt-a".into(), branch: Some("feat/a".into()), bare: false, prunable: false });
        assert_eq!(e[2].branch, None, "detached");
        assert!(e[3].prunable);
        assert!(e[4].bare);
    }

    #[test]
    fn discovers_worktrees_skipping_prunable_and_removed() {
        let tmp = tempdir();
        let r = repo(tmp.path(), "app");
        git(&r, &["worktree", "add", "-q", "-b", "feat/a", tmp.path().join("app-a").to_str().unwrap()]);
        git(&r, &["worktree", "add", "-q", "-b", "feat/b", tmp.path().join("app-b").to_str().unwrap()]);
        git(&r, &["worktree", "add", "-q", "-b", "feat/c", tmp.path().join("app-c").to_str().unwrap()]);
        // b: its directory deleted behind git's back (prunable).
        std::fs::remove_dir_all(tmp.path().join("app-b")).unwrap();
        // c: removed properly.
        git(&r, &["worktree", "remove", tmp.path().join("app-c").to_str().unwrap()]);

        let found = worktrees_of(&s(&r), &open_filter(), git_worktree_list).unwrap();
        assert_eq!(found, vec![s(&r), s(&tmp.path().join("app-a"))], "main checkout and the live worktree only");
    }

    #[test]
    fn filter_skips_integration_tool_state_and_ephemeral() {
        let f = Filter {
            integration: HashSet::from(["/w/app-integration".to_string()]),
            ephemeral_roots: vec!["/tmp".into(), "/var/folders".into()],
        };
        assert!(!f.admits_worktree("/w/app-integration"));
        assert!(!f.admits_worktree("/tmp/app-x"));
        assert!(!f.admits_worktree("/private/var/folders/xy/app"), "/private spelling of an ephemeral root");
        assert!(!f.admits_worktree("/Users/u/.amuxd/teams/1/apps/2"));
        assert!(f.admits_worktree("/w/app/.claude/worktrees/fix-1"), "EnterWorktree's worktrees count");
        assert!(f.admits_worktree("/w/app-feature"));
        assert!(!f.admits_repo("/Users/u/.local/state/gen"));
        assert!(!f.admits_repo("/w/app/.claude/worktrees/fix-1"), "never a repo root");
        assert!(f.admits_repo("/w/app"));
    }

    #[test]
    fn repo_set_persists_and_seeds_from_worktrees() {
        let tmp = tempdir();
        let r = repo(tmp.path(), "app");
        let wt = tmp.path().join("app-a");
        git(&r, &["worktree", "add", "-q", "-b", "feat/a", wt.to_str().unwrap()]);
        let file = tmp.path().join("cfg").join(FILE_NAME);

        // First run: the app listed only the worktree; its repo joins the set.
        let mut set = RepoSet::open(file.clone());
        let (found, changed) = scan(&mut set, &[wt.to_string_lossy().into_owned()], &open_filter(), repo_of, git_worktree_list);
        assert!(changed);
        assert_eq!(set.repos(), vec![s(&r)]);
        assert_eq!(found, vec![s(&r), s(&wt)]);
        set.save().unwrap();

        // A restart with the app closed (no seeds) still knows the repo, and
        // sees a worktree made meanwhile.
        let wt2 = tmp.path().join("app-b");
        git(&r, &["worktree", "add", "-q", "-b", "feat/b", wt2.to_str().unwrap()]);
        let mut set = RepoSet::open(file.clone());
        assert_eq!(set.repos(), vec![s(&r)]);
        let (found, changed) = scan(&mut set, &[], &open_filter(), repo_of, git_worktree_list);
        assert!(!changed);
        assert_eq!(found, vec![s(&r), s(&wt), s(&wt2)]);
    }

    #[test]
    fn a_missing_repo_is_kept_and_one_no_longer_a_repo_is_dropped() {
        let tmp = tempdir();
        let mut set = RepoSet::open(tmp.path().join(FILE_NAME));
        let gone = tmp.path().join("unmounted/app");
        let plain = tmp.path().join("plain");
        std::fs::create_dir_all(&plain).unwrap();
        set.add(&gone.to_string_lossy());
        set.add(&plain.to_string_lossy());
        let (found, changed) = scan(&mut set, &[], &open_filter(), repo_of, git_worktree_list);
        assert!(found.is_empty());
        assert!(changed);
        assert_eq!(set.repos(), vec![s(&gone)], "the missing one waits for its volume");
    }

    #[test]
    fn rejected_seeds_never_join() {
        let tmp = tempdir();
        let mut set = RepoSet::open(tmp.path().join(FILE_NAME));
        let f = Filter { integration: HashSet::new(), ephemeral_roots: vec!["/scratch".into()] };
        let (_, changed) = scan(&mut set, &["/scratch/x/wt".into(), "/h/.local/state/gen".into()], &f, |p| Some(p.to_string()), |_| Some(String::new()));
        assert!(!changed);
        assert!(set.repos().is_empty());
    }

    #[test]
    fn client_projects_reads_both_clients() {
        let tmp = tempdir();
        std::fs::write(tmp.path().join("config.json"), r#"{"workspace_paths": ["/w/a", "/w/b"], "theme_mode": "dark"}"#).unwrap();
        std::fs::write(tmp.path().join("gpui-projects.json"), r#"["/w/c", {"path": "/w/d"}]"#).unwrap();
        assert_eq!(client_projects(tmp.path()), vec!["/w/a", "/w/b", "/w/c", "/w/d"]);
    }
}
