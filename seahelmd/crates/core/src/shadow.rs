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
