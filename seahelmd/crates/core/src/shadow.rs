//! Shadow mode: run the core beside the macOS app and count where they
//! disagree, before any client trusts the core (docs/status-core-port.md,
//! "Verification").
//!
//! `--follow-app` also feeds the app's panes to the core (`pane.sync`), so the
//! core watches exactly what the app watches without the app knowing about it.
//! A disagreement counts once it has lasted longer than `GRACE`: the two sides
//! poll on their own clocks and debounce differently, so a flip seen by one a
//! poll before the other is not a finding.

use std::collections::{BTreeMap, HashMap};
use std::io::Write;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use serde_json::{json, Value};

use crate::rpc;

const GRACE: Duration = Duration::from_secs(8);
const PERIOD: Duration = Duration::from_secs(2);

pub fn run(args: &[String]) -> Result<()> {
    let follow = args.iter().any(|a| a == "--follow-app");
    let seconds: u64 = args
        .iter()
        .position(|a| a == "--seconds")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(u64::MAX);
    let log_path = rpc::config_dir().join("core-shadow.jsonl");
    let mut log = std::fs::OpenOptions::new().create(true).append(true).open(&log_path)?;
    eprintln!("shadow: comparing every {}s, grace {}s; disagreements → {}", PERIOD.as_secs(), GRACE.as_secs(), log_path.display());

    let started = Instant::now();
    // pane → (app status, core status, since)
    let mut open: HashMap<String, (String, String, Instant)> = HashMap::new();
    let mut tally: BTreeMap<(String, String), (u32, Duration)> = BTreeMap::new();
    let mut agreed_polls: u64 = 0;
    let mut compared_polls: u64 = 0;

    while started.elapsed().as_secs() < seconds {
        let tick = Instant::now();
        let app = rpc::call(&rpc::app_socket(), "pane.list", json!({})).context("app pane.list")?;
        let app_panes = app.get("panes").and_then(Value::as_array).cloned().unwrap_or_default();
        if follow {
            let worktrees = rpc::call(&rpc::app_socket(), "fleet.groups", json!({"mode": "repository"}))
                .ok()
                .map(|v| worktree_paths(&v))
                .unwrap_or_default();
            rpc::call(&rpc::core_socket(), "worktrees.set", json!({"paths": worktrees}))?;
            rpc::call(&rpc::core_socket(), "pane.sync", json!({"panes": app_panes}))?;
        }
        let core = rpc::call(&rpc::core_socket(), "pane.list", json!({}))?;
        let core_status: HashMap<String, String> = core
            .get("panes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|p| Some((str_of(p, "pane_session_key")?, str_of(p, "status")?)))
            .collect();

        for p in &app_panes {
            let (Some(key), Some(app_status)) = (str_of(p, "pane_session_key"), str_of(p, "status")) else { continue };
            let Some(core_status) = core_status.get(&key).cloned() else { continue };
            compared_polls += 1;
            if core_status == app_status {
                agreed_polls += 1;
                if let Some((a, c, since)) = open.remove(&key) {
                    close(&mut log, &mut tally, &key, &a, &c, since.elapsed())?;
                }
                continue;
            }
            match open.get(&key) {
                Some((a, c, _)) if *a == app_status && *c == core_status => {}
                Some((a, c, since)) => {
                    let (a, c, d) = (a.clone(), c.clone(), since.elapsed());
                    close(&mut log, &mut tally, &key, &a, &c, d)?;
                    open.insert(key.clone(), (app_status, core_status, Instant::now()));
                }
                None => {
                    open.insert(key.clone(), (app_status, core_status, Instant::now()));
                }
            }
        }
        std::thread::sleep(PERIOD.saturating_sub(tick.elapsed()));
        if compared_polls > 0 && started.elapsed().as_secs() % 60 < PERIOD.as_secs() {
            report(&tally, agreed_polls, compared_polls);
        }
    }
    for (key, (a, c, since)) in open.drain() {
        close(&mut log, &mut tally, &key, &a, &c, since.elapsed())?;
    }
    report(&tally, agreed_polls, compared_polls);
    Ok(())
}

fn close(
    log: &mut std::fs::File,
    tally: &mut BTreeMap<(String, String), (u32, Duration)>,
    pane: &str,
    app: &str,
    core: &str,
    lasted: Duration,
) -> Result<()> {
    if lasted < GRACE {
        return Ok(());
    }
    let entry = tally.entry((app.to_string(), core.to_string())).or_default();
    entry.0 += 1;
    entry.1 += lasted;
    let line = json!({"at": seahelm_core_types::now(), "pane": pane, "app": app, "core": core, "seconds": lasted.as_secs_f64()});
    writeln!(log, "{line}")?;
    Ok(())
}

fn report(tally: &BTreeMap<(String, String), (u32, Duration)>, agreed: u64, compared: u64) {
    let pct = if compared == 0 { 100.0 } else { agreed as f64 * 100.0 / compared as f64 };
    eprintln!("shadow: {agreed}/{compared} pane-polls agree ({pct:.1}%)");
    for ((app, core), (n, total)) in tally {
        eprintln!("  app {app:<8} core {core:<8} ×{n:<4} {:.0}s total", total.as_secs_f64());
    }
}

fn str_of(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).map(str::to_string)
}

/// Every worktree path in a `fleet.groups` reply.
pub fn worktree_paths(groups: &Value) -> Vec<String> {
    groups
        .get("groups")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .flat_map(|g| g.get("items").and_then(Value::as_array).cloned().unwrap_or_default())
        .filter_map(|i| str_of(&i, "worktree_path"))
        .collect()
}

/// `seahelm-core compare-messages [--since SECS] [--quiet]`: one look at
/// each pane's message timeline in the app and in the core, rows of the
/// same stretch of time aligned (longest common subsequence of kind and
/// content), and what only one side has. A line per pane to
/// `core-messages-shadow.jsonl`; a summary on stdout.
pub fn compare_messages(args: &[String]) -> Result<()> {
    let since_arg: Option<f64> = args.iter().position(|a| a == "--since").and_then(|i| args.get(i + 1)).and_then(|s| s.parse().ok());
    let quiet = args.iter().any(|a| a == "--quiet");
    let app = rpc::call(&rpc::app_socket(), "message.snapshot", json!({})).context("app message.snapshot")?;
    let core = rpc::call(&rpc::core_socket(), "message.snapshot", json!({})).context("core message.snapshot")?;
    let by_key = |v: &Value| -> BTreeMap<String, Vec<Value>> {
        let mut m: BTreeMap<String, Vec<Value>> = BTreeMap::new();
        for row in v.get("messages").and_then(Value::as_array).into_iter().flatten() {
            if let Some(k) = str_of(row, "pane_session_key").filter(|k| !k.is_empty()) {
                m.entry(k).or_default().push(row.clone());
            }
        }
        m
    };
    let (app, core) = (by_key(&app), by_key(&core));
    let mut log = std::fs::OpenOptions::new().create(true).append(true).open(rpc::config_dir().join("core-messages-shadow.jsonl"))?;
    let (mut matched, mut only_app, mut only_core) = (0usize, 0usize, 0usize);
    for (key, core_rows) in &core {
        let Some(app_rows) = app.get(key) else { continue };
        // The stretch both have watched: from the later of the two first rows.
        let first = |rows: &Vec<Value>| rows.iter().filter_map(|r| r.get("ts").and_then(Value::as_f64)).fold(f64::MAX, f64::min);
        let from = since_arg.map(|s| seahelm_core_types::now() - s).unwrap_or_else(|| first(app_rows).max(first(core_rows)));
        let a = signatures(app_rows, from);
        let c = signatures(core_rows, from);
        if a.is_empty() && c.is_empty() {
            continue;
        }
        let common = lcs(&a, &c);
        let (oa, oc) = (a.len() - common, c.len() - common);
        matched += common;
        only_app += oa;
        only_core += oc;
        writeln!(log, "{}", json!({"at": seahelm_core_types::now(), "pane": key, "matched": common, "only_app": oa, "only_core": oc}))?;
        if !quiet && (oa > 0 || oc > 0) {
            println!("{key}: {common} matched, {oa} only in the app, {oc} only in the core");
            for s in a.iter().filter(|s| !c.contains(s)).take(3) {
                println!("  app : {s}");
            }
            for s in c.iter().filter(|s| !a.contains(s)).take(3) {
                println!("  core: {s}");
            }
        }
    }
    let total = matched + only_app + only_core;
    let pct = if total == 0 { 100.0 } else { matched as f64 * 100.0 / total as f64 };
    println!("messages: {matched} rows agree, {only_app} only in the app, {only_core} only in the core ({pct:.1}%)");
    Ok(())
}

/// A row as compared: kind and what it says, from `from` on.
fn signatures(rows: &[Value], from: f64) -> Vec<String> {
    rows.iter()
        .filter(|r| r.get("ts").and_then(Value::as_f64).unwrap_or(0.0) >= from)
        .map(|r| {
            let s = |k: &str| str_of(r, k).unwrap_or_default();
            let body = match s("kind").as_str() {
                "tool" => format!("{} {}", s("tool"), s("detail")),
                "status" => format!("{}→{}", s("old_status"), s("status")),
                _ => s("text").chars().take(120).collect(),
            };
            format!("{}: {}", s("kind"), body.trim())
        })
        .collect()
}

fn lcs(a: &[String], b: &[String]) -> usize {
    let mut prev = vec![0usize; b.len() + 1];
    for x in a {
        let mut cur = vec![0usize; b.len() + 1];
        for (j, y) in b.iter().enumerate() {
            cur[j + 1] = if x == y { prev[j] + 1 } else { prev[j + 1].max(cur[j]) };
        }
        prev = cur;
    }
    prev[b.len()]
}

#[cfg(test)]
mod message_tests {
    use super::*;

    #[test]
    fn aligns_rows_and_counts_what_one_side_lacks() {
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert_eq!(lcs(&s(&["user: a", "tool: Bash ls", "assistant: done"]), &s(&["user: a", "assistant: done"])), 2);
        let rows = vec![
            json!({"kind": "tool", "tool": "Read", "detail": "a.rs", "ts": 5.0}),
            json!({"kind": "status", "old_status": "Running", "status": "Idle", "ts": 6.0}),
            json!({"kind": "user", "text": "old", "ts": 1.0}),
        ];
        assert_eq!(signatures(&rows, 2.0), s(&["tool: Read a.rs", "status: Running→Idle"]));
    }
}
