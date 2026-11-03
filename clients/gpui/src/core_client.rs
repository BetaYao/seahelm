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
    std::env::var_os("SEAHELM_CORE_BIN").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("seahelm-core"))
}

/// Start the service unless it answers already. Errors are reported, not
/// fatal: without it the window still works, with the app's statuses only.
pub fn ensure() {
    if call("core.ping", json!({})).is_ok() {
        return;
    }
    match std::process::Command::new(binary()).arg("ensure").status() {
        Ok(s) if s.success() => {}
        Ok(s) => eprintln!("seahelm-gpui: seahelm-core ensure exited {s}"),
        Err(e) => eprintln!("seahelm-gpui: cannot start seahelm-core ({e}); statuses come from the app only"),
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
