//! The fleet: every project's worktrees, as the macOS app sees them.
//!
//! Read from the running app's control socket (`fleet.groups`, `pane.list`),
//! the same calls the web client makes; read only, nothing is changed there.
//! Git stats are not in that payload, so they are worked out here, on a
//! thread of their own, from each worktree's checkout.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};

use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Deserialize;

#[derive(Clone, Debug, Deserialize)]
pub struct Item {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub subtitle: String,
    #[serde(default)]
    pub repository: String,
    #[serde(default)]
    pub status: String,
    pub worktree_path: String,
    #[serde(default)]
    pub is_main_worktree: bool,
    pub last_activity_at: Option<f64>,
    pub running_since: Option<f64>,
    #[serde(default)]
    pub unseen: bool,
    pub pr: Option<Pr>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Pr {
    pub number: u64,
    #[serde(default)]
    pub state: String,
    pub checks: Option<String>,
    pub review: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Group {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub items: Vec<Item>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GitStats {
    pub added: u64,
    pub removed: u64,
    pub ahead: u64,
    pub behind: u64,
}

/// One reading of the fleet.
#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub groups: Vec<Group>,
    pub panes: HashMap<String, usize>,
    pub running: usize,
    /// Why there is no fleet, when there is none.
    pub error: Option<String>,
}

impl Snapshot {
    pub fn worktree_count(&self) -> usize {
        self.groups.iter().map(|g| g.items.len()).sum()
    }

    pub fn find(&self, id: &str) -> Option<&Item> {
        self.groups.iter().flat_map(|g| g.items.iter()).find(|i| i.id == id)
    }
}

/// What a row shows for an item's status.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dot {
    Running,
    Waiting,
    Idle,
    Error,
    Exited,
    Unknown,
    Unseen,
}

impl Item {
    pub fn dot(&self) -> Dot {
        if self.unseen {
            return Dot::Unseen;
        }
        match self.status.as_str() {
            "Running" => Dot::Running,
            "Waiting" | "Blocked" | "NeedsInput" => Dot::Waiting,
            "Idle" => Dot::Idle,
            "Error" => Dot::Error,
            "Exited" => Dot::Exited,
            _ => Dot::Unknown,
        }
    }

    /// The time label: how long it has run, while running; else how long ago
    /// it last did anything (`WorktreeRowHelpers.swift`).
    pub fn time_label(&self, now: f64) -> String {
        if self.dot() == Dot::Running {
            if let Some(since) = self.running_since {
                return compact_duration((now - since).max(0.0));
            }
        }
        match self.last_activity_at {
            Some(at) => relative_age((now - at).max(0.0)),
            None => String::new(),
        }
    }
}

pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// "12s", "3m05s", "1h02m".
pub fn compact_duration(secs: f64) -> String {
    let s = secs as u64;
    if s < 60 {
        format!("{s}s")
    } else if s < 3600 {
        format!("{}m{:02}s", s / 60, s % 60)
    } else {
        format!("{}h{:02}m", s / 3600, (s % 3600) / 60)
    }
}

/// "just now", "Ns", "Nm", "Nh", "Nd".
pub fn relative_age(secs: f64) -> String {
    let s = secs as u64;
    if s < 10 {
        "just now".into()
    } else if s < 60 {
        format!("{s}s")
    } else if s < 3600 {
        format!("{}m", s / 60)
    } else if s < 86400 {
        format!("{}h", s / 3600)
    } else {
        format!("{}d", s / 86400)
    }
}

/// One JSON-RPC call to the app.
fn call(method: &str, params: serde_json::Value) -> Result<serde_json::Value, String> {
    let mut sock = crate::platform::connect(&crate::platform::app_socket()).map_err(|e| format!("Seahelm is not running ({e})"))?;
    sock.set_read_timeout(Some(Duration::from_secs(5))).ok();
    let req = serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
    let mut line = serde_json::to_vec(&req).map_err(|e| e.to_string())?;
    line.push(b'\n');
    sock.write_all(&line).map_err(|e| e.to_string())?;
    let mut reply = String::new();
    BufReader::new(sock).read_line(&mut reply).map_err(|e| e.to_string())?;
    let mut value: serde_json::Value = serde_json::from_str(&reply).map_err(|e| e.to_string())?;
    if let Some(err) = value.get("error") {
        return Err(err.to_string());
    }
    Ok(value.get_mut("result").map(serde_json::Value::take).unwrap_or(value))
}

pub fn read() -> Snapshot {
    let groups = match call("fleet.groups", serde_json::json!({"mode": "repository"})) {
        Ok(v) => v.get("groups").cloned().and_then(|g| serde_json::from_value::<Vec<Group>>(g).ok()),
        Err(e) => return Snapshot { error: Some(e), ..Snapshot::default() },
    };
    let Some(groups) = groups else {
        return Snapshot { error: Some("unexpected fleet.groups reply".into()), ..Snapshot::default() };
    };
    let mut panes = HashMap::new();
    if let Ok(v) = call("pane.list", serde_json::json!({})) {
        for p in v.get("panes").and_then(|p| p.as_array()).into_iter().flatten() {
            if let Some(path) = p.get("worktree_path").and_then(|w| w.as_str()) {
                *panes.entry(path.to_string()).or_insert(0) += 1;
            }
        }
    }
    let running = groups.iter().flat_map(|g| &g.items).filter(|i| i.status == "Running").count();
    Snapshot { groups, panes, running, error: None }
}

fn git(path: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("git").arg("-C").arg(path).args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// What this worktree changes against where it branched from (the default
/// branch), uncommitted work included; and where it stands to its upstream.
pub fn git_stats(path: &str) -> Option<GitStats> {
    let base = git(path, &["rev-parse", "--abbrev-ref", "origin/HEAD"]).unwrap_or_else(|| "main".into());
    let fork = git(path, &["merge-base", "HEAD", &base]).unwrap_or_else(|| "HEAD".into());
    let short = git(path, &["diff", "--shortstat", &fork])?;
    let mut stats = GitStats::default();
    for part in short.split(',') {
        let part = part.trim();
        let n: u64 = part.split_whitespace().next().and_then(|n| n.parse().ok()).unwrap_or(0);
        if part.contains("insertion") {
            stats.added = n;
        } else if part.contains("deletion") {
            stats.removed = n;
        }
    }
    if let Some(counts) = git(path, &["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]) {
        let mut it = counts.split_whitespace().filter_map(|n| n.parse().ok());
        stats.ahead = it.next().unwrap_or(0);
        stats.behind = it.next().unwrap_or(0);
    }
    Some(stats)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn times_read_as_the_app_writes_them() {
        assert_eq!(relative_age(3.0), "just now");
        assert_eq!(relative_age(42.0), "42s");
        assert_eq!(relative_age(125.0), "2m");
        assert_eq!(relative_age(7300.0), "2h");
        assert_eq!(relative_age(200000.0), "2d");
        assert_eq!(compact_duration(12.0), "12s");
        assert_eq!(compact_duration(185.0), "3m05s");
        assert_eq!(compact_duration(3720.0), "1h02m");
    }

    #[test]
    fn a_fleet_groups_reply_parses() {
        let json = r#"[{"id":"repository:seahelm","title":"seahelm","items":[
            {"id":"/w/a","title":"main","subtitle":"main","repository":"seahelm","status":"Running",
             "worktree_path":"/w/a","is_main_worktree":true,"running_since":100,
             "pr":{"number":12,"url":"u","state":"OPEN","checks":"SUCCESS"}}]}]"#;
        let groups: Vec<Group> = serde_json::from_str(json).unwrap();
        let item = &groups[0].items[0];
        assert_eq!(item.dot(), Dot::Running);
        assert_eq!(item.time_label(112.0), "12s");
        assert_eq!(item.pr.as_ref().unwrap().number, 12);
    }
}
