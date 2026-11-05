//! What each worktree's branch has on GitHub: its newest pull request,
//! whether that PR's checks pass, and where review stands. Ported from the
//! app's `WorktreePRStore` / `WorktreePRStatusParser`
//! (`Sources/Core/WorktreePRStatus.swift`), so every client can draw the
//! fleet row's `#12 ✓ approved`.
//!
//! One GraphQL request per repository per minute covers every worktree in
//! it (the 30 most recently updated PRs, filed by head branch; PRs from
//! forks skipped). A worktree whose branch is not among them (an old merged
//! PR, a branch quiet for weeks) is looked up by head branch
//! (`BRANCH_QUERY`), batched per repository, and the answer cached: a
//! merged or closed PR never changes, so it is never asked again; "no PR"
//! is asked again after a day, an open one after half an hour.
//!
//! Request budget, per repository: one request a minute, as before, plus
//! branch lookups. A daily sweep over a fleet that has been seen before
//! costs no branch requests beyond one per repository for the "no PR"
//! answers gone stale (up to `BRANCH_QUERY_MAX` branches in one request);
//! a cold start costs one request per `BRANCH_QUERY_MAX` uncovered branches.
//! Each is a single GraphQL call worth one point of the 5,000-an-hour limit. The token is `$GITHUB_TOKEN`, `$GH_TOKEN`, else
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
    pub fn as_str(self) -> &'static str {
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
    pub body: String,
    pub number: u64,
    pub url: String,
    pub state: State,
    pub checks: Option<Checks>,
    pub review: Option<Review>,
    /// The PR's head commit (`headRefOid`): what GitHub keeps under
    /// `refs/pull/<n>/head` after the branch is gone, so a squash-merged
    /// worktree's commits are not "on no remote".
    pub head_oid: Option<String>,
    /// When it merged (`mergedAt`), Unix seconds.
    pub merged_at: Option<i64>,
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
        if let Some(o) = &self.head_oid {
            v["head_oid"] = json!(o);
        }
        if let Some(t) = self.merged_at {
            v["merged_at"] = json!(t);
        }
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

    /// PR prose is internal routing data, never part of the polled status wire shape.
    fn routing_json(&self) -> Value {
        let mut value=self.to_json();
        value["body"]=json!(self.body);
        value
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
        number url body state isDraft headRefName headRefOid mergedAt reviewDecision
        headRepositoryOwner { login }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
}";

/// Branches looked up in one request at most; the rest wait a tick.
pub const BRANCH_QUERY_MAX: usize = 20;

/// The query for looking up `n` branches' PRs by head branch: one aliased
/// `pullRequests(headRefName:)` per branch (`b0`, `b1`, …, the names passed
/// as variables), the newest five each so a fork's PR of the same name
/// does not hide this repository's.
pub fn branch_query(n: usize) -> String {
    let vars: String = (0..n).map(|i| format!(", $b{i}: String!")).collect();
    let fields: String = (0..n)
        .map(|i| {
            format!(
                "    b{i}: pullRequests(headRefName: $b{i}, states: [OPEN, MERGED, CLOSED], first: 5, orderBy: {{field: UPDATED_AT, direction: DESC}}) {{
      nodes {{
        number url body state isDraft headRefName headRefOid mergedAt reviewDecision
        headRepositoryOwner {{ login }}
        commits(last: 1) {{ nodes {{ commit {{ statusCheckRollup {{ state }} }} }} }}
      }}
    }}
"
            )
        })
        .collect();
    format!("query($owner: String!, $repo: String!{vars}) {{\n  repository(owner: $owner, name: $repo) {{\n{fields}  }}\n}}")
}

/// The answer to `branch_query(branches.len())`: every asked branch, with
/// its newest PR from this repository or None. None when the answer has no
/// repository (no access, bad token).
pub fn parse_branch_answers(response: &Value, owner: &str, branches: &[String]) -> Option<HashMap<String, Option<PrStatus>>> {
    let repo = response.pointer("/data/repository").filter(|r| !r.is_null())?;
    Some(
        branches
            .iter()
            .enumerate()
            .map(|(i, b)| {
                let nodes = repo.pointer(&format!("/b{i}/nodes")).and_then(Value::as_array).cloned().unwrap_or_default();
                let pr = nodes.iter().filter_map(|n| parse_node(n, owner)).find(|(nb, _)| nb == b).map(|(_, p)| p);
                (b.clone(), pr)
            })
            .collect(),
    )
}

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
        let Some((branch, pr)) = parse_node(&node, owner) else { continue };
        by_branch.entry(branch).or_insert(pr);
    }
    by_branch
}

/// One PR node: its head branch and status. None for a fork's PR (a fork's
/// `fix-typo` is not this repo's `fix-typo` worktree) or a malformed node.
fn parse_node(node: &Value, owner: &str) -> Option<(String, PrStatus)> {
    let branch = node.get("headRefName").and_then(Value::as_str)?;
    let number = node.get("number").and_then(Value::as_u64)?;
    let url = node.get("url").and_then(Value::as_str)?;
    let draft = node.get("isDraft").and_then(Value::as_bool).unwrap_or(false);
    let state = parse_state(node.get("state").and_then(Value::as_str), draft)?;
    let head_owner = node.pointer("/headRepositoryOwner/login").and_then(Value::as_str);
    if !head_owner.is_some_and(|o| o.eq_ignore_ascii_case(owner)) {
        return None;
    }
    let rollup = node
        .pointer("/commits/nodes")
        .and_then(Value::as_array)
        .and_then(|n| n.last())
        .and_then(|n| n.pointer("/commit/statusCheckRollup/state"))
        .and_then(Value::as_str);
    Some((
        branch.to_string(),
        PrStatus { body: node.get("body").and_then(Value::as_str).unwrap_or_default().into(),
            number,
            url: url.to_string(),
            state,
            checks: parse_checks(rollup),
            review: parse_review(node.get("reviewDecision").and_then(Value::as_str)),
            head_oid: node.get("headRefOid").and_then(Value::as_str).filter(|o| !o.is_empty()).map(str::to_string),
            merged_at: node.get("mergedAt").and_then(Value::as_str).and_then(parse_iso8601).map(|t| t.floor() as i64),
        },
    ))
}

/// GitHub's `2026-11-04T10:20:30Z` (UTC, optional fraction or offset)
/// into Unix seconds.
pub fn parse_iso8601(raw: &str) -> Option<f64> {
    let raw = raw.trim();
    let (date, time) = raw.split_once('T')?;
    let mut d = date.splitn(3, '-').map(|x| x.parse::<i64>().ok());
    let (y, m, day) = (d.next()??, d.next()??, d.next()??);
    // The offset: Z, +hh:mm or -hh:mm.
    let (clock, offset) = if let Some(c) = time.strip_suffix('Z') {
        (c, 0)
    } else if let Some(i) = time.rfind(['+', '-']) {
        let (c, o) = time.split_at(i);
        let sign = if o.starts_with('-') { -1 } else { 1 };
        let mut hm = o[1..].split(':').map(|x| x.parse::<i64>().ok());
        let (h, mi) = (hm.next()??, hm.next().flatten().unwrap_or(0));
        (c, sign * (h * 3600 + mi * 60))
    } else {
        (time, 0)
    };
    let mut t = clock.splitn(3, ':');
    let h: i64 = t.next()?.parse().ok()?;
    let mi: i64 = t.next()?.parse().ok()?;
    let sec: f64 = t.next().unwrap_or("0").parse().ok()?;
    if !(1..=12).contains(&m) || !(1..=31).contains(&day) {
        return None;
    }
    // Days from the civil date (Howard Hinnant's algorithm).
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some((days * 86_400 + h * 3600 + mi * 60 - offset) as f64 + sec)
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
/// A branch looked up and found to have no PR is asked again after this.
pub const BRANCH_NONE_TTL: Duration = Duration::from_secs(24 * 60 * 60);
/// An open PR found by lookup (so not updated lately) is asked again after
/// this; once it moves it is among the 30 most recent anyway.
pub const BRANCH_OPEN_TTL: Duration = Duration::from_secs(30 * 60);
/// Branches never looked up: a repository's default branch has no PR of
/// its own worth a request.
const NOT_LOOKED_UP: &[&str] = &["main", "master", "HEAD"];

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
    /// The newest PR of each of `branches` (at most `BRANCH_QUERY_MAX`),
    /// None for a branch without one; None on any failure.
    fn fetch_branches(&self, owner: &str, repo: &str, token: &str, branches: &[String]) -> Option<HashMap<String, Option<PrStatus>>>;
}

/// A branch's PR found by `Source::fetch_branches`.
struct BranchEntry {
    pr: Option<PrStatus>,
    at: Instant,
    /// False when the last lookup failed (`pr` is then what was known before).
    ok: bool,
}

impl BranchEntry {
    fn due(&self, now: Instant) -> bool {
        let wait = match (&self.pr, self.ok) {
            (_, false) => FAILURE_TTL,
            (Some(p), true) if !p.is_live() => return false,
            (Some(_), true) => BRANCH_OPEN_TTL,
            (None, true) => BRANCH_NONE_TTL,
        };
        now.duration_since(self.at) >= wait
    }
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
    /// ("owner/repo", branch) → its PR looked up by head branch, for
    /// branches not among the repository's recent PRs.
    branch_prs: HashMap<(String, String), BranchEntry>,
    token: Option<(Option<String>, Instant)>,
}

impl Inner {
    /// The branch's PR: the recent list's answer, else the lookup's.
    fn pr_for(&self, repo: &str, branch: &str) -> Option<&PrStatus> {
        if let Some(p) = self.repos.get(repo).and_then(|e| e.by_branch.get(branch)) {
            return Some(p);
        }
        self.branch_prs.get(&(repo.to_string(), branch.to_string())).and_then(|e| e.pr.as_ref())
    }
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
        inner.pr_for(repo, branch).cloned()
    }

    /// What is known of the worktree's PR: None when nothing was fetched
    /// for its repository yet (or the fetch failed), or the branch is not
    /// among the recent PRs and its lookup has not answered; Some(None)
    /// when the branch has no PR or the remote is not GitHub.
    pub fn known(&self, worktree: &str) -> Option<Option<PrStatus>> {
        let inner = self.lock();
        let Some(repo) = inner.remotes.get(worktree)? else { return Some(None) };
        let branch = inner.branches.get(worktree)?;
        let entry = inner.repos.get(repo).filter(|e| e.ok)?;
        if let Some(p) = entry.by_branch.get(branch) {
            return Some(Some(p.clone()));
        }
        if NOT_LOOKED_UP.contains(&branch.as_str()) {
            return Some(None);
        }
        let looked = inner.branch_prs.get(&(repo.clone(), branch.clone()))?;
        (looked.ok || looked.pr.is_some()).then(|| looked.pr.clone())
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
                let pr = inner.pr_for(repo, branch)?;
                Some(json!({"worktree_path": wt, "repo": repo, "branch": branch, "pr": pr.to_json()}))
            })
            .collect()
    }

    /// All cached PRs, including ones with no listed worktree. Routing must
    /// identify them by repository/PR number, never by an assumed pane path.
    pub fn routing_list(&self) -> Vec<Value> {
        let inner=self.lock();
        let mut rows=std::collections::BTreeMap::new();
        for (repo,entry) in &inner.repos {
            for (branch,pr) in &entry.by_branch {
                rows.insert((repo.clone(),pr.number),json!({"repo":repo,"branch":branch,"pr":pr.routing_json()}));
            }
        }
        for ((repo,branch),entry) in &inner.branch_prs {
            if let Some(pr)=&entry.pr { rows.entry((repo.clone(),pr.number)).or_insert_with(||json!({"repo":repo,"branch":branch,"pr":pr.routing_json()})); }
        }
        rows.into_values().collect()
    }

    /// One tick: resolve new worktrees' remotes, refresh every branch, fetch
    /// every repository whose answer is stale, then look up the branches the
    /// answers do not cover. Slow work (git, curl) runs without the lock.
    /// Returns whether any worktree's PR changed.
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
                // A finished PR in the recent list is the lookup's answer
                // too, so it costs no request once it drops out of the 30.
                for (branch, pr) in by_branch.iter().filter(|(_, p)| !p.is_live()) {
                    inner.branch_prs.insert((repo.clone(), branch.clone()), BranchEntry { pr: Some(pr.clone()), at: now, ok: true });
                }
                inner.repos.insert(repo, RepoEntry { by_branch, at: now, ok });
            }
        }
        self.look_up_branches(worktrees, now);
        before.into_iter().any(|(w, old)| self.status(&w) != old)
    }

    /// Look up, by head branch, the worktrees' branches their repository's
    /// recent PRs do not cover and whose cached answer is due: one request
    /// per repository, `BRANCH_QUERY_MAX` branches at most.
    fn look_up_branches(&self, worktrees: &[String], now: Instant) {
        let wanted: Vec<(String, Vec<String>)> = {
            let mut inner = self.lock();
            let mut live: HashSet<(String, String)> = HashSet::new();
            for w in worktrees {
                if let (Some(Some(repo)), Some(branch)) = (inner.remotes.get(w), inner.branches.get(w)) {
                    live.insert((repo.clone(), branch.clone()));
                }
            }
            // A branch no worktree has any more is forgotten, so a name
            // reused later is asked about afresh.
            inner.branch_prs.retain(|k, _| live.contains(k));
            let mut by_repo: HashMap<String, Vec<String>> = HashMap::new();
            for (repo, branch) in live {
                if NOT_LOOKED_UP.contains(&branch.as_str()) {
                    continue;
                }
                let Some(entry) = inner.repos.get(&repo).filter(|e| e.ok) else { continue };
                if entry.by_branch.contains_key(&branch) {
                    continue;
                }
                if inner.branch_prs.get(&(repo.clone(), branch.clone())).is_some_and(|e| !e.due(now)) {
                    continue;
                }
                by_repo.entry(repo).or_default().push(branch);
            }
            let mut wanted: Vec<(String, Vec<String>)> = by_repo
                .into_iter()
                .map(|(r, mut b)| {
                    b.sort();
                    b.truncate(BRANCH_QUERY_MAX);
                    (r, b)
                })
                .collect();
            wanted.sort();
            wanted
        };
        if wanted.is_empty() {
            return;
        }
        let Some(token) = self.token(now) else { return };
        for (repo, branches) in wanted {
            let Some((owner, name)) = repo.split_once('/') else { continue };
            let answers = self.source.fetch_branches(owner, name, &token, &branches);
            let mut inner = self.lock();
            for b in branches {
                let key = (repo.clone(), b.clone());
                let entry = match &answers {
                    Some(a) => BranchEntry { pr: a.get(&b).cloned().flatten(), at: now, ok: true },
                    // A failure keeps what was known and waits.
                    None => BranchEntry { pr: inner.branch_prs.remove(&key).and_then(|e| e.pr), at: now, ok: false },
                };
                inner.branch_prs.insert(key, entry);
            }
        }
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
        let v = graphql(token, &json!({"query": QUERY, "variables": {"owner": owner, "repo": repo}}))?;
        // An answer with errors and no repository (no access, bad token) is
        // a failure, not "no PRs".
        if v.pointer("/data/repository").map_or(true, Value::is_null) {
            return None;
        }
        Some(parse_statuses(&v, owner))
    }

    fn fetch_branches(&self, owner: &str, repo: &str, token: &str, branches: &[String]) -> Option<HashMap<String, Option<PrStatus>>> {
        if branches.is_empty() {
            return Some(HashMap::new());
        }
        let mut vars = json!({"owner": owner, "repo": repo});
        for (i, b) in branches.iter().enumerate() {
            vars[format!("b{i}")] = json!(b);
        }
        let v = graphql(token, &json!({"query": branch_query(branches.len()), "variables": vars}))?;
        parse_branch_answers(&v, owner, branches)
    }
}

/// One GraphQL request through curl; the parsed answer, None on any failure.
fn graphql(token: &str, body: &Value) -> Option<Value> {
    let body = body.to_string();
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
    serde_json::from_slice(&out.stdout).ok()
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
            PrStatus { body: String::new(),
                number: 12,
                url: "https://github.com/acme/app/pull/12".into(),
                state: State::Open,
                checks: Some(Checks::Passing),
                review: Some(Review::Approved),
                head_oid: None,
                merged_at: None,
            }
        );
        assert_eq!(by["feat/b"].state, State::Draft);
        assert_eq!(by["feat/b"].checks, Some(Checks::Pending));
        assert_eq!(by["feat/c"].checks, Some(Checks::Failing), "ERROR is a failed check");
        assert_eq!(by["feat/c"].review, Some(Review::ChangesRequested));
        assert_eq!(by["feat/d"].state, State::Merged);
        assert_eq!(by["feat/d"].checks, None);
    }

    #[test]
    fn reads_head_oid_and_merge_time() {
        let mut n = node(40, "feat/m", "MERGED", false, "acme", None, None);
        n["headRefOid"] = json!("abc123");
        n["mergedAt"] = json!("2026-11-04T10:20:30Z");
        let by = parse_statuses(&response(vec![n, node(41, "feat/o", "OPEN", false, "acme", None, None)]), "acme");
        assert_eq!(by["feat/m"].head_oid.as_deref(), Some("abc123"));
        assert_eq!(by["feat/m"].merged_at, Some(1_793_787_630));
        assert_eq!(by["feat/o"].merged_at, None);
        assert_eq!(by["feat/m"].to_json()["head_oid"], "abc123");
        assert_eq!(parse_iso8601("1970-01-01T00:00:00Z"), Some(0.0));
        assert_eq!(parse_iso8601("1970-01-02T01:00:00+01:00"), Some(86_400.0));
        assert_eq!(parse_iso8601("2024-02-29T00:00:00.5Z"), Some(1_709_164_800.5));
        assert_eq!(parse_iso8601("nonsense"), None);
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
        let merged = PrStatus { body: String::new(), number: 1, url: "u".into(), state: State::Merged, checks: Some(Checks::Failing), review: Some(Review::Approved), head_oid: None, merged_at: None };
        let w = merged.to_json();
        assert!(w.get("checks").is_none());
        assert!(w.get("review").is_none());
        assert_eq!(w["state"], "merged");
        let open = PrStatus { body: String::new(), number: 2, url: "u".into(), state: State::Open, checks: Some(Checks::Failing), review: None, head_oid: None, merged_at: None };
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
        /// What a branch lookup finds (absent: no PR); None fails the lookup.
        by_head: Mutex<Option<HashMap<String, PrStatus>>>,
        /// Every branch lookup's branches, in order.
        looked_up: Mutex<Vec<Vec<String>>>,
    }

    impl Fake {
        fn new(repo: Option<&str>, token: Option<&str>) -> Self {
            Fake {
                repo: repo.map(Into::into),
                branches: Mutex::new(HashMap::new()),
                token: token.map(Into::into),
                answer: Mutex::new(None),
                calls: AtomicUsize::new(0),
                by_head: Mutex::new(Some(HashMap::new())),
                looked_up: Mutex::new(Vec::new()),
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
        fn fetch_branches(&self, owner: &str, repo: &str, _: &str, branches: &[String]) -> Option<HashMap<String, Option<PrStatus>>> {
            assert_eq!(format!("{owner}/{repo}"), "acme/app");
            assert!(branches.len() <= BRANCH_QUERY_MAX);
            self.looked_up.lock().unwrap().push(branches.to_vec());
            let found = self.by_head.lock().unwrap().clone()?;
            Some(branches.iter().map(|b| (b.clone(), found.get(b).cloned())).collect())
        }
    }

    fn done(n: u64, state: State) -> PrStatus {
        PrStatus { body: String::new(), number: n, url: "u".into(), state, checks: None, review: None, head_oid: Some(format!("oid{n}")), merged_at: None }
    }

    /// A store over worktrees `/wt/<branch>` each on `<branch>`, with an
    /// empty recent list.
    fn branch_store(branches: &[&str]) -> (Arc<Fake>, PrStore, Vec<String>) {
        let fake = Arc::new(Fake::new(Some("acme/app"), Some("token")));
        let mut wts = Vec::new();
        for b in branches {
            fake.branches.lock().unwrap().insert(format!("/wt/{b}"), b.to_string());
            wts.push(format!("/wt/{b}"));
        }
        *fake.answer.lock().unwrap() = Some(HashMap::new());
        let store = PrStore::new(Box::new(fake.clone()));
        (fake, store, wts)
    }

    #[test]
    fn an_old_merged_pr_is_found_by_branch_and_never_asked_again() {
        let (fake, store, wts) = branch_store(&["feat/old", "feat/none"]);
        fake.by_head.lock().unwrap().as_mut().unwrap().insert("feat/old".into(), done(7, State::Merged));
        let t0 = Instant::now();
        assert!(store.refresh(&wts, t0), "the lookup's answer is a change");
        assert_eq!(*fake.looked_up.lock().unwrap(), vec![vec!["feat/none".to_string(), "feat/old".to_string()]], "one request for both");
        assert_eq!(store.status("/wt/feat/old").map(|p| (p.number, p.state)), Some((7, State::Merged)));
        assert_eq!(store.known("/wt/feat/old"), Some(Some(done(7, State::Merged))));
        assert_eq!(store.known("/wt/feat/none"), Some(None), "looked up: no PR");
        assert_eq!(store.list().len(), 1, "pr.list serves the looked-up PR");
        assert_eq!(store.list()[0]["pr"]["number"], 7);

        // An hour on: the repo is asked again, the branches are not.
        store.refresh(&wts, t0 + Duration::from_secs(3600));
        assert_eq!(fake.looked_up.lock().unwrap().len(), 1);
        // A day on: only "no PR" is asked again; the merged one never.
        store.refresh(&wts, t0 + BRANCH_NONE_TTL);
        assert_eq!(fake.looked_up.lock().unwrap().last().unwrap(), &vec!["feat/none".to_string()]);
        store.refresh(&wts, t0 + BRANCH_NONE_TTL * 30);
        assert!(fake.looked_up.lock().unwrap().iter().skip(1).all(|b| b == &vec!["feat/none".to_string()]));
    }

    #[test]
    fn unknown_until_the_lookup_answers() {
        let (fake, store, wts) = branch_store(&["feat/x"]);
        *fake.by_head.lock().unwrap() = None;
        let t0 = Instant::now();
        store.refresh(&wts, t0);
        assert_eq!(store.known("/wt/feat/x"), None, "a failed lookup is not \"no PR\"");
        store.refresh(&wts, t0 + TTL);
        assert_eq!(fake.looked_up.lock().unwrap().len(), 1, "a failure waits five minutes");
        *fake.by_head.lock().unwrap() = Some(HashMap::from([("feat/x".to_string(), done(3, State::Closed))]));
        store.refresh(&wts, t0 + FAILURE_TTL);
        assert_eq!(store.known("/wt/feat/x").flatten().map(|p| p.state), Some(State::Closed));
    }

    #[test]
    fn the_recent_list_wins_and_finished_prs_in_it_need_no_lookup() {
        let (fake, store, wts) = branch_store(&["feat/a", "feat/m"]);
        *fake.answer.lock().unwrap() = Some(HashMap::from([("feat/a".to_string(), pr(1)), ("feat/m".to_string(), done(2, State::Merged))]));
        let t0 = Instant::now();
        store.refresh(&wts, t0);
        assert!(fake.looked_up.lock().unwrap().is_empty(), "every branch covered by the recent list");
        // feat/m drops out of the 30 most recent: its merged PR stays known
        // without a request.
        *fake.answer.lock().unwrap() = Some(HashMap::from([("feat/a".to_string(), pr(1))]));
        store.refresh(&wts, t0 + TTL);
        assert!(fake.looked_up.lock().unwrap().is_empty());
        assert_eq!(store.status("/wt/feat/m").map(|p| p.number), Some(2));
    }

    #[test]
    fn default_branches_are_never_looked_up_and_lookups_are_capped() {
        let names: Vec<String> = (0..BRANCH_QUERY_MAX + 5).map(|i| format!("f{i:02}")).collect();
        let mut all: Vec<&str> = names.iter().map(String::as_str).collect();
        all.push("main");
        let (fake, store, wts) = branch_store(&all);
        let t0 = Instant::now();
        store.refresh(&wts, t0);
        assert_eq!(store.known("/wt/main"), Some(None));
        store.refresh(&wts, t0 + Duration::from_secs(15));
        let asked = fake.looked_up.lock().unwrap().clone();
        assert_eq!(asked.len(), 2, "the rest waits a tick");
        assert_eq!(asked[0].len(), BRANCH_QUERY_MAX);
        assert_eq!(asked[1].len(), 5);
        assert!(asked.iter().flatten().all(|b| b != "main"));
    }

    #[test]
    fn branch_answers_skip_forks_and_read_every_alias() {
        let mut fork = node(9, "fix", "OPEN", false, "someone", None, None);
        fork["headRefName"] = json!("fix");
        let ours = node(5, "fix", "MERGED", false, "acme", None, None);
        let v = json!({"data": {"repository": {"b0": {"nodes": [fork, ours]}, "b1": {"nodes": []}}}});
        let a = parse_branch_answers(&v, "acme", &["fix".to_string(), "lonely".to_string()]).unwrap();
        assert_eq!(a["fix"].as_ref().map(|p| p.number), Some(5));
        assert_eq!(a["lonely"], None);
        assert_eq!(parse_branch_answers(&json!({"data": {"repository": null}}), "acme", &[]), None);
        let q = branch_query(2);
        assert!(q.contains("$b1: String!") && q.contains("b1: pullRequests(headRefName: $b1"));
    }

    fn pr(n: u64) -> PrStatus {
        PrStatus { body: String::new(), number: n, url: "u".into(), state: State::Open, checks: Some(Checks::Passing), review: None, head_oid: None, merged_at: None }
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

#[cfg(test)]
mod routing_cache_tests {
    use super::*;
    #[test]
    fn routing_has_closing_bodies_even_without_a_worktree() {
        let response=json!({"data":{"repository":{"pullRequests":{"nodes":[{
            "number":99,"url":"https://github.com/o/r/pull/99","state":"MERGED","headRefName":"fix-login","headRepositoryOwner":{"login":"o"},"body":"Resolves #42"
        }]}}}});
        let parsed=parse_statuses(&response,"o"); assert_eq!(parsed["fix-login"].body,"Resolves #42");
        let store=PrStore::new(Box::new(Live));
        store.lock().repos.insert("o/r".into(),RepoEntry{by_branch:parsed,at:Instant::now(),ok:true});
        assert!(store.list().is_empty());
        {
            let mut inner=store.lock();
            inner.branches.insert("/scratch/repo".into(),"fix-login".into());
            inner.remotes.insert("/scratch/repo".into(),Some("o/r".into()));
        }
        let polled=store.list(); assert_eq!(polled.len(),1);
        assert!(polled[0]["pr"].get("body").is_none());
        assert!(store.status("/scratch/repo").unwrap().to_json().get("body").is_none());
        let rows=store.routing_list(); assert_eq!(rows.len(),1); assert!(rows[0].get("worktree_path").is_none());
        assert_eq!(rows[0]["pr"]["body"],"Resolves #42");
        assert!(crate::first_mate::routing::duplicate_issue("o/r",42,"","",&rows,None).unwrap().contains("PR #99"));
        assert!(QUERY.contains("body")); assert!(branch_query(1).contains("body"));
    }
}
