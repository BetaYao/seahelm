//! `seahelm`: the macOS app's command line, for agents and people inside a
//! pane (the `seahelm` skill). It speaks newline-delimited JSON-RPC to the
//! app's control socket (`$SEAHELM_SOCKET_PATH`, else
//! `~/.config/seahelm/seahelm.sock`). The app installs it as
//! `~/.local/bin/seahelm` (`SeahelmCliInstaller`); it replaces the Python
//! script that used to be written there.
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
        die("usage: seahelm <ping|memory|session|pane|wait|events|layout|integration|worktree> ...", 2)
    };
    let cli = Cli { note };
    cli.run(group, rest);
}

struct Cli {
    note: Option<String>,
}

impl Cli {
    fn run(&self, group: &str, a: &[String]) {
        match group {
            "ping" => {
                self.call("ping", json!({}), 40.0, &[]);
                println!("pong");
            }
            "memory" => pretty(&self.call("app.memory", json!({}), 40.0, &[])),
            "session" if first(a) == Some("snapshot") => {
                pretty(&self.call("session.snapshot", json!({}), 40.0, &[])["panes"].take_or_array())
            }
            "events" => self.events(a),
            "integration" => {
                if let Some(sub) = first(a) {
                    if sub != "status" {
                        die(&format!("unknown integration subcommand: {sub}"), 2);
                    }
                }
                let rest = a.get(1..).unwrap_or_default();
                // The cwd's repo by default: an agent asking "did my work get
                // folded in?" is asking about the repo it is standing in.
                let path = match rest.first() {
                    Some(p) if !p.starts_with("--") => Some(p.clone()),
                    _ if has(rest, "--all") => None,
                    _ => std::env::current_dir().ok().map(|d| d.to_string_lossy().into_owned()),
                };
                let params = path.map(|p| json!({"path": p})).unwrap_or_else(|| json!({}));
                pretty(&self.call("integration.status", params, 40.0, &[])["checkouts"].take_or_array());
            }
            "layout" => self.layout(a),
            "wait" => self.wait(a),
            "worktree" => self.worktree(a),
            "pane" => self.pane(a),
            other => die(&format!("unknown command: {other}"), 2),
        }
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
                pretty(&self.call("worktree.delete", json!({"worktree_path": absolute(path)}), 40.0, &[]));
            }
            other => die(&format!("unknown worktree subcommand: {other}"), 2),
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
        let stream = connect(None).unwrap_or_else(|e| die(&format!("socket error: {e}"), 2));
        send(&stream, "events.subscribe", Value::Object(params)).unwrap_or_else(|e| die(&format!("socket error: {e}"), 2));
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
    /// (with the code `exit_codes` maps its RPC code to, else 2).
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
        let reply = request(method, params, timeout)
            .unwrap_or_else(|e| die(&format!("socket error: {e} (is seahelm running?)"), 2));
        let obj: Value = serde_json::from_str(&reply).unwrap_or_else(|_| die("bad response", 2));
        if let Some(err) = obj.get("error") {
            let code = err["code"].as_i64().unwrap_or(0);
            let exit_code = exit_codes.iter().find(|(c, _)| *c == code).map(|(_, e)| *e).unwrap_or(2);
            die(err["message"].as_str().unwrap_or("error"), exit_code);
        }
        obj.get("result").cloned().unwrap_or_else(|| json!({}))
    }
}

// MARK: - the socket

fn socket_path() -> std::path::PathBuf {
    match std::env::var("SEAHELM_SOCKET_PATH") {
        Ok(p) if !p.is_empty() => p.into(),
        _ => std::path::PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".config/seahelm/seahelm.sock"),
    }
}

#[cfg(unix)]
type Stream = std::os::unix::net::UnixStream;

#[cfg(unix)]
fn connect(timeout: Option<f64>) -> std::io::Result<Stream> {
    let s = Stream::connect(socket_path())?;
    if let Some(t) = timeout {
        let d = Some(std::time::Duration::from_secs_f64(t));
        s.set_read_timeout(d)?;
        s.set_write_timeout(d)?;
    }
    Ok(s)
}

#[cfg(not(unix))]
type Stream = std::fs::File;

#[cfg(not(unix))]
fn connect(_timeout: Option<f64>) -> std::io::Result<Stream> {
    Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "the macOS app's control socket is Unix-only"))
}

fn send(mut stream: &Stream, method: &str, params: Value) -> std::io::Result<()> {
    use std::io::Write;
    let mut line = serde_json::to_vec(&json!({"id": "cli", "method": method, "params": params}))?;
    line.push(b'\n');
    stream.write_all(&line)
}

fn request(method: &str, params: Value, timeout: f64) -> std::io::Result<String> {
    use std::io::{BufRead, BufReader};
    let stream = connect(Some(timeout))?;
    send(&stream, method, params)?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    Ok(line)
}

// MARK: - arguments and output

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
    fn paths_are_made_absolute() {
        assert!(absolute("rel/x").ends_with("/rel/x"));
        assert!(absolute("rel/x").starts_with('/'));
        assert_eq!(absolute("/abs"), "/abs");
    }
}
