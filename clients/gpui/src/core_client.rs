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
    ensure_gateway();
}

/// Start seahelm-gateway (web access and Telegram,
/// docs/seahelm-gateway-plan.md) unless it runs already. It does nothing
/// until web access or Telegram is turned on in its settings
/// (`seahelm-gateway call gateway.config.set …`).
pub fn ensure_gateway() {
    let gateway = crate::platform::tool("seahelm-gateway", "SEAHELM_GATEWAY_BIN");
    match std::process::Command::new(gateway).arg("ensure").status() {
        Ok(s) if s.success() => {}
        Ok(s) => eprintln!("seahelm-gpui: seahelm-gateway ensure exited {s}"),
        Err(e) => eprintln!("seahelm-gpui: cannot start seahelm-gateway ({e}); no web access or Telegram"),
    }
}

pub fn call(method: &str, params: Value) -> Result<Value, String> {
    call_at(&socket(), method, params)
}

/// One newline-delimited JSON-RPC call on `path` (the core's socket, or
/// seahelm-gateway's admin one): the result, or the error as text.
pub fn call_at(path: &std::path::Path, method: &str, params: Value) -> Result<Value, String> {
    let mut stream = crate::platform::connect(path).map_err(|e| e.to_string())?;
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
    /// The row's title (session summary, else the last prompt), when the
    /// core has one.
    pub title: Option<String>,
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
                    title: w.get("title").and_then(Value::as_str).filter(|t| !t.trim().is_empty()).map(str::to_string),
                    status: w.get("status").and_then(Value::as_str).unwrap_or("Unknown").to_string(),
                    unseen: w.get("unseen").and_then(Value::as_bool).unwrap_or(false),
                    running_since: w.get("running_since").and_then(Value::as_f64),
                    last_activity_at: w.get("last_activity_at").and_then(Value::as_f64),
                },
            ))
        })
        .collect()
}

/// The event `subscribe` hands over on every (re)connect.
pub const CONNECTED: &str = "core.connected";

/// Follow the core's event stream (`events.subscribe`) on a thread of its
/// own, handing each event to `tx`; reconnects (after the core restarts,
/// say) with a growing pause. Ends when `tx` is closed.
pub fn subscribe(types: &[&str], tx: futures::channel::mpsc::UnboundedSender<Value>) {
    let types: Vec<String> = types.iter().map(|t| t.to_string()).collect();
    let _ = std::thread::Builder::new().name("seahelm-core-events".into()).spawn(move || {
        let mut pause = Duration::from_secs(1);
        while !tx.is_closed() {
            if let Ok(mut stream) = crate::platform::connect(&socket()) {
                let req = json!({"jsonrpc": "2.0", "id": 1, "method": "events.subscribe", "params": {"types": types}});
                let mut line = serde_json::to_vec(&req).unwrap_or_default();
                line.push(b'\n');
                if stream.write_all(&line).is_ok() {
                    pause = Duration::from_secs(1);
                    // Not the core's: says a (re)connect happened, so the
                    // client can tell a restarted core what it lost.
                    if tx.unbounded_send(json!({"type": CONNECTED})).is_err() {
                        return;
                    }
                    // The core pings every 15 s; a minute of silence is a dead core.
                    stream.set_read_timeout(Some(Duration::from_secs(60))).ok();
                    for line in BufReader::new(stream).lines() {
                        let Ok(line) = line else { break };
                        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                        let Some(ev) = event_of(v) else { continue };
                        if tx.unbounded_send(ev).is_err() {
                            return;
                        }
                    }
                }
            }
            std::thread::sleep(pause);
            pause = (pause * 2).min(Duration::from_secs(30));
        }
    });
}

/// Something waiting on the user (`cards.list`, `cards.changed`): an agent's
/// question or suggestion, a choice on screen, First Mate's asks.
#[derive(Clone, Debug, Default, PartialEq, serde::Deserialize)]
pub struct Card {
    pub id: String,
    pub kind: String,
    #[serde(default)]
    pub pane_session_key: String,
    #[serde(default)]
    pub worktree_path: String,
    #[serde(default)]
    pub project: String,
    #[serde(default)]
    pub branch: String,
    #[serde(default)]
    pub message: String,
    /// What to show and tap, in order (ticks and Done on a multi-select).
    #[serde(default)]
    pub labels: Vec<String>,
    #[serde(default)]
    pub fresh_at: f64,
}

pub fn parse_cards(v: &Value) -> Vec<Card> {
    v.get("cards").and_then(Value::as_array).into_iter().flatten().filter_map(|c| serde_json::from_value(c.clone()).ok()).collect()
}

/// Every card on offer, oldest first; empty without a core.
pub fn cards() -> Vec<Card> {
    call("cards.list", json!({})).map(|v| parse_cards(&v)).unwrap_or_default()
}

/// Answer a card with its `index`th label; the core presses the keys.
pub fn answer_card(id: &str, index: usize) -> Result<(), String> {
    call("cards.answer", json!({"id": id, "index": index})).map(|_| ())
}

/// First Mate as the core reports it (`autopilot.state`), plus whether its
/// seahelmd session is up — it may be the macOS app's, when the core does
/// not own First Mate. None when the core does not answer.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FirstMate {
    /// The core runs First Mate.
    pub enabled: bool,
    /// off / starting / watching / thinking / needs you / paused.
    pub activity: String,
    pub detail: String,
    pub session_live: bool,
}

pub const FIRST_MATE_SESSION: &str = "seahelm-first-mate";

pub fn first_mate() -> Option<FirstMate> {
    let v = call("autopilot.state", json!({})).ok()?;
    let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or_default().to_string();
    Some(FirstMate {
        enabled: v.get("enabled").and_then(Value::as_bool).unwrap_or(false),
        activity: s("activity"),
        detail: s("detail"),
        session_live: seahelmd::client::connect(FIRST_MATE_SESSION).is_ok(),
    })
}

pub fn dismiss_card(id: &str) -> Result<(), String> {
    call("cards.dismiss", json!({"id": id})).map(|_| ())
}

/// The event in one line of the stream: `{"method": "event", "params": {…}}`.
/// Replies and pings are not events.
fn event_of(mut line: Value) -> Option<Value> {
    if line.get("method").and_then(Value::as_str) != Some("event") {
        return None;
    }
    let ev = line.get_mut("params").map(Value::take)?;
    ev.get("type").is_some().then_some(ev)
}

#[cfg(test)]
mod event_tests {
    use super::*;

    #[test]
    fn events_come_in_their_envelope() {
        let line = json!({"jsonrpc": "2.0", "method": "event", "params": {"type": "pane.notice", "seq": 3}});
        assert_eq!(event_of(line).unwrap()["type"], "pane.notice");
        assert!(event_of(json!({"jsonrpc": "2.0", "method": "ping"})).is_none());
        assert!(event_of(json!({"jsonrpc": "2.0", "id": null, "result": {"subscribed": true}})).is_none());
    }
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

/// One window of a provider's usage (`usage.summary` readouts): "5h", "42%",
/// and how much is used ("ok", "warn", "critical").
#[derive(Clone, Debug, PartialEq)]
pub struct UsageSegment {
    pub label: String,
    pub percent: String,
    pub severity: String,
}

/// A provider's windows that have a reading; providers with none left out.
#[derive(Clone, Debug, PartialEq)]
pub struct UsageReadout {
    pub name: String,
    pub segments: Vec<UsageSegment>,
}

/// Claude's and Codex's rate limits as the core reads them (`usage.summary`);
/// empty when it has nothing, or is not running.
pub fn usage() -> Vec<UsageReadout> {
    let Ok(v) = call("usage.summary", json!({})) else { return Vec::new() };
    parse_usage(&v)
}

pub fn parse_usage(v: &Value) -> Vec<UsageReadout> {
    v.get("readouts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|r| {
            let segments: Vec<UsageSegment> = r
                .get("segments")?
                .as_array()?
                .iter()
                .filter_map(|s| {
                    let percent = s.get("percent_text")?.as_str()?;
                    (percent != "--").then(|| UsageSegment {
                        label: s.get("label").and_then(Value::as_str).unwrap_or("").to_string(),
                        percent: percent.to_string(),
                        severity: s.get("severity").and_then(Value::as_str).unwrap_or("unknown").to_string(),
                    })
                })
                .collect();
            let name = r.get("name").and_then(Value::as_str)?.to_string();
            (!segments.is_empty()).then_some(UsageReadout { name, segments })
        })
        .collect()
}

#[cfg(test)]
mod usage_tests {
    use super::*;

    #[test]
    fn windows_without_a_reading_are_left_out() {
        let v = json!({"readouts": [
            {"provider": "claude", "name": "Claude", "segments": [
                {"label": "5h", "percent_text": "--", "severity": "unknown"},
                {"label": "7d", "percent_text": "42%", "severity": "ok"}]},
            {"provider": "codex", "name": "Codex", "segments": [
                {"label": "quota", "percent_text": "--", "severity": "unknown"}]}
        ]});
        let r = parse_usage(&v);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].name, "Claude");
        assert_eq!(r[0].segments, vec![UsageSegment { label: "7d".into(), percent: "42%".into(), severity: "ok".into() }]);
        assert!(parse_usage(&json!({})).is_empty());
    }
}
