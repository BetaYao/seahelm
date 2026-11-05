//! What is actually in a worktree, measured rather than described by First
//! Mate (`WorktreeFacts.swift`): uncommitted files and lines, ignored files
//! that are not caches, commits that exist nowhere else, busy panes, how
//! long it has been idle, whether it still changes anything against its
//! base, and where its PR stands. In every event and on every card that
//! would delete the worktree, so a summary that leaves something out cannot
//! be what the user approves on. Vocabulary: docs/first-mate-autonomy.md,
//! "Vocabulary of measured facts".

use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::pr::{PrStatus, State};

/// Ignored directories (and files) that a build or an install puts back:
/// losing them costs time, not work, so they do not count as ignored files.
/// Matched against every component of an ignored path.
pub const REGENERABLE: &[&str] = &[
    // JavaScript
    "node_modules", "dist", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".vite", ".cache", ".eslintcache",
    "coverage", ".nyc_output",
    // Rust, Swift, Xcode, JVM, Zig, Dart, CocoaPods
    "target", ".build", "DerivedData", ".swiftpm", "Pods", "build", ".gradle", ".zig-cache", "zig-cache", "zig-out",
    ".dart_tool",
    // Python
    ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".ipynb_checkpoints",
    // Junk
    ".DS_Store",
];

/// How many ignored names a card spells out.
pub const IGNORED_NAMES_CAP: usize = 8;

/// Bases a branch is compared against, first that exists.
pub const BASES: &[&str] = &["origin/main", "origin/master", "main", "master"];

/// Read back from the observation log by the habits, so every field has a default.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Facts {
    pub changed: u32,
    pub deleted: u32,
    pub untracked: u32,
    pub insertions: u32,
    pub deletions: u32,
    /// Gitignored entries that are not in `REGENERABLE` (a wholly ignored
    /// directory is one entry). `git worktree remove` deletes them without a word.
    pub ignored: u32,
    /// Their names, at most `IGNORED_NAMES_CAP` (".env", "notes/").
    pub ignored_files: Vec<String>,
    /// Commits on HEAD that no remote ref has and the PR's head does not
    /// contain; None when git could not say.
    pub unpushed: Option<u32>,
    /// Whether `unpushed` was checked against the PR's head commit.
    pub unpushed_checked_pr_head: bool,
    pub busy_panes: u32,
    /// Whole days since the latest of the last commit and the last pane
    /// activity the core knows of.
    pub idle_days: Option<u32>,
    pub last_commit_at: Option<f64>,
    pub last_pane_activity_at: Option<f64>,
    /// The base `identical_to_base` was measured against ("origin/main").
    pub base: Option<String>,
    /// Merging HEAD into the base changes nothing: every committed change is
    /// already there (a squash merge included). None without a base.
    pub identical_to_base: Option<bool>,
    /// `merged / closed / open / draft / none`; None when nobody knows.
    pub pr: Option<String>,
    pub pr_number: Option<u64>,
    pub days_since_merge: Option<u32>,
}

/// What the caller knows of the worktree's PR.
#[derive(Clone, Copy, Debug)]
pub enum PrInfo<'a> {
    /// Not fetched (offline, no token, not looked at yet).
    Unknown,
    /// Looked, and the branch has none.
    None,
    Some(&'a PrStatus),
}

/// What the caller knows beyond git.
#[derive(Clone, Copy, Debug)]
pub struct Context<'a> {
    pub pr: PrInfo<'a>,
    /// Latest pane activity in the worktree (prompt, reply, start), Unix seconds.
    pub last_pane_activity: Option<f64>,
    pub busy_panes: u32,
    pub now: f64,
    /// Whether a PR head missing locally may be fetched from `origin`
    /// (`refs/pull/<n>/head`; objects only, no ref written).
    pub fetch_pr_head: bool,
}

impl<'a> Context<'a> {
    pub fn new(pr: PrInfo<'a>, now: f64) -> Self {
        Context { pr, last_pane_activity: None, busy_panes: 0, now, fetch_pr_head: true }
    }
}

fn plural(n: u32, one: &str) -> String {
    format!("{n} {one}{}", if n == 1 { "" } else { "s" })
}

impl Facts {
    /// "2 ignored files would be lost (.env, notes.md) · nothing uncommitted · every commit is on a remote or in PR #12 ·
    /// panes idle · PR #12 merged 3 days ago · idle 3 days · identical to origin/main".
    pub fn summary(&self) -> String {
        let mut parts = Vec::new();
        // First: the one thing `git worktree remove` loses without asking.
        if self.ignored > 0 {
            let mut names = self.ignored_files.join(", ");
            let more = self.ignored as usize - self.ignored_files.len().min(self.ignored as usize);
            if more > 0 {
                names += &format!(", +{more} more");
            }
            parts.push(format!("{} would be lost ({names})", plural(self.ignored, "ignored file")));
        }
        let n = self.changed + self.untracked;
        if n == 0 {
            parts.push("nothing uncommitted".to_string());
        } else {
            let mut kinds = Vec::new();
            if self.deleted > 0 {
                kinds.push(format!("{} deleted", self.deleted));
            }
            if self.untracked > 0 {
                kinds.push(format!("{} untracked", self.untracked));
            }
            let mut detail = format!("+{} \u{2212}{}", self.insertions, self.deletions);
            if !kinds.is_empty() {
                detail += &format!("; {}", kinds.join(", "));
            }
            parts.push(format!("{} uncommitted ({detail})", plural(n, "file")));
        }
        parts.push(match (self.unpushed, self.unpushed_checked_pr_head, self.pr_number) {
            (None, ..) => "unpushed commits unknown".into(),
            (Some(0), true, Some(pr)) => format!("every commit is on a remote or in PR #{pr}"),
            (Some(0), ..) => "every commit is on a remote".into(),
            (Some(u), ..) => format!("{} on no remote", plural(u, "commit")),
        });
        parts.push(match self.busy_panes {
            0 => "panes idle".into(),
            b => format!("{} busy", plural(b, "pane")),
        });
        match (self.pr.as_deref(), self.pr_number) {
            (None, _) => parts.push("PR unknown".into()),
            (Some("none"), _) => parts.push("no PR".into()),
            (Some("merged"), Some(n)) => parts.push(match self.days_since_merge {
                Some(0) => format!("PR #{n} merged today"),
                Some(d) => format!("PR #{n} merged {} ago", plural(d, "day")),
                None => format!("PR #{n} merged"),
            }),
            (Some(state), Some(n)) => parts.push(format!("PR #{n} {state}")),
            (Some(state), None) => parts.push(format!("PR {state}")),
        }
        match self.idle_days {
            Some(0) => parts.push("active today".into()),
            Some(d) => parts.push(format!("idle {}", plural(d, "day"))),
            None => {}
        }
        if let (Some(same), Some(base)) = (self.identical_to_base, &self.base) {
            parts.push(if same { format!("identical to {base}") } else { format!("changes {base}") });
        }
        parts.join(" · ")
    }

    /// Measure with git. Blocking (a PR head missing locally is fetched,
    /// with a timeout).
    pub fn measure(worktree: &Path, ctx: &Context) -> Self {
        let mut f = Facts { busy_panes: ctx.busy_panes, last_pane_activity_at: ctx.last_pane_activity, ..Facts::default() };
        if let Some(s) = git(worktree, &["status", "--porcelain=v1"]) {
            (f.changed, f.deleted, f.untracked) = parse_status(&s);
        }
        if let Some(s) = git(worktree, &["diff", "HEAD", "--shortstat"]) {
            (f.insertions, f.deletions) = parse_shortstat(&s);
        }
        if let Some(s) = git(worktree, &["status", "--porcelain=v1", "-z", "--ignored=traditional", "--untracked-files=normal"]) {
            let kept: Vec<String> = ignored_worth_keeping(&s).into_iter().filter(|p| !is_symlink(worktree, p)).collect();
            f.ignored = kept.len() as u32;
            f.ignored_files = kept.into_iter().take(IGNORED_NAMES_CAP).collect();
        }
        let pr = match ctx.pr {
            PrInfo::Unknown => None,
            PrInfo::None => {
                f.pr = Some("none".into());
                None
            }
            PrInfo::Some(p) => {
                f.pr = Some(p.state.as_str().into());
                f.pr_number = Some(p.number);
                if p.state == State::Merged {
                    f.days_since_merge = p.merged_at.map(|t| days(ctx.now - t as f64));
                }
                Some(p)
            }
        };
        (f.unpushed, f.unpushed_checked_pr_head) = unpushed(worktree, pr, ctx.fetch_pr_head);
        f.last_commit_at = git(worktree, &["log", "-1", "--format=%ct", "HEAD"]).and_then(|s| s.trim().parse().ok());
        let latest = [f.last_commit_at, f.last_pane_activity_at].into_iter().flatten().fold(None, |a: Option<f64>, t| Some(a.map_or(t, |a| a.max(t))));
        f.idle_days = latest.map(|t| days(ctx.now - t));
        if let Some(base) = BASES.iter().find(|b| git(worktree, &["rev-parse", "--verify", "--quiet", &format!("{b}^{{commit}}")]).is_some()) {
            f.base = Some(base.to_string());
            f.identical_to_base = identical_to(worktree, base);
        }
        f
    }
}

fn days(secs: f64) -> u32 {
    (secs.max(0.0) / 86_400.0).floor() as u32
}

pub fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git").arg("-C").arg(dir).args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Commits on HEAD that no remote ref (`refs/remotes/*`, `refs/pull/*`)
/// has and, when the PR's head commit is here (or can be fetched as
/// `refs/pull/<n>/head`), that it does not contain either: after a squash
/// merge whose branch GitHub deleted, the commits live only under the PR.
fn unpushed(worktree: &Path, pr: Option<&PrStatus>, fetch: bool) -> (Option<u32>, bool) {
    let mut args = vec!["rev-list", "--count", "HEAD", "--not", "--remotes", "--glob=refs/pull/*"];
    // In a local-only repository the base is the durable copy. Unknown
    // remote configuration stays conservative.
    let local_base = if git(worktree, &["remote"]).is_some_and(|s| s.trim().is_empty()) {
        ["main", "master"].into_iter().find(|base| has_commit(worktree, base))
    } else { None };
    if let Some(base) = local_base { args.push(base); }
    let mut checked = false;
    let head = pr.and_then(|p| p.head_oid.as_deref().map(|o| (p.number, o)));
    if let Some((number, oid)) = head {
        if is_hex(oid) && (has_commit(worktree, oid) || (fetch && fetch_pull_head(worktree, number) && has_commit(worktree, oid))) {
            args.push(oid);
            checked = true;
        }
    }
    (git(worktree, &args).and_then(|s| s.trim().parse().ok()), checked)
}

fn is_hex(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_hexdigit())
}

fn has_commit(worktree: &Path, oid: &str) -> bool {
    git(worktree, &["cat-file", "-e", &format!("{oid}^{{commit}}")]).is_some()
}

/// Objects only: no ref and no FETCH_HEAD is written.
fn fetch_pull_head(worktree: &Path, number: u64) -> bool {
    let refspec = format!("refs/pull/{number}/head");
    let child = Command::new("git")
        .arg("-C")
        .arg(worktree)
        .args(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "origin", &refspec])
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    let Ok(mut child) = child else { return false };
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
}

/// `git merge-tree --write-tree HEAD <base>` gives the tree a merge would
/// make; when it is the base's own tree, the branch changes nothing.
/// A conflict is a change.
fn identical_to(worktree: &Path, base: &str) -> Option<bool> {
    let base_tree = git(worktree, &["rev-parse", &format!("{base}^{{tree}}")])?;
    let out = Command::new("git")
        .arg("-C")
        .arg(worktree)
        .args(["merge-tree", "--write-tree", "--no-messages", "HEAD", base])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    match out.status.code() {
        Some(0) => {
            let merged = String::from_utf8_lossy(&out.stdout);
            Some(merged.lines().next().map(str::trim) == Some(base_tree.trim()))
        }
        Some(1) => Some(false),
        _ => None,
    }
}

/// The ignored entries of `git status -z --ignored` that are not caches.
fn ignored_worth_keeping(status_z: &str) -> Vec<String> {
    let mut kept: Vec<String> = status_z
        .split('\0')
        .filter_map(|e| e.strip_prefix("!! "))
        .filter(|p| !is_regenerable(p))
        .map(str::to_string)
        .collect();
    kept.sort();
    kept
}

pub fn is_regenerable(path: &str) -> bool {
    let path = path.trim_end_matches('/');
    path.split('/').any(|c| REGENERABLE.contains(&c))
        || REGENERABLE_SUFFIXES.iter().any(|s| path.ends_with(s))
        // Xcode's per-user state, and the workspace a generated project
        // (xcodegen) carries inside its .xcodeproj.
        || path.split('/').any(|c| c == "xcuserdata")
        || (path.ends_with("project.xcworkspace") && path.contains(".xcodeproj/"))
}

/// Endings of files tools rewrite on every run.
const REGENERABLE_SUFFIXES: &[&str] = &[".pyc", ".tsbuildinfo"];

/// An ignored entry that is a symbolic link: removing the worktree removes
/// the link, never what it points at (seahelm's own worktrees link
/// GhosttyKit.xcframework into a shared cache).
fn is_symlink(worktree: &Path, entry: &str) -> bool {
    std::fs::symlink_metadata(worktree.join(entry.trim_end_matches('/'))).is_ok_and(|m| m.file_type().is_symlink())
}

fn parse_status(porcelain: &str) -> (u32, u32, u32) {
    let (mut changed, mut deleted, mut untracked) = (0, 0, 0);
    for line in porcelain.lines().filter(|l| l.len() >= 2) {
        let code = &line[..2];
        if code == "??" {
            untracked += 1;
            continue;
        }
        if code == "!!" {
            continue;
        }
        changed += 1;
        if code.contains('D') {
            deleted += 1;
        }
    }
    (changed, deleted, untracked)
}

fn parse_shortstat(text: &str) -> (u32, u32) {
    let number_before = |word: &str| -> u32 {
        text.find(word)
            .and_then(|i| text[..i].trim().rsplit(' ').next().and_then(|n| n.parse().ok()))
            .unwrap_or(0)
    };
    (number_before("insertion"), number_before("deletion"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pr::{PrStatus, State};
    use std::fs;
    use std::path::PathBuf;

    #[test]
    fn parses_git() {
        assert_eq!(parse_status(" M a\nD  b\n?? c\n!! d\n"), (2, 1, 1));
        assert_eq!(parse_shortstat(" 3 files changed, 16 insertions(+), 47942 deletions(-)\n"), (16, 47942));
        assert_eq!(parse_shortstat(" 1 file changed, 1 deletion(-)\n"), (0, 1));
    }

    #[test]
    fn generated_xcode_state_and_tsbuildinfo_are_regenerable() {
        assert!(is_regenerable("seahelm.xcodeproj/project.xcworkspace/"));
        assert!(is_regenerable("App.xcodeproj/xcuserdata/me.xcuserdatad/"));
        assert!(is_regenerable("apps/api/.tsbuildinfo"));
        assert!(!is_regenerable("project.xcworkspace/"), "a hand-made workspace at the root is kept");
        assert!(!is_regenerable(".env"));
    }

    #[test]
    #[cfg(unix)]
    fn an_ignored_symlink_is_not_counted() {
        let dir = std::env::temp_dir().join(format!("facts-symlink-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::os::unix::fs::symlink("/nonexistent/target", dir.join("GhosttyKit.xcframework")).unwrap();
        std::fs::write(dir.join(".env"), "x").unwrap();
        assert!(is_symlink(&dir, "GhosttyKit.xcframework"));
        assert!(!is_symlink(&dir, ".env"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn caches_are_not_ignored_files() {
        let z = "!! .env\0!! node_modules/\0!! web/node_modules/\0!! notes/\0!! a/__pycache__/\0!! x.pyc\0?? new.txt\0!! .DS_Store\0";
        assert_eq!(ignored_worth_keeping(z), vec![".env".to_string(), "notes/".to_string()]);
        assert!(is_regenerable("target/"));
        assert!(!is_regenerable("targets.md"));
    }

    #[test]
    fn summary_reads_like_the_apps() {
        let f = Facts {
            changed: 40,
            deleted: 40,
            untracked: 1,
            insertions: 16,
            deletions: 47942,
            unpushed: Some(0),
            pr: Some("none".into()),
            ..Facts::default()
        };
        assert_eq!(f.summary(), "41 files uncommitted (+16 \u{2212}47942; 40 deleted, 1 untracked) · every commit is on a remote · panes idle · no PR");
        assert_eq!(
            Facts { unpushed: Some(2), busy_panes: 1, ..Facts::default() }.summary(),
            "nothing uncommitted · 2 commits on no remote · 1 pane busy · PR unknown"
        );
    }

    #[test]
    fn summary_spells_out_the_new_facts() {
        let f = Facts {
            ignored: 10,
            ignored_files: (0..IGNORED_NAMES_CAP).map(|i| format!("f{i}")).collect(),
            unpushed: Some(0),
            unpushed_checked_pr_head: true,
            pr: Some("merged".into()),
            pr_number: Some(12),
            days_since_merge: Some(3),
            idle_days: Some(3),
            base: Some("origin/main".into()),
            identical_to_base: Some(true),
            ..Facts::default()
        };
        assert_eq!(
            f.summary(),
            "10 ignored files would be lost (f0, f1, f2, f3, f4, f5, f6, f7, +2 more) · nothing uncommitted · \
             every commit is on a remote or in PR #12 · panes idle · PR #12 merged 3 days ago · idle 3 days · identical to origin/main"
        );
        let json = serde_json::to_value(&f).unwrap();
        assert_eq!(json["ignored"], 10);
        assert_eq!(json["identical_to_base"], true);
    }

    // Real repositories.

    struct Repo {
        _tmp: tempfile::TempDir,
        /// The "GitHub" side: a bare repository.
        origin: PathBuf,
        /// A clone of it, the worktree under test.
        work: PathBuf,
    }

    fn run(dir: &Path, args: &[&str]) -> String {
        let out = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    fn commit(dir: &Path, file: &str, text: &str, msg: &str) -> String {
        fs::write(dir.join(file), text).unwrap();
        run(dir, &["add", "-A"]);
        run(dir, &["commit", "-qm", msg]);
        run(dir, &["rev-parse", "HEAD"])
    }

    /// origin with one commit on main, cloned; `.gitignore` covers `.env`
    /// and `node_modules/`.
    fn repo() -> Repo {
        let tmp = tempfile::tempdir().unwrap();
        let origin = tmp.path().join("origin.git");
        let seed = tmp.path().join("seed");
        let work = tmp.path().join("work");
        fs::create_dir_all(&seed).unwrap();
        run(tmp.path(), &["init", "-q", "--bare", "-b", "main", origin.to_str().unwrap()]);
        run(&seed, &["init", "-q", "-b", "main"]);
        commit(&seed, ".gitignore", ".env\nnode_modules/\n", "ignore");
        commit(&seed, "a.txt", "a\n", "a");
        run(&seed, &["push", "-q", origin.to_str().unwrap(), "main"]);
        run(tmp.path(), &["clone", "-q", origin.to_str().unwrap(), work.to_str().unwrap()]);
        Repo { _tmp: tmp, origin, work }
    }

    fn measure(dir: &Path, pr: PrInfo) -> Facts {
        Facts::measure(dir, &Context { fetch_pr_head: true, ..Context::new(pr, seahelm_core_types::now()) })
    }

    fn merged_pr(number: u64, head: &str) -> PrStatus {
        PrStatus { body: String::new(),
            number,
            url: "u".into(),
            state: State::Merged,
            checks: None,
            review: None,
            head_oid: Some(head.into()),
            merged_at: Some((seahelm_core_types::now() - 2.5 * 86_400.0) as i64),
        }
    }

    #[test]
    fn a_clean_clone_has_nothing_to_lose() {
        let r = repo();
        let f = measure(&r.work, PrInfo::None);
        assert_eq!((f.changed, f.untracked, f.ignored, f.unpushed), (0, 0, 0, Some(0)));
        assert_eq!(f.base.as_deref(), Some("origin/main"));
        assert_eq!(f.identical_to_base, Some(true));
        assert_eq!(f.idle_days, Some(0));
        assert_eq!(f.pr.as_deref(), Some("none"));
    }

    #[test]
    fn gitignored_env_counts_and_node_modules_does_not() {
        let r = repo();
        fs::write(r.work.join(".env"), "SECRET=1\n").unwrap();
        fs::create_dir_all(r.work.join("node_modules/left-pad")).unwrap();
        fs::write(r.work.join("node_modules/left-pad/index.js"), "x").unwrap();
        let f = measure(&r.work, PrInfo::Unknown);
        assert_eq!(f.ignored, 1);
        assert_eq!(f.ignored_files, vec![".env".to_string()]);
        assert_eq!(f.untracked, 0, "ignored files are not untracked");
        assert!(f.summary().starts_with("1 ignored file would be lost (.env)"), "{}", f.summary());
    }

    #[test]
    fn uncommitted_and_untracked() {
        let r = repo();
        fs::write(r.work.join("a.txt"), "a\nb\n").unwrap();
        fs::write(r.work.join("new.txt"), "n\n").unwrap();
        let f = measure(&r.work, PrInfo::Unknown);
        assert_eq!((f.changed, f.untracked, f.insertions), (1, 1, 1));
        assert_eq!(f.identical_to_base, Some(true), "uncommitted work is its own fact");
    }

    #[test]
    fn a_new_commit_is_unpushed_and_changes_the_base() {
        let r = repo();
        run(&r.work, &["checkout", "-qb", "feat"]);
        commit(&r.work, "b.txt", "b\n", "b");
        let f = measure(&r.work, PrInfo::None);
        assert_eq!(f.unpushed, Some(1));
        assert_eq!(f.identical_to_base, Some(false));
        assert!(f.summary().contains("1 commit on no remote"));
        assert!(f.summary().contains("changes origin/main"));
    }

    /// The case that misread: the branch was pushed, squash-merged as PR #7,
    /// and GitHub deleted the branch. Its commits are on no remote-tracking
    /// ref, but they are the PR's head, and the base already has the change.
    #[test]
    fn squash_merged_branch_with_its_remote_branch_deleted() {
        let r = repo();
        run(&r.work, &["checkout", "-qb", "feat"]);
        commit(&r.work, "b.txt", "b\n", "b1");
        let head = commit(&r.work, "b.txt", "b\nb2\n", "b2");
        run(&r.work, &["push", "-q", "origin", "feat"]);
        // GitHub: keeps the head under refs/pull/7/head, squashes onto main, deletes the branch.
        run(&r.origin, &["update-ref", "refs/pull/7/head", &head]);
        let main_tree = run(&r.origin, &["merge-tree", "--write-tree", "main", &head]);
        let squash = run(&r.origin, &["commit-tree", &main_tree, "-p", "main", "-m", "feat (#7)"]);
        run(&r.origin, &["update-ref", "refs/heads/main", &squash]);
        run(&r.origin, &["update-ref", "-d", "refs/heads/feat"]);
        run(&r.work, &["fetch", "-q", "--prune", "origin"]);
        assert_eq!(run(&r.work, &["rev-list", "--count", "HEAD", "--not", "--remotes"]), "2", "the old reading");

        let pr = merged_pr(7, &head);
        let f = measure(&r.work, PrInfo::Some(&pr));
        assert_eq!(f.unpushed, Some(0));
        assert!(f.unpushed_checked_pr_head);
        assert_eq!(f.identical_to_base, Some(true));
        assert_eq!(f.days_since_merge, Some(2));
        assert_eq!(f.pr.as_deref(), Some("merged"));
        assert!(f.summary().contains("every commit is on a remote or in PR #7"), "{}", f.summary());

        // A commit made after the merge is still unpushed.
        commit(&r.work, "c.txt", "c\n", "after");
        assert_eq!(measure(&r.work, PrInfo::Some(&pr)).unpushed, Some(1));
    }

    /// The PR head is not in the clone (pushed from elsewhere): fetched as
    /// refs/pull/<n>/head, with no ref written.
    #[test]
    fn a_missing_pr_head_is_fetched_from_refs_pull() {
        let r = repo();
        run(&r.work, &["checkout", "-qb", "feat"]);
        let head = commit(&r.work, "b.txt", "b\n", "b");
        // Only on the PR ref, never on a branch; a second clone lacks it.
        run(&r.work, &["push", "-q", "origin", &format!("{head}:refs/pull/9/head")]);
        let other = r.work.parent().unwrap().join("other");
        run(r.work.parent().unwrap(), &["clone", "-q", "--no-local", r.origin.to_str().unwrap(), other.to_str().unwrap()]);
        assert!(!has_commit(&other, &head));
        assert!(fetch_pull_head(&other, 9));
        assert!(has_commit(&other, &head));
        assert!(run(&other, &["for-each-ref", "refs/pull"]).is_empty(), "no ref written");
    }
}

#[cfg(test)] mod local_repo_tests {
    #[test] fn base_commits_are_safe_but_unique_local_commits_are_not() {
        let tmp = tempfile::tempdir().unwrap(); let dir = tmp.path();
        let git = |args: &[&str]| { assert!(std::process::Command::new("git").arg("-C").arg(dir).args(args).output().unwrap().status.success()); };
        git(&["init", "-b", "main"]);
        let commit = || git(&["-c", "user.name=test", "-c", "user.email=test@localhost", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "Test"]);
        commit(); assert_eq!(super::unpushed(dir, None, false).0, Some(0));
        git(&["checkout", "-b", "run"]); commit(); assert_eq!(super::unpushed(dir, None, false).0, Some(1));
        git(&["branch", "-f", "main", "HEAD"]); assert_eq!(super::unpushed(dir, None, false).0, Some(0));
    }
}
