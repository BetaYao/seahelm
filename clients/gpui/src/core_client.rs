//! Talking to seahelm-core: the status service every client shares
//! (docs/status-core-port.md). The client registers the panes it opens,
//! says which worktree it shows, and reads back each worktree's state.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::time::Duration;

use serde_json::{json, Value};

/// `$SEAHELM_CORE_SOCKET`, else `~/.config/seahelm/core.sock` (a named
/// pipe on Windows).
pub fn socket() -> PathBuf {
    crate::platform::core_socket()
}

/// `$SEAHELM_CORE_BIN`, then `seahelm-core` on PATH.
fn binary() -> PathBuf {
    crate::platform::tool("seahelm-core", "SEAHELM_CORE_BIN")
}

/// Start the service unless it answers already, and wire the agents'
/// hooks to it (`seahelm-core install-hooks`, idempotent: it leaves hooks
/// that already reach the core alone). Errors are reported, not fatal:
/// without the core the window still works, with no statuses.
pub fn ensure() {
    if call("core.ping", json!({})).is_err() {
        match std::process::Command::new(binary()).arg("ensure").status() {
            Ok(s) if s.success() => {}
            Ok(s) => eprintln!("seahelm-gpui: seahelm-core ensure exited {s}"),
            Err(e) => {
                eprintln!("seahelm-gpui: cannot start seahelm-core ({e}); no statuses");
                return;
            }
        }
    }
    match std::process::Command::new(binary()).arg("install-hooks").output() {
        Ok(out) if out.status.success() => {}
        Ok(out) => eprintln!("seahelm-gpui: seahelm-core install-hooks: {}", String::from_utf8_lossy(&out.stderr).trim()),
        Err(e) => eprintln!("seahelm-gpui: seahelm-core install-hooks: {e}"),
    }
}

pub fn call(method: &str, params: Value) -> Result<Value, String> {
    let mut stream = crate::platform::connect(&socket()).map_err(|e| e.to_string())?;
    stream.set_read_timeout(Some(Duration::from_secs(5))).ok();
    let mut line = serde_json::to_vec(&json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))
        .map_err(|e| e.to_string())?;
    line.push(b'\n');
    stream.write_all(&line).map_err(|e| e.to_string())?;
    let mut reply = String::new();
    BufReader::new(stream).read_line(&mut reply).map_err(|e| e.to_string())?;
    let mut v: Value = serde_json::from_str(&reply).map_err(|e| e.to_string())?;
    if let Some(e) = v.get("error") {
        return Err(e.to_string());
    }
    Ok(v.get_mut("result").map(Value::take).unwrap_or(Value::Null))
}

/// What the core says about one worktree.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct WorktreeState {
    pub status: String,
    pub unseen: bool,
    pub running_since: Option<f64>,
    pub last_activity_at: Option<f64>,
}

/// Every worktree the core has panes in, by path.
pub fn worktrees() -> std::collections::HashMap<String, WorktreeState> {
    let Ok(v) = call("worktree.list", json!({})) else { return Default::default() };
    v.get("worktrees")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|w| {
            let path = w.get("worktree_path")?.as_str()?.to_string();
            Some((
                path,
                WorktreeState {
                    status: w.get("status").and_then(Value::as_str).unwrap_or("Unknown").to_string(),
                    unseen: w.get("unseen").and_then(Value::as_bool).unwrap_or(false),
                    running_since: w.get("running_since").and_then(Value::as_f64),
                    last_activity_at: w.get("last_activity_at").and_then(Value::as_f64),
                },
            ))
        })
        .collect()
}

/// A worktree's pull request, as the core files it (`pr.list`; the app's
/// `fleet.groups` item `pr` shape).
#[derive(Clone, Debug, Default, PartialEq, serde::Deserialize)]
pub struct Pr {
    pub number: u64,
    #[serde(default)]
    pub url: String,
    /// open / draft / merged / closed.
    #[serde(default)]
    pub state: String,
    /// passing / failing / pending, while the PR is live.
    pub checks: Option<String>,
    /// approved / changes_requested / review_required, while live.
    pub review: Option<String>,
}

/// Every known worktree's PR, by path. The core asks GitHub for the
/// worktrees `set_worktrees` lists (and those with panes).
pub fn prs() -> std::collections::HashMap<String, Pr> {
    let Ok(v) = call("pr.list", json!({})) else { return Default::default() };
    v.get("prs")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|e| {
            let path = e.get("worktree_path")?.as_str()?.to_string();
            let pr: Pr = serde_json::from_value(e.get("pr")?.clone()).ok()?;
            Some((path, pr))
        })
        .collect()
}

/// Tell the core every worktree the fleet shows, so it watches their PRs
/// even where no pane is open.
pub fn set_worktrees(paths: &[String]) {
    let _ = call("worktrees.set", json!({"paths": paths}));
}
