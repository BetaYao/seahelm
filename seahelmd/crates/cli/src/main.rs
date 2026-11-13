//! `seahelm`: the command line for agents and people inside a pane (the
//! `seahelm` skill). It speaks newline-delimited JSON-RPC to two sockets,
//! by the split in docs/target-architecture.html ("two kinds of control"):
//!
//! - **seahelm-core** (`$SEAHELM_CORE_SOCKET`, else
//!   `~/.config/seahelm/core.sock`, a named pipe on Windows) answers what
//!   works with every client closed: listing, reading, typing into and
//!   waiting on panes, and the event stream.
//! - **the macOS app** (`$SEAHELM_SOCKET_PATH`, else
//!   `~/.config/seahelm/seahelm.sock`) answers what only the side drawing
//!   the panes can do: split, focus, zoom, move, fork, layouts, `exec`.
//!
//! A core verb goes to the app when the core cannot be reached, or does not
//! know the pane yet (one split a moment ago); worktree create/delete and
//! close go to the app first and to the core without one. A call that
//! reached either side is never sent again. The app installs this as
//! `~/.local/bin/seahelm` (`SeahelmCliInstaller`).
//!
//! Every call carries `_meta.caller` (`$SEAHELM_PANE_ID`) and, after a global
//! `--note "…"`, `_meta.note`: the pane acted on shows who is acting. Errors
//! go to stderr as `seahelm: …` with exit code 2 unless a call says
//! otherwise.

use std::process::exit;

use serde_json::{json, Map, Value};

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut note = None;
    while args.first().map(String::as_str) == Some("--note") {
        if args.len() < 2 {
            die("--note needs a value", 2);
        }
        note = Some(args[1].clone());
        args.drain(..2);
    }
    let Some((group, rest)) = args.split_first() else {
        die("usage: seahelm <ping|memory|session|pane|wait|events|layout|worktree|habit|schedule> ...", 2)
    };
    let cli = Cli { note };
    cli.run(group, rest);
}

fn task_source_params(raw:&str,repo:&str,read:impl FnOnce()->Result<String,String>)->Result<Value,String>{
    let mut source:Value=serde_json::from_str(raw).map_err(|_|"invalid source JSON")?;
    let kind=source["kind"].as_str().ok_or("source kind required")?;
    if !["github","jira-cloud","jira-server"].contains(&kind){return Err("invalid source kind".into())}
    let jira=kind!="github";
    source["repo"]=json!(repo);
    let mut params=json!({"repo":repo,"source":source});
    if jira{params["credential"]=serde_json::from_str(&read()?).map_err(|_|"invalid credential JSON")?;}
    Ok(params)
}

struct Cli {
    note: Option<String>,
}

impl Cli {
    fn run(&self, group: &str, a: &[String]) {
        match group {
            "ping" => {
                self.call("core.ping", json!({}), 40.0, &[]);
                println!("pong");
            }
            "memory" if a.is_empty() => pretty(&self.call("app.memory", json!({}), 40.0, &[])),
            "memory" => self.project_memory(a),
            "session" if first(a) == Some("snapshot") => {
                pretty(&self.call("session.snapshot", json!({}), 40.0, &[])["panes"].take_or_array())
            }
            "events" => self.events(a),
            "layout" => self.layout(a),
            "wait" => self.wait(a),
            "worktree" => self.worktree(a),
            "habit" => self.habit(a),
            "task-source" => self.task_source(a),
            "schedule" => {
                let sub = first(a).unwrap_or("list");
                let rest = a.get(1..).unwrap_or_default();
                let method = match sub { "add" => "schedule.add", "list" => "schedule.list", "remove" => "schedule.remove", "run-now" => "schedule.run_now", _ => die("usage: seahelm schedule add|list|remove|run-now", 2) };
                let params = if sub == "add" {
                    json!({"name": rest.first(), "cron": opt(rest, "--cron"), "brief": opt(rest, "--brief"), "enabled": !has(rest, "--disabled"), "budget": {"max_minutes": opt(rest, "--max-minutes").and_then(|v| v.parse::<u32>().ok()).unwrap_or(30), "pause_above_usage": opt(rest, "--pause-above-usage").and_then(|v| v.parse::<f64>().ok()).unwrap_or(80.0)}})
                } else { json!({"name": rest.first()}) };
                pretty(&self.call(method, params, 180.0, &[]));
            }
            "pane" => self.pane(a),
            other => die(&format!("unknown command: {other}"), 2),
        }
    }

    fn project_memory(&self, a: &[String]) {
        let Some((verb, rest)) = a.split_first() else { unreachable!() };
        let Some(repo) = rest.first() else { die("usage: seahelm memory note|show|undo|confirm <repo> [text|digest]", 2) };
        let mut params = json!({"repo": absolute(repo)});
        match verb.as_str() {
            "show" | "undo" if rest.len() == 1 => {}
            "note" if rest.len() > 1 => params["text"] = json!(rest[1..].join(" ")),
            "confirm" if rest.len() == 2 => params["digest"] = json!(rest[1]),
            _ => die("usage: seahelm memory note|show|undo|confirm <repo> [text|digest]", 2),
        }
        pretty(&self.call(&format!("memory.{verb}"), params, 40.0, &[]));
    }

    fn layout(&self, a: &[String]) {
        match first(a) {
            Some("export") => pretty(&self.call("layout.export", json!({}), 40.0, &[])),
            Some("apply") => {
                let raw = match a.get(1).map(String::as_str) {
                    None | Some("-") => read_stdin(),
                    Some(path) => std::fs::read_to_string(path).unwrap_or_else(|e| die(&format!("{path}: {e}"), 2)),
                };
                let doc: Value = serde_json::from_str(&raw).unwrap_or_else(|_| die("invalid layout JSON", 2));
                let root = doc.get("root").cloned().unwrap_or(doc);
                self.call("layout.apply", json!({"root": root}), 40.0, &[]);
            }
            Some(other) => die(&format!("unknown layout subcommand: {other}"), 2),
            None => die("usage: seahelm layout <export|apply [file|-]>", 2),
        }
    }

    fn wait(&self, a: &[String]) {
        let Some((sub, rest)) = a.split_first() else { die("usage: seahelm wait <output|agent-status> <pane> ...", 2) };
        let Some(pane) = rest.first() else { die("pane id required", 2) };
        let tmo: u64 = opt(rest, "--timeout").map(|t| int(&t)).unwrap_or(30000);
        let secs = tmo as f64 / 1000.0 + 10.0;
        let r = match sub.as_str() {
            "output" => {
                let m = opt(rest, "--match").unwrap_or_else(|| die("--match required", 2));
                let source = opt(rest, "--source").unwrap_or_else(|| "recent".into());
                self.call(
                    "wait.output",
                    json!({"pane_id": pane, "match": m, "timeout_ms": tmo, "source": source, "regex": has(rest, "--regex")}),
                    secs,
                    &[],
                )
            }
            "agent-status" => {
                let st = opt(rest, "--status").unwrap_or_else(|| die("--status required", 2));
                self.call("wait.agent_status", json!({"pane_id": pane, "status": st, "timeout_ms": tmo}), secs, &[])
            }
            other => die(&format!("unknown wait: {other}"), 2),
        };
        exit(if r["matched"].as_bool() == Some(true) { 0 } else { 1 });
    }

    fn worktree(&self, a: &[String]) {
        let Some((sub, rest)) = a.split_first() else { die("usage: seahelm worktree <create|delete> ...", 2) };
        match sub.as_str() {
            "create" => {
                let (Some(repo), Some(task)) = (opt(rest, "--repo"), opt(rest, "--task")) else {
                    die("usage: seahelm worktree create --repo <path> --task <text> [--agent claudeCode]", 2)
                };
                let agent = opt(rest, "--agent").unwrap_or_else(|| "claudeCode".into());
                pretty(&self.call(
                    "worktree.create",
                    json!({"repo_path": absolute(&repo), "prompt": task, "agent_type": agent}),
                    120.0,
                    &[],
                ));
            }
            "delete" => {
                let Some(path) = rest.first() else { die("usage: seahelm worktree delete <worktree-path>", 2) };
                let mut params = json!({"worktree_path": absolute(path)});
                if let Some(habit) = opt(rest, "--habit") { params["habit"] = json!(habit); }
                pretty(&self.call("worktree.delete", params, 40.0, &[]));
            }
            other => die(&format!("unknown worktree subcommand: {other}"), 2),
        }
    }

    /// First Mate's habits: `seahelm habit list [--repo <path>] [--json]`
    /// (read-only), and `seahelm habit inventory [--preview] [--json]` — take
    /// the inventory again (one card per group; `--preview` only shows the groups).
    fn task_source(&self, a: &[String]) {
        let sub = first(a).unwrap_or("");
        if !["add", "list", "remove", "test"].contains(&sub) { die("usage: seahelm task-source <add|list|remove|test> --repo PATH [--id ID] [--json SOURCE]; add reads credential JSON from stdin for Jira", 2); }
        let repo = opt(a, "--repo").map(|r| absolute(&r)).unwrap_or_default();
        let mut params = json!({"repo":repo,"id":opt(a,"--id")});
        if sub == "add" {
            let raw=opt(a,"--json").unwrap_or_else(||die("--json SOURCE required",2));
            params=task_source_params(&raw,&repo,||{
                use std::io::Read;
                let mut text=String::new();std::io::stdin().read_to_string(&mut text).map_err(|_|"cannot read credential JSON".to_string())?;Ok(text)
            }).unwrap_or_else(|e|die(&e,2));
        }
        pretty(&self.call(&format!("task-source.{sub}"),params,120.0,&[]));
    }

    fn habit(&self, a: &[String]) {
        match first(a) {
            Some("list") => {
                let rest = &a[1..];
                let params = opt(rest, "--repo").map(|r| json!({"repo": absolute(&r)})).unwrap_or_else(|| json!({}));
                let v = self.call("habits.list", params, 40.0, &[]);
                if has(rest, "--json") {
                    pretty(&v);
                } else {
                    print!("{}", habit_table(&v));
                }
            }
            Some("propose") => {
                let raw = opt(&a[1..], "--json").unwrap_or_else(|| die("habit propose --json <habit>", 2));
                let habit: Value = serde_json::from_str(&raw).unwrap_or_else(|_| die("invalid habit JSON", 2));
                pretty(&self.call("habits.propose", json!({"habit": habit}), 40.0, &[]));
            }
            Some("inventory") => {
                let rest = &a[1..];
                let preview = has(rest, "--preview");
                // Measuring every worktree runs git in each: give it time.
                let v = self.call("habits.inventory", json!({"preview": preview}), 180.0, &[]);
                if has(rest, "--json") {
                    pretty(&v);
                } else if preview {
                    print!("{}", inventory_table(&v));
                } else {
                    println!("{}", v["message"].as_str().unwrap_or("Started."));
                }
            }
            Some(other) => die(&format!("unknown habit subcommand: {other}"), 2),
            None => die("usage: seahelm habit <list [--repo <path>] [--json] | inventory [--preview] [--json]>", 2),
        }
    }

    fn pane(&self, a: &[String]) {
        let Some((sub, rest)) = a.split_first() else {
            die("usage: seahelm pane <list|read|run|exec|send-text|send-keys|split|close|focus|move|fork|explain|zoom|options|sleep|wake> ...", 2)
        };
        let need = |n: usize, usage: &str| {
            if rest.len() < n {
                die(usage, 2);
            }
        };
        match sub.as_str() {
            "list" => pretty(&self.call("pane.list", json!({}), 40.0, &[])["panes"].take_or_array()),
            "read" => {
                need(1, "pane id required");
                let source = opt(rest, "--source").unwrap_or_else(|| "visible".into());
                let lines = opt(rest, "--lines").map(|l| int(&l)).unwrap_or(100);
                let r = self.call("pane.read", json!({"pane_id": rest[0], "source": source, "lines": lines}), 40.0, &[]);
                print!("{}", r["text"].as_str().unwrap_or(""));
            }
            "run" => {
                need(2, "usage: seahelm pane run <pane> <command...>");
                self.call("pane.run", json!({"pane_id": rest[0], "command": rest[1..].join(" ")}), 40.0, &[]);
            }
            "exec" => {
                // Runs only at an empty zsh prompt; exits with the command's code.
                let usage = "usage: seahelm pane exec <pane> [--timeout MS] <command...>";
                need(2, usage);
                let (pane, mut cmd, mut tmo) = (&rest[0], &rest[1..], 30000u64);
                if cmd.first().map(String::as_str) == Some("--timeout") {
                    if cmd.len() < 3 {
                        die(usage, 2);
                    }
                    tmo = int(&cmd[1]);
                    cmd = &cmd[2..];
                }
                let r = self.call(
                    "pane.exec",
                    json!({"pane_id": pane, "command": cmd.join(" "), "timeout_ms": tmo}),
                    tmo as f64 / 1000.0 + 15.0,
                    &[(-32024, 124)],
                );
                let out = r["output"].as_str().unwrap_or("");
                if !out.is_empty() {
                    if out.ends_with('\n') { print!("{out}") } else { println!("{out}") }
                }
                exit(r["exit_code"].as_i64().map(|c| c as i32).unwrap_or(1));
            }
            "send-text" => {
                need(2, "usage: seahelm pane send-text <pane> <text...>");
                self.call("pane.send_text", json!({"pane_id": rest[0], "text": rest[1..].join(" ")}), 40.0, &[]);
            }
            "send-keys" => {
                need(2, "usage: seahelm pane send-keys <pane> <key...>");
                self.call("pane.send_keys", json!({"pane_id": rest[0], "keys": rest[1..]}), 40.0, &[]);
            }
            "close" | "focus" => {
                need(1, &format!("usage: seahelm pane {sub} <pane>"));
                self.call(&format!("pane.{sub}"), json!({"pane_id": rest[0]}), 40.0, &[]);
            }
            "move" => {
                need(2, "usage: seahelm pane move <pane> <worktree-path>");
                compact(&self.call("pane.move", json!({"pane_id": rest[0], "worktree_path": rest[1]}), 40.0, &[]));
            }
            "fork" => {
                need(1, "usage: seahelm pane fork <pane> [worktree-path]");
                let mut p = json!({"pane_id": rest[0]});
                if let Some(wt) = rest.get(1) {
                    p["worktree_path"] = json!(wt);
                }
                compact(&self.call("pane.fork", p, 40.0, &[]));
            }
            "sleep" | "wake" => {
                let pane = rest.first().filter(|p| !p.starts_with("--"));
                if pane.is_none() && !has(rest, "--all") {
                    die(&format!("usage: seahelm pane {sub} <pane>|--all"), 2);
                }
                let p = pane.map(|p| json!({"pane_id": p})).unwrap_or_else(|| json!({"all": true}));
                compact(&self.call(&format!("pane.{sub}"), p, 40.0, &[]));
            }
            "rename" => {
                need(1, "usage: seahelm pane rename <pane> [title...]   (no title: back to its own)");
                compact(&self.call("pane.rename", json!({"pane_id": rest[0], "title": rest[1..].join(" ")}), 40.0, &[]));
            }
            "explain" => {
                need(1, "usage: seahelm pane explain <pane>");
                pretty(&self.call("pane.explain", json!({"pane_id": rest[0]}), 40.0, &[]));
            }
            "options" => {
                need(1, "usage: seahelm pane options <pane>");
                pretty(&self.call("pane.options", json!({"pane_id": rest[0]}), 40.0, &[])["options"].take_or_array());
            }
            "zoom" => {
                let pane = rest.first().filter(|p| !p.starts_with("--"));
                let mode = if has(rest, "--on") { "on" } else if has(rest, "--off") { "off" } else { "toggle" };
                let mut p = json!({"mode": mode});
                if let Some(pane) = pane {
                    p["pane_id"] = json!(pane);
                }
                compact(&self.call("pane.zoom", p, 40.0, &[]));
            }
            "split" => {
                let pane = rest.first().filter(|p| !p.starts_with("--"));
                let direction = opt(rest, "--direction").unwrap_or_else(|| "right".into());
                let mut p = json!({"direction": direction, "focus": !has(rest, "--no-focus")});
                if let Some(pane) = pane {
                    p["pane_id"] = json!(pane);
                }
                println!("{}", self.call("pane.split", p, 40.0, &[])["pane_id"].as_str().unwrap_or(""));
            }
            other => die(&format!("unknown pane subcommand: {other}"), 2),
        }
    }

    /// `seahelm events [--after N] [--pane P] [--type T ...]`: every event, one
    /// line each, until interrupted.
    fn events(&self, a: &[String]) {
        let mut params = Map::new();
        if let Some(after) = opt(a, "--after") {
            params.insert("events_after".into(), json!(int(&after)));
        }
        if let Some(pane) = opt(a, "--pane") {
            params.insert("pane_id".into(), json!(pane));
        }
        let types: Vec<&String> = a.windows(2).filter(|w| w[0] == "--type").map(|w| &w[1]).collect();
        if !types.is_empty() {
            params.insert("types".into(), json!(types));
        }
        // The core's events; the app relays the same ones, seq and all.
        let (mut stream, side) = [Side::Core, Side::App]
            .into_iter()
            .filter(|side| *side == Side::App || core_speaks_cli())
            .find_map(|side| connect(side, None).ok().map(|s| (s, side)))
            .unwrap_or_else(|| die("socket error: neither seahelm-core nor the app answers (is seahelm running?)", 2));
        send(&mut stream, side.method("events.subscribe"), Value::Object(params))
            .unwrap_or_else(|e| die(&format!("socket error: {e}"), 2));
        use std::io::{BufRead, BufReader, Write};
        let mut out = std::io::stdout();
        for line in BufReader::new(stream).lines() {
            let Ok(line) = line else { break };
            let line = line.trim();
            if !line.is_empty() {
                let _ = writeln!(out, "{line}");
                let _ = out.flush();
            }
        }
    }

    /// One request, one reply line: the `result`, or exit on an `error`
    /// (with the code `exit_codes` maps its RPC code to, else 2). Sent to
    /// each side `route` names in turn while one cannot be reached or does
    /// not know the pane; never again once a side took it.
    fn call(&self, method: &str, mut params: Value, timeout: f64, exit_codes: &[(i64, i32)]) -> Value {
        if let Ok(me) = std::env::var("SEAHELM_PANE_ID") {
            if !me.is_empty() {
                let mut meta = json!({"caller": me});
                if let Some(n) = &self.note {
                    meta["note"] = json!(n);
                }
                params["_meta"] = meta;
            }
        }
        let sides = route(method);
        let mut unreachable = Vec::new();
        // A core from before this CLI (still running after an update) does
        // not speak its dialect: leave it out.
        let too_old = sides.contains(&Side::App) && sides.contains(&Side::Core) && !core_speaks_cli();
        let mut not_found: Option<Value> = None;
        for (i, side) in sides.iter().enumerate() {
            if *side == Side::Core && too_old {
                unreachable.push("seahelm-core: older than this CLI".to_string());
                continue;
            }
            let line = match request(*side, side.method(method), &params, timeout) {
                Ok(line) => line,
                Err(Sent::Unreachable(e)) => {
                    unreachable.push(format!("{}: {e}", side.name()));
                    continue;
                }
                Err(Sent::Failed(e)) => die(&format!("socket error: {e} ({})", side.name()), 2),
            };
            let obj: Value = serde_json::from_str(&line).unwrap_or_else(|_| die("bad response", 2));
            if let Some(err) = obj.get("error") {
                let code = err["code"].as_i64().unwrap_or(0);
                if code == PANE_NOT_FOUND && i + 1 < sides.len() {
                    not_found.get_or_insert_with(|| err.clone());
                    continue;
                }
                let exit_code = exit_codes.iter().find(|(c, _)| *c == code).map(|(_, e)| *e).unwrap_or(2);
                die(err["message"].as_str().unwrap_or("error"), exit_code);
            }
            return obj.get("result").cloned().unwrap_or_else(|| json!({}));
        }
        if let Some(err) = not_found {
            die(err["message"].as_str().unwrap_or("pane not found"), 2);
        }
        if sides == [Side::App] {
            die(&format!("{method} needs the Seahelm app, which is not answering ({})", unreachable.join("; ")), 2);
        }
        die(&format!("socket error: {} (is seahelm running?)", unreachable.join("; ")), 2)
    }
}

/// What this CLI needs of the core (`core.ping`'s `cli`).
const CLI_DIALECT: u64 = 1;

/// Whether the core answers and speaks this CLI's dialect. Unreachable is
/// "no": the caller then finds out about the app on its own.
fn core_speaks_cli() -> bool {
    let Ok(line) = request(Side::Core, "core.ping", &json!({}), 5.0) else { return false };
    serde_json::from_str::<Value>(&line)
        .ok()
        .and_then(|v| v.pointer("/result/cli").and_then(Value::as_u64))
        .is_some_and(|d| d >= CLI_DIALECT)
}

/// The app's (and the core's) "no such pane": the core has not heard of a
/// pane the app split a moment ago, so the app is asked next.
const PANE_NOT_FOUND: i64 = -32004;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Side {
    Core,
    App,
}

impl Side {
    fn name(self) -> &'static str {
        match self {
            Side::Core => "seahelm-core",
            Side::App => "the app",
        }
    }

    /// The method's name on this side: the only one that differs is ping.
    fn method(self, method: &str) -> &str {
        match (self, method) {
            (Side::App, "core.ping") => "ping",
            _ => method,
        }
    }
}

/// Who answers a method, in the order asked. Business verbs are the
/// core's; worktrees and closing a pane are the app's while it runs (it
/// asks before losing work and tidies its layout); the rest is the
/// interface's, which only the app draws.
fn route(method: &str) -> &'static [Side] {
    match method {
        "core.ping" | "session.snapshot" | "pane.list" | "pane.read" | "pane.run" | "pane.send_text"
        | "pane.send_keys" | "pane.explain" | "wait.output" | "wait.agent_status" | "events.subscribe" => {
            &[Side::Core, Side::App]
        }
        "worktree.create" | "worktree.delete" | "pane.close" => &[Side::App, Side::Core],
        // First Mate's habits live in the core alone.
        "task-source.add" | "task-source.list" | "task-source.remove" | "task-source.test" | "schedule.add" | "schedule.list" | "schedule.remove" | "schedule.run_now" | "habits.list" | "habits.inventory" | "habits.propose" => &[Side::Core],
        "memory.note" | "memory.show" | "memory.undo" | "memory.confirm" => &[Side::Core],
        "pane.rename" => &[Side::Core],
        _ => &[Side::App],
    }
}

// MARK: - the sockets

fn home() -> std::path::PathBuf {
    std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")).map(Into::into).unwrap_or_default()
}

fn env_path(name: &str) -> Option<std::path::PathBuf> {
    std::env::var_os(name).filter(|p| !p.is_empty()).map(Into::into)
}

fn socket_path(side: Side) -> std::path::PathBuf {
    match side {
        Side::App => env_path("SEAHELM_SOCKET_PATH").unwrap_or_else(|| home().join(".config/seahelm/seahelm.sock")),
        Side::Core => env_path("SEAHELM_CORE_SOCKET").unwrap_or_else(|| {
            if cfg!(windows) {
                let user = std::env::var("USERNAME").ok().filter(|u| !u.is_empty()).unwrap_or_else(|| "default".into());
                format!(r"\\.\pipe\seahelm-core-{user}").into()
            } else {
                home().join(".config/seahelm/core.sock")
            }
        }),
    }
}

trait Conn: std::io::Read + std::io::Write {}
impl<T: std::io::Read + std::io::Write> Conn for T {}

#[cfg(unix)]
fn connect(side: Side, timeout: Option<f64>) -> std::io::Result<Box<dyn Conn>> {
    let s = std::os::unix::net::UnixStream::connect(socket_path(side))?;
    if let Some(t) = timeout {
        let d = Some(std::time::Duration::from_secs_f64(t));
        s.set_read_timeout(d)?;
        s.set_write_timeout(d)?;
    }
    Ok(Box::new(s))
}

/// The core's named pipe opens like a file. The app is macOS only.
#[cfg(not(unix))]
fn connect(side: Side, _timeout: Option<f64>) -> std::io::Result<Box<dyn Conn>> {
    if side == Side::App {
        return Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "the macOS app's control socket is Unix-only"));
    }
    Ok(Box::new(std::fs::OpenOptions::new().read(true).write(true).open(socket_path(side))?))
}

fn send(stream: &mut Box<dyn Conn>, method: &str, params: Value) -> std::io::Result<()> {
    let mut line = serde_json::to_vec(&json!({"id": "cli", "method": method, "params": params}))?;
    line.push(b'\n');
    stream.write_all(&line)?;
    stream.flush()
}

/// How far a request got.
enum Sent {
    /// Nobody to send it to: safe to ask the other side.
    Unreachable(std::io::Error),
    /// Sent, then no reply: it may have run, so it is not sent again.
    Failed(std::io::Error),
}

fn request(side: Side, method: &str, params: &Value, timeout: f64) -> Result<String, Sent> {
    use std::io::{BufRead, BufReader};
    let mut stream = connect(side, Some(timeout)).map_err(Sent::Unreachable)?;
    send(&mut stream, method, params.clone()).map_err(Sent::Failed)?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).map_err(Sent::Failed)?;
    if line.trim().is_empty() {
        return Err(Sent::Failed(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "no reply")));
    }
    Ok(line)
}

// MARK: - arguments and output

/// `habits.inventory --preview` for a person: one block per group.
fn inventory_table(v: &Value) -> String {
    let groups = v["groups"].as_array().cloned().unwrap_or_default();
    let mut out = format!("measured {} worktree(s)\n", v["measured"].as_u64().unwrap_or(0));
    if groups.is_empty() {
        out += "nothing looks finished: no card would be raised\n";
    }
    for g in groups {
        let ws = g["worktrees"].as_array().cloned().unwrap_or_default();
        let opts: Vec<&str> = g["options"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
        out += &format!("{} · {}  [{}]\n", g["title"].as_str().unwrap_or("?"), ws.len(), opts.join(" / "));
        for w in ws {
            out += &format!("  {} — {}\n", w["path"].as_str().unwrap_or("?"), w["facts"].as_str().unwrap_or(""));
        }
    }
    out
}

/// `habits.list` for a person: one block per file, one line per habit.
fn habit_table(v: &Value) -> String {
    let mut out = String::new();
    for b in v["books"].as_array().into_iter().flatten() {
        let title = b["repo"].as_str().map(str::to_string).unwrap_or_else(|| b["key"].as_str().unwrap_or("?").to_string());
        out += &format!("{title}  ({})\n", b["file"].as_str().unwrap_or_default());
        let habits = b["habits"].as_array().cloned().unwrap_or_default();
        if habits.is_empty() {
            out += "  (no habits)\n";
        }
        for h in habits {
            let level = h["effective_level"].as_str().or(h["level"].as_str()).unwrap_or("?");
            let e = &h["evidence"];
            let when: Vec<String> = h["when"].as_object().map(|m| m.iter().map(|(k, v)| format!("{k}: {}", v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string()))).collect()).unwrap_or_default();
            out += &format!(
                "  {:<8} {}  {} — {} [{}]  approved {} · rejected {} · manual {} · ignored {}\n",
                level,
                h["id"].as_str().unwrap_or("?"),
                h["do"].as_str().unwrap_or("?"),
                when.join(", "),
                h["status"].as_str().unwrap_or("active"),
                e["approved"], e["rejected"], e["manual"], e["ignored"],
            );
        }
        for n in b["notes"].as_array().into_iter().flatten().chain(b["invalid"].as_array().into_iter().flatten()) {
            out += &format!("  ! {}\n", n.as_str().unwrap_or_default());
        }
    }
    out
}

fn first(a: &[String]) -> Option<&str> {
    a.first().map(String::as_str)
}

fn has(a: &[String], name: &str) -> bool {
    a.iter().any(|x| x == name)
}

/// The value after `name`, if both are there.
fn opt(a: &[String], name: &str) -> Option<String> {
    let i = a.iter().position(|x| x == name)?;
    a.get(i + 1).cloned()
}

fn int(s: &str) -> u64 {
    s.parse().unwrap_or_else(|_| die(&format!("not a number: {s}"), 2))
}

fn absolute(path: &str) -> String {
    let expanded = match path.strip_prefix("~/") {
        Some(rest) => std::path::PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(rest),
        None => std::path::PathBuf::from(path),
    };
    let abs = if expanded.is_absolute() {
        expanded
    } else {
        std::env::current_dir().unwrap_or_default().join(expanded)
    };
    abs.to_string_lossy().into_owned()
}

fn read_stdin() -> String {
    use std::io::Read;
    let mut s = String::new();
    let _ = std::io::stdin().read_to_string(&mut s);
    s
}

fn pretty(v: &Value) {
    println!("{}", serde_json::to_string_pretty(v).unwrap_or_default());
}

fn compact(v: &Value) {
    println!("{}", serde_json::to_string(v).unwrap_or_default());
}

fn die(msg: &str, code: i32) -> ! {
    eprintln!("seahelm: {msg}");
    exit(code)
}

trait TakeOrArray {
    fn take_or_array(&mut self) -> Value;
}

impl TakeOrArray for Value {
    /// The field's value, or `[]` when the reply had none (as the Python
    /// `.get(key, [])` did).
    fn take_or_array(&mut self) -> Value {
        match self.take() {
            Value::Null => json!([]),
            v => v,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_source_validates_kind_before_reading_stdin(){
        for raw in ["{}",r#"{"kind":"unknown"}"#,"null"]{assert!(task_source_params(raw,"repo",||panic!("must not read stdin")).is_err());}
        assert!(task_source_params(r#"{"kind":"github"}"#,"repo",||panic!("GitHub needs no credential")).is_ok());
        assert!(task_source_params(r#"{"kind":"jira-cloud"}"#,"repo",||Ok(r#"{"token":"fake"}"#.into())).is_ok());
    }

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn options_read_the_value_after_their_name() {
        let a = s(&["#3", "--lines", "20", "--regex"]);
        assert_eq!(opt(&a, "--lines").as_deref(), Some("20"));
        assert_eq!(opt(&a, "--regex"), None);
        assert!(has(&a, "--regex"));
        assert_eq!(opt(&a, "--missing"), None);
    }

    #[test]
    fn business_verbs_go_to_the_core_first() {
        for m in ["pane.list", "pane.read", "pane.run", "pane.send_keys", "wait.output", "wait.agent_status", "events.subscribe"] {
            assert_eq!(route(m), [Side::Core, Side::App], "{m}");
        }
        for m in ["worktree.create", "worktree.delete", "pane.close"] {
            assert_eq!(route(m), [Side::App, Side::Core], "{m}");
        }
        assert_eq!(route("habits.list"), [Side::Core], "habits live in the core alone");
        assert_eq!(route("habits.inventory"), [Side::Core]);
        for method in ["memory.note", "memory.show", "memory.undo", "memory.confirm"] { assert_eq!(route(method), [Side::Core]); }

        for method in ["schedule.add", "schedule.list", "schedule.remove", "schedule.run_now"] { assert_eq!(route(method), [Side::Core]); }
        // Only the side drawing the panes can do these.
        for m in ["pane.split", "pane.focus", "pane.zoom", "pane.move", "pane.fork", "pane.exec", "layout.apply"] {
            assert_eq!(route(m), [Side::App], "{m}");
        }
    }

    #[test]
    fn habits_read_as_a_table() {
        let v = json!({"books": [{"key": "_global", "repo": null, "file": "/h/_global.yml", "notes": [], "invalid": ["habit 2: bad"],
            "habits": [{"id": "delete-merged-clean", "do": "delete_worktree", "level": "ask", "status": "active",
                        "when": {"pr": "merged", "idle_days": ">=1"}, "evidence": {"approved": 2, "rejected": 0, "manual": 3, "ignored": 0}}]}]});
        let t = habit_table(&v);
        assert!(t.starts_with("_global  (/h/_global.yml)\n"), "{t}");
        assert!(t.contains("ask      delete-merged-clean  delete_worktree — pr: merged, idle_days: >=1 [active]  approved 2 · rejected 0 · manual 3"), "{t}");
        assert!(t.contains("! habit 2: bad"));
    }

    #[test]
    fn ping_is_named_per_side() {
        assert_eq!(Side::Core.method("core.ping"), "core.ping");
        assert_eq!(Side::App.method("core.ping"), "ping");
        assert_eq!(Side::App.method("pane.read"), "pane.read");
    }

    // The paths below are Unix paths.
    #[cfg(unix)]
    #[test]
    fn paths_are_made_absolute() {
        assert!(absolute("rel/x").ends_with("/rel/x"));
        assert!(absolute("rel/x").starts_with('/'));
        assert_eq!(absolute("/abs"), "/abs");
    }
}
