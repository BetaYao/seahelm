//! What each worktree's branch has on GitHub: its newest pull request,
//! whether that PR's checks pass, and where review stands. Ported from the
//! app's `WorktreePRStore` / `WorktreePRStatusParser`
//! (`Sources/Core/WorktreePRStatus.swift`), so every client can draw the
//! fleet row's `#12 ✓ approved`.
//!
//! One GraphQL request per repository per minute covers every worktree in
//! it (the 30 most recently updated PRs, filed by head branch; PRs from
//! forks skipped). The token is `$GITHUB_TOKEN`, `$GH_TOKEN`, else
//! `gh auth token`; with none nothing is asked. The request goes out through
//! `curl` (on macOS, Linux and Windows 10+) rather than a TLS stack of our
//! own, on the PR thread, never on an RPC thread. A failed request keeps
//! the last answer and is retried after five minutes.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::core::Core;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Open,
    Draft,
    Merged,
    Closed,
}

impl State {
    fn as_str(self) -> &'static str {
        match self {
            State::Open => "open",
            State::Draft => "draft",
            State::Merged => "merged",
            State::Closed => "closed",
        }
    }
}

/// The head commit's check rollup.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Checks {
    Passing,
    Failing,
    Pending,
}

impl Checks {
    fn as_str(self) -> &'static str {
        match self {
            Checks::Passing => "passing",
            Checks::Failing => "failing",
            Checks::Pending => "pending",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Review {
    Approved,
    ChangesRequested,
    ReviewRequired,
}

impl Review {
    fn as_str(self) -> &'static str {
        match self {
            Review::Approved => "approved",
            Review::ChangesRequested => "changes_requested",
            Review::ReviewRequired => "review_required",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrStatus {
    pub number: u64,
    pub url: String,
    pub state: State,
    pub checks: Option<Checks>,
    pub review: Option<Review>,
}

impl PrStatus {
    /// Checks and review only mean something while the PR can still change.
    pub fn is_live(&self) -> bool {
        matches!(self.state, State::Open | State::Draft)
    }

    /// The wire shape: the app's `fleet.groups` item `pr`
    /// (`{number, url, state, checks?, review?}`, state one of
    /// open / draft / merged / closed; checks and review only while live).
    pub fn to_json(&self) -> Value {
        let mut v = json!({"number": self.number, "url": self.url, "state": self.state.as_str()});
        if self.is_live() {
            if let Some(c) = self.checks {
                v["checks"] = json!(c.as_str());
            }
            if let Some(r) = self.review {
                v["review"] = json!(r.as_str());
            }
        }
        v
    }

    /// One sentence for a tooltip or a screen reader.
    pub fn summary(&self) -> String {
        let mut parts = vec![format!("PR #{}", self.number), self.state.as_str().to_string()];
        if self.is_live() {
            if let Some(c) = self.checks {
                parts.push(
                    match c {
                        Checks::Passing => "checks passing",
                        Checks::Failing => "checks failing",
                        Checks::Pending => "checks running",
                    }
                    .into(),
                );
            }
            if let Some(r) = self.review {
                parts.push(
                    match r {
                        Review::Approved => "approved",
                        Review::ChangesRequested => "changes requested",
                        Review::ReviewRequired => "review required",
                    }
                    .into(),
                );
            }
        }
        parts.join(" · ")
    }
}

/// The repo's recently updated PRs, newest first, with what the row draws.
pub const QUERY: &str = "query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    pullRequests(first: 30, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number url state isDraft headRefName reviewDecision
        headRepositoryOwner { login }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
}";

/// Branch → its most recently updated PR. PRs from forks are skipped: a
/// fork's `fix-typo` is not this repo's `fix-typo` worktree.
pub fn parse_statuses(response: &Value, owner: &str) -> HashMap<String, PrStatus> {
    let nodes = response
        .pointer("/data/repository/pullRequests/nodes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut by_branch = HashMap::new();
    for node in nodes {
        let Some(branch) = node.get("headRefName").and_then(Value::as_str) else { continue };
        if by_branch.contains_key(branch) {
            continue;
        }
        let (Some(number), Some(url)) = (node.get("number").and_then(Value::as_u64), node.get("url").and_then(Value::as_str))
        else {
            continue;
        };
        let draft = node.get("isDraft").and_then(Value::as_bool).unwrap_or(false);
        let Some(state) = parse_state(node.get("state").and_then(Value::as_str), draft) else { continue };
        let head_owner = node.pointer("/headRepositoryOwner/login").and_then(Value::as_str);
        if !head_owner.is_some_and(|o| o.eq_ignore_ascii_case(owner)) {
            continue;
        }
        let rollup = node
            .pointer("/commits/nodes")
            .and_then(Value::as_array)
            .and_then(|n| n.last())
            .and_then(|n| n.pointer("/commit/statusCheckRollup/state"))
            .and_then(Value::as_str);
        by_branch.insert(
            branch.to_string(),
            PrStatus {
                number,
                url: url.to_string(),
                state,
                checks: parse_checks(rollup),
                review: parse_review(node.get("reviewDecision").and_then(Value::as_str)),
            },
        );
    }
    by_branch
}

pub fn parse_state(raw: Option<&str>, draft: bool) -> Option<State> {
    match raw? {
        "OPEN" => Some(if draft { State::Draft } else { State::Open }),
        "MERGED" => Some(State::Merged),
        "CLOSED" => Some(State::Closed),
        _ => None,
    }
}

/// GitHub's rollup: ERROR is a failure too; EXPECTED is a required check
/// that has not reported yet, which is still waiting.
pub fn parse_checks(raw: Option<&str>) -> Option<Checks> {
    match raw? {
        "SUCCESS" => Some(Checks::Passing),
        "FAILURE" | "ERROR" => Some(Checks::Failing),
        "PENDING" | "EXPECTED" => Some(Checks::Pending),
        _ => None,
    }
}

pub fn parse_review(raw: Option<&str>) -> Option<Review> {
    match raw? {
        "APPROVED" => Some(Review::Approved),
        "CHANGES_REQUESTED" => Some(Review::ChangesRequested),
        "REVIEW_REQUIRED" => Some(Review::ReviewRequired),
        _ => None,
    }
}

/// `origin`'s URL, in the three shapes git writes it: host, owner, repo.
pub fn parse_remote(url: &str) -> Option<(String, String, String)> {
    let url = url.trim();
    if url.is_empty() {
        return None;
    }
    let strip_user = |h: &str| h.rsplit_once('@').map_or(h, |(_, h)| h).to_string();
    let (host, path) = if let Some((_, rest)) = url.split_once("://") {
        // ssh://git@github.com/owner/repo.git, https://github.com/owner/repo
        let (host, path) = rest.split_once('/')?;
        let host = strip_user(host);
        let host = host.split_once(':').map_or(host.as_str(), |(h, _)| h).to_string();
        (host, path.to_string())
    } else {
        // git@github.com:owner/repo.git
        let (host, path) = url.split_once(':')?;
        (strip_user(host), path.to_string())
    };
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    if parts.len() < 2 || host.is_empty() {
        return None;
    }
    let repo = parts[parts.len() - 1];
    let repo = repo.strip_suffix(".git").unwrap_or(repo);
    let owner = parts[parts.len() - 2];
    if owner.is_empty() || repo.is_empty() {
        return None;
    }
    Some((host.to_ascii_lowercase(), owner.to_string(), repo.to_string()))
}

/// "owner/repo" when the remote is on github.com.
pub fn github_repo(url: &str) -> Option<String> {
    let (host, owner, repo) = parse_remote(url)?;
    (host == "github.com").then(|| format!("{owner}/{repo}"))
}

/// CI moves on the scale of minutes; a minute is fresh enough to watch it.
pub const TTL: Duration = Duration::from_secs(60);
/// After a failed request (offline, rate-limited, no access).
pub const FAILURE_TTL: Duration = Duration::from_secs(5 * 60);
/// `gh auth token` is a subprocess; do not ask per refresh.
const TOKEN_TTL: Duration = Duration::from_secs(10 * 60);
const REQUEST_TIMEOUT_SECS: u64 = 8;
/// How often the PR thread looks for stale repositories and moved branches.
pub const TICK: Duration = Duration::from_secs(15);

/// What the store needs from the outside world, so tests can stand in.
pub trait Source: Send + Sync {
    /// "owner/repo" for the worktree's `origin`, None when it is not on GitHub.
    fn repo(&self, worktree: &str) -> Option<String>;
    fn branch(&self, worktree: &str) -> Option<String>;
    fn token(&self) -> Option<String>;
    /// One repository's PRs by branch, None on any failure.
    fn fetch(&self, owner: &str, repo: &str, token: &str) -> Option<HashMap<String, PrStatus>>;
}

struct RepoEntry {
    by_branch: HashMap<String, PrStatus>,
    at: Instant,
    ok: bool,
}

#[derive(Default)]
struct Inner {
    /// Worktrees a client listed (`worktrees.set`).
    listed: Vec<String>,
    /// Worktree → "owner/repo"; None is "not on GitHub". Resolved once.
    remotes: HashMap<String, Option<String>>,
    /// Worktree → its branch, refreshed every tick.
    branches: HashMap<String, String>,
    repos: HashMap<String, RepoEntry>,
    token: Option<(Option<String>, Instant)>,
}

/// PR status per repository, refreshed on its own thread and cached, so the
/// RPC methods only read a map.
pub struct PrStore {
    inner: Mutex<Inner>,
    source: Box<dyn Source>,
}

impl PrStore {
    pub fn new(source: Box<dyn Source>) -> Self {
        PrStore { inner: Mutex::new(Inner::default()), source }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn set_listed(&self, paths: &[String]) {
        self.lock().listed = paths.to_vec();
    }

    pub fn listed(&self) -> Vec<String> {
        self.lock().listed.clone()
    }

    /// The worktree's PR as last fetched, without touching disk or network.
    pub fn status(&self, worktree: &str) -> Option<PrStatus> {
        let inner = self.lock();
        let repo = inner.remotes.get(worktree)?.as_ref()?;
        let branch = inner.branches.get(worktree)?;
        inner.repos.get(repo)?.by_branch.get(branch).cloned()
    }

    /// Every known worktree with a PR: `{worktree_path, repo, branch, pr}`.
    pub fn list(&self) -> Vec<Value> {
        let inner = self.lock();
        let mut paths: Vec<&String> = inner.branches.keys().collect();
        paths.sort();
        paths
            .into_iter()
            .filter_map(|wt| {
                let repo = inner.remotes.get(wt)?.as_ref()?;
                let branch = inner.branches.get(wt)?;
                let pr = inner.repos.get(repo)?.by_branch.get(branch)?;
                Some(json!({"worktree_path": wt, "repo": repo, "branch": branch, "pr": pr.to_json()}))
            })
            .collect()
    }

    /// One tick: resolve new worktrees' remotes, refresh every branch, and
    /// fetch every repository whose answer is stale. Slow work (git, curl)
    /// runs without the lock. Returns whether any worktree's PR changed.
    pub fn refresh(&self, worktrees: &[String], now: Instant) -> bool {
        let unknown: Vec<String> = {
            let inner = self.lock();
            worktrees.iter().filter(|w| !inner.remotes.contains_key(*w)).cloned().collect()
        };
        let resolved: Vec<(String, Option<String>)> = unknown.into_iter().map(|w| {
            let r = self.source.repo(&w);
            (w, r)
        }).collect();
        let branches: Vec<(String, Option<String>)> = worktrees.iter().map(|w| (w.clone(), self.source.branch(w))).collect();

        let before: Vec<(String, Option<PrStatus>)> = worktrees.iter().map(|w| (w.clone(), self.status(w))).collect();
        let stale: Vec<String> = {
            let mut inner = self.lock();
            inner.remotes.extend(resolved);
            // Worktrees nobody lists any more drop out of `pr.list`.
            inner.branches.retain(|w, _| worktrees.contains(w));
            for (w, b) in branches {
                match b {
                    Some(b) => {
                        inner.branches.insert(w, b);
                    }
                    None => {
                        inner.branches.remove(&w);
                    }
                }
            }
            let mut repos: HashSet<String> = HashSet::new();
            for w in worktrees {
                if let Some(Some(r)) = inner.remotes.get(w) {
                    repos.insert(r.clone());
                }
            }
            let mut stale: Vec<String> = repos
                .into_iter()
                .filter(|r| match inner.repos.get(r) {
                    Some(e) => now.duration_since(e.at) >= if e.ok { TTL } else { FAILURE_TTL },
                    None => true,
                })
                .collect();
            stale.sort();
            stale
        };
        if !stale.is_empty() {
            let token = self.token(now);
            for repo in stale {
                let Some((owner, name)) = repo.split_once('/') else { continue };
                // No token, no request; try again after the failure wait.
                let fetched = token.as_deref().and_then(|t| self.source.fetch(owner, name, t));
                let mut inner = self.lock();
                let old = inner.repos.remove(&repo).map(|e| e.by_branch).unwrap_or_default();
                let ok = fetched.is_some();
                // A failed fetch keeps what was known: a blip offline should
                // not wipe every badge until the next success.
                let by_branch = fetched.unwrap_or(old);
                inner.repos.insert(repo, RepoEntry { by_branch, at: now, ok });
            }
        }
        before.into_iter().any(|(w, old)| self.status(&w) != old)
    }

    fn token(&self, now: Instant) -> Option<String> {
        if let Some((t, at)) = self.lock().token.clone() {
            if now.duration_since(at) < TOKEN_TTL {
                return t;
            }
        }
        let t = self.source.token();
        self.lock().token = Some((t.clone(), now));
        t
    }
}

/// The real world: git for remotes and branches, the environment or `gh`
/// for the token, curl for GitHub.
pub struct Live;

fn git(path: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("git").arg("-C").arg(path).args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string()).filter(|s| !s.is_empty())
}

/// A curl config line value: double-quoted, `\` and `"` escaped.
fn curl_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

impl Source for Live {
    fn repo(&self, worktree: &str) -> Option<String> {
        github_repo(&git(worktree, &["remote", "get-url", "origin"])?)
    }

    fn branch(&self, worktree: &str) -> Option<String> {
        git(worktree, &["rev-parse", "--abbrev-ref", "HEAD"]).filter(|b| b != "HEAD")
    }

    fn token(&self) -> Option<String> {
        for var in ["GITHUB_TOKEN", "GH_TOKEN"] {
            if let Ok(t) = std::env::var(var) {
                if !t.trim().is_empty() {
                    return Some(t.trim().to_string());
                }
            }
        }
        let out = Command::new("gh").args(["auth", "token"]).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
        let t = String::from_utf8_lossy(&out.stdout).trim().to_string();
        (out.status.success() && !t.is_empty()).then_some(t)
    }

    fn fetch(&self, owner: &str, repo: &str, token: &str) -> Option<HashMap<String, PrStatus>> {
        let body = json!({"query": QUERY, "variables": {"owner": owner, "repo": repo}}).to_string();
        // The config goes in on stdin, so the token is not in argv for `ps`.
        let config = format!(
            "url = \"https://api.github.com/graphql\"\nheader = {}\nheader = \"Content-Type: application/json\"\nheader = \"User-Agent: seahelm-core\"\ndata-binary = {}\n",
            curl_quote(&format!("Authorization: bearer {token}")),
            curl_quote(&body),
        );
        let mut child = Command::new("curl")
            .args(["-sS", "--fail", "--max-time", &REQUEST_TIMEOUT_SECS.to_string(), "-K", "-"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        child.stdin.take()?.write_all(config.as_bytes()).ok()?;
        let out = child.wait_with_output().ok()?;
        if !out.status.success() {
            return None;
        }
        let v: Value = serde_json::from_slice(&out.stdout).ok()?;
        // An answer with errors and no repository (no access, bad token) is
        // a failure, not "no PRs".
        if v.pointer("/data/repository").map_or(true, Value::is_null) {
            return None;
        }
        Some(parse_statuses(&v, owner))
    }
}

/// The PR thread: every `TICK`, the worktrees clients listed plus every
/// registered pane's worktree, refreshed; a change wakes subscribers.
pub fn spawn(core: Arc<Core>) {
    let _ = std::thread::Builder::new().name("core-pr".into()).spawn(move || loop {
        core.pr_cycle(Instant::now());
        std::thread::sleep(TICK);
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn node(number: u64, branch: &str, state: &str, draft: bool, owner: &str, review: Option<&str>, rollup: Option<&str>) -> Value {
        let mut commit = json!({});
        if let Some(r) = rollup {
            commit["statusCheckRollup"] = json!({"state": r});
        }
        let mut n = json!({
            "number": number, "url": format!("https://github.com/acme/app/pull/{number}"),
            "state": state, "isDraft": draft, "headRefName": branch,
            "headRepositoryOwner": {"login": owner},
            "commits": {"nodes": [{"commit": commit}]},
        });
        if let Some(r) = review {
            n["reviewDecision"] = json!(r);
        }
        n
    }

    fn response(nodes: Vec<Value>) -> Value {
        json!({"data": {"repository": {"pullRequests": {"nodes": nodes}}}})
    }

    // Ported from Tests/WorktreePRStatusTests.swift, by name.

    #[test]
    fn reads_state_checks_and_review() {
        let by = parse_statuses(
            &response(vec![
                node(12, "feat/a", "OPEN", false, "acme", Some("APPROVED"), Some("SUCCESS")),
                node(13, "feat/b", "OPEN", true, "acme", None, Some("PENDING")),
                node(14, "feat/c", "OPEN", false, "acme", Some("CHANGES_REQUESTED"), Some("ERROR")),
                node(15, "feat/d", "MERGED", false, "acme", None, None),
            ]),
            "acme",
        );
        assert_eq!(
            by["feat/a"],
            PrStatus {
                number: 12,
                url: "https://github.com/acme/app/pull/12".into(),
                state: State::Open,
                checks: Some(Checks::Passing),
                review: Some(Review::Approved)
            }
        );
        assert_eq!(by["feat/b"].state, State::Draft);
        assert_eq!(by["feat/b"].checks, Some(Checks::Pending));
        assert_eq!(by["feat/c"].checks, Some(Checks::Failing), "ERROR is a failed check");
        assert_eq!(by["feat/c"].review, Some(Review::ChangesRequested));
        assert_eq!(by["feat/d"].state, State::Merged);
        assert_eq!(by["feat/d"].checks, None);
    }

    /// Nodes come newest-updated first; a branch reopened as a new PR is that one.
    #[test]
    fn newest_pr_for_a_branch_wins() {
        let by = parse_statuses(
            &response(vec![node(20, "fix", "OPEN", false, "acme", None, None), node(9, "fix", "CLOSED", false, "acme", None, None)]),
            "acme",
        );
        assert_eq!(by["fix"].number, 20);
    }

    #[test]
    fn fork_prs_are_not_this_repositorys_branches() {
        let by = parse_statuses(
            &response(vec![
                node(30, "main", "OPEN", false, "someone-else", None, None),
                node(31, "fix", "OPEN", false, "ACME", None, None),
            ]),
            "acme",
        );
        assert!(!by.contains_key("main"));
        assert_eq!(by["fix"].number, 31, "owner match ignores case");
    }

    #[test]
    fn empty_or_error_answer_is_nothing() {
        assert!(parse_statuses(&json!({"errors": [{"message": "x"}]}), "acme").is_empty());
    }

    #[test]
    fn wire_drops_checks_and_review_once_the_pr_is_done() {
        let merged = PrStatus { number: 1, url: "u".into(), state: State::Merged, checks: Some(Checks::Failing), review: Some(Review::Approved) };
        let w = merged.to_json();
        assert!(w.get("checks").is_none());
        assert!(w.get("review").is_none());
        assert_eq!(w["state"], "merged");
        let open = PrStatus { number: 2, url: "u".into(), state: State::Open, checks: Some(Checks::Failing), review: None };
        assert_eq!(open.to_json()["checks"], "failing");
        assert_eq!(open.summary(), "PR #2 · open · checks failing");
    }

    // Remotes.

    #[test]
    fn remotes_parse_in_every_shape_git_writes() {
        let gh = |u: &str| github_repo(u);
        assert_eq!(gh("https://github.com/BetaYao/seahelm"), Some("BetaYao/seahelm".into()));
        assert_eq!(gh("https://github.com/BetaYao/seahelm.git\n"), Some("BetaYao/seahelm".into()));
        assert_eq!(gh("git@github.com:BetaYao/seahelm.git"), Some("BetaYao/seahelm".into()));
        assert_eq!(gh("ssh://git@github.com:22/BetaYao/seahelm.git"), Some("BetaYao/seahelm".into()));
        assert_eq!(gh("https://user:tok@GitHub.com/BetaYao/seahelm"), Some("BetaYao/seahelm".into()));
        assert_eq!(gh("git@gitlab.com:acme/app.git"), None, "not on GitHub");
        assert_eq!(gh("/local/path/repo"), None);
        assert_eq!(gh(""), None);
        assert_eq!(parse_remote("git@gitlab.com:acme/app.git"), Some(("gitlab.com".into(), "acme".into(), "app".into())));
    }

    // The store.

    struct Fake {
        repo: Option<String>,
        branches: Mutex<HashMap<String, String>>,
        token: Option<String>,
        answer: Mutex<Option<HashMap<String, PrStatus>>>,
        calls: AtomicUsize,
    }

    impl Fake {
        fn new(repo: Option<&str>, token: Option<&str>) -> Self {
            Fake {
                repo: repo.map(Into::into),
                branches: Mutex::new(HashMap::new()),
                token: token.map(Into::into),
                answer: Mutex::new(None),
                calls: AtomicUsize::new(0),
            }
        }
    }

    impl Source for Arc<Fake> {
        fn repo(&self, _: &str) -> Option<String> {
            self.repo.clone()
        }
        fn branch(&self, w: &str) -> Option<String> {
            self.branches.lock().unwrap().get(w).cloned()
        }
        fn token(&self) -> Option<String> {
            self.token.clone()
        }
        fn fetch(&self, owner: &str, repo: &str, _: &str) -> Option<HashMap<String, PrStatus>> {
            assert_eq!(format!("{owner}/{repo}"), "acme/app");
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.answer.lock().unwrap().clone()
        }
    }

    fn pr(n: u64) -> PrStatus {
        PrStatus { number: n, url: "u".into(), state: State::Open, checks: Some(Checks::Passing), review: None }
    }

    #[test]
    fn store_fetches_once_per_repo_and_serves_every_branch() {
        let fake = Arc::new(Fake::new(Some("acme/app"), Some("token")));
        fake.branches.lock().unwrap().extend([("/wt/a".to_string(), "feat/a".to_string()), ("/wt/b".to_string(), "other".to_string())]);
        *fake.answer.lock().unwrap() = Some(HashMap::from([("feat/a".to_string(), pr(1))]));
        let store = PrStore::new(Box::new(fake.clone()));
        let wts = vec!["/wt/a".to_string(), "/wt/b".to_string()];
        let t0 = Instant::now();
        assert!(store.refresh(&wts, t0), "a PR appeared");
        assert!(!store.refresh(&wts, t0 + Duration::from_secs(30)));
        assert_eq!(store.status("/wt/a").map(|p| p.number), Some(1));
        assert_eq!(store.status("/wt/b"), None);
        assert_eq!(fake.calls.load(Ordering::SeqCst), 1, "fresh for a minute, one request for both worktrees");
        let listed = store.list();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0]["branch"], "feat/a");
        assert_eq!(listed[0]["pr"]["number"], 1);
        store.refresh(&wts, t0 + TTL);
        assert_eq!(fake.calls.load(Ordering::SeqCst), 2, "asked again once stale");
    }

    #[test]
    fn a_branch_switch_is_seen_without_a_fetch() {
        let fake = Arc::new(Fake::new(Some("acme/app"), Some("token")));
        fake.branches.lock().unwrap().insert("/wt/a".into(), "feat/a".into());
        *fake.answer.lock().unwrap() = Some(HashMap::from([("feat/a".to_string(), pr(1)), ("feat/b".to_string(), pr(2))]));
        let store = PrStore::new(Box::new(fake.clone()));
        let wts = vec!["/wt/a".to_string()];
        let t0 = Instant::now();
        store.refresh(&wts, t0);
        fake.branches.lock().unwrap().insert("/wt/a".into(), "feat/b".into());
        assert!(store.refresh(&wts, t0 + Duration::from_secs(1)));
        assert_eq!(store.status("/wt/a").map(|p| p.number), Some(2));
        assert_eq!(fake.calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_failed_fetch_keeps_the_last_answer_and_waits_longer() {
        let fake = Arc::new(Fake::new(Some("acme/app"), Some("token")));
        fake.branches.lock().unwrap().insert("/wt/a".into(), "feat/a".into());
        *fake.answer.lock().unwrap() = Some(HashMap::from([("feat/a".to_string(), pr(1))]));
        let store = PrStore::new(Box::new(fake.clone()));
        let wts = vec!["/wt/a".to_string()];
        let t0 = Instant::now();
        store.refresh(&wts, t0);
        *fake.answer.lock().unwrap() = None;
        store.refresh(&wts, t0 + TTL);
        assert_eq!(store.status("/wt/a").map(|p| p.number), Some(1), "kept through the failure");
        store.refresh(&wts, t0 + TTL + TTL);
        assert_eq!(fake.calls.load(Ordering::SeqCst), 2, "a failure waits five minutes, not one");
        store.refresh(&wts, t0 + TTL + FAILURE_TTL);
        assert_eq!(fake.calls.load(Ordering::SeqCst), 3);
    }

    #[test]
    fn no_token_no_request() {
        let fake = Arc::new(Fake::new(Some("acme/app"), None));
        fake.branches.lock().unwrap().insert("/wt/a".into(), "feat/a".into());
        let store = PrStore::new(Box::new(fake.clone()));
        assert!(!store.refresh(&["/wt/a".to_string()], Instant::now()));
        assert_eq!(fake.calls.load(Ordering::SeqCst), 0, "asked GitHub without a token");
    }

    #[test]
    fn not_on_github_is_never_fetched() {
        let fake = Arc::new(Fake::new(None, Some("token")));
        fake.branches.lock().unwrap().insert("/wt/a".into(), "x".into());
        let store = PrStore::new(Box::new(fake.clone()));
        store.refresh(&["/wt/a".to_string()], Instant::now());
        assert_eq!(fake.calls.load(Ordering::SeqCst), 0);
        assert_eq!(store.status("/wt/a"), None);
    }

    #[test]
    fn curl_config_values_are_quoted() {
        assert_eq!(curl_quote(r#"a"b\c"#), r#""a\"b\\c""#);
        assert_eq!(curl_quote("x\ny"), r#""x\ny""#);
    }
}
