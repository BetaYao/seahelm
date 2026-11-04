//! The hook bridge: what an agent's hook command does, in one place for
//! both of its names — `seahelm-hook [<source>]` (the binary the macOS app
//! copies into `~/.local/bin`) and `seahelm-core hook [<source>]` (what
//! `seahelm-core install-hooks` wires on machines without the app).
//!
//! It reads a hook payload on stdin, tags it with the pane it ran in and the
//! agent that invoked it, and sends it to seahelm-core as one JSON-RPC line:
//!
//! ```text
//! {"jsonrpc":"2.0","id":"h","method":"hook","params":{"seahelm_pane_id":…,"seahelm_source":…,…}}
//! ```
//!
//! The source is *declared* by whoever wired the hook (`seahelm-hook
//! claude-code`) rather than sniffed from the payload, because Claude
//! Code's payloads now carry the very keys that used to read as Codex-only.
//!
//! The core's answer may carry `stdout`: text the agent should read back
//! from its hook (Claude Code, Codex and Cursor take a SessionStart hook's
//! stdout as added context). That is the only thing the bridge ever prints;
//! anything else — no core, a silent one, a payload it cannot read — ends in
//! exit 0 with nothing on stdout, because a hook's stdout is read as a
//! decision and Stop is observation-only.

use std::io::Read;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::Map;

/// The env var naming the core's socket (or, on Windows, its named pipe).
pub const SOCKET_ENV: &str = "SEAHELM_CORE_SOCKET";

/// How long the bridge may spend on one event before it gives up.
pub const TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);

/// Where seahelm-core listens when `SEAHELM_CORE_SOCKET` is unset:
/// `~/.config/seahelm/core.sock`, or on Windows the per-user pipe
/// `\\.\pipe\seahelm-core-<user>` (pipe names are machine-wide, so the user
/// name keeps two accounts apart).
pub fn default_socket_path(home: &Path, user: Option<&str>) -> PathBuf {
    if cfg!(windows) {
        let user = user.filter(|u| !u.is_empty()).unwrap_or("default");
        PathBuf::from(format!(r"\\.\pipe\seahelm-core-{user}"))
    } else {
        home.join(".config").join("seahelm").join("core.sock")
    }
}

/// The socket the bridge sends to, from its environment.
pub fn socket_path_from_env() -> PathBuf {
    match std::env::var_os(SOCKET_ENV).filter(|p| !p.is_empty()) {
        Some(p) => PathBuf::from(p),
        None => default_socket_path(&crate::home_dir(), std::env::var("USERNAME").ok().as_deref()),
    }
}

/// The whole bridge: stdin to the core at `socket`, the core's `stdout` (if
/// any) to ours. Never panics out, never blocks past [`TIMEOUT`]: a
/// watchdog ends the process whatever is stuck.
pub fn run(socket: &Path, source: Option<&str>) {
    std::thread::spawn(|| {
        std::thread::sleep(TIMEOUT);
        std::process::exit(0);
    });
    let socket = socket.to_path_buf();
    let source = source.map(str::to_string);
    let out = std::panic::catch_unwind(move || deliver(&socket, source.as_deref())).ok().flatten();
    if let Some(out) = out {
        use std::io::Write;
        let mut stdout = std::io::stdout();
        let _ = stdout.write_all(out.as_bytes());
        let _ = stdout.flush();
    }
}

fn deliver(socket: &Path, source: Option<&str>) -> Option<String> {
    let mut payload = Vec::new();
    std::io::stdin().read_to_end(&mut payload).ok()?;
    let payload = String::from_utf8_lossy(&payload);
    let pane = pane_id(std::env::var("SEAHELM_PANE_ID").ok().as_deref(), std::env::var("SEAHELMD_SESSION").ok().as_deref());
    let params = splice(&payload, pane.as_deref(), source)?;
    let reply = exchange(socket, request_line(params).as_bytes()).ok()?;
    agent_output(&reply)
}

/// The text the core asks the bridge to print, from its reply line.
pub fn agent_output(reply: &str) -> Option<String> {
    let v: Value = serde_json::from_str(reply.trim()).ok()?;
    let s = v.get("result")?.get("stdout")?.as_str()?;
    (!s.is_empty()).then(|| s.to_string())
}

/// Write the line, close our half, and read the server's one-line answer.
#[cfg(unix)]
fn exchange(path: &Path, line: &[u8]) -> std::io::Result<String> {
    use std::io::Write;
    use std::os::unix::net::UnixStream;
    let mut stream = UnixStream::connect(path)?;
    stream.set_write_timeout(Some(TIMEOUT))?;
    stream.set_read_timeout(Some(TIMEOUT))?;
    stream.write_all(line)?;
    stream.shutdown(std::net::Shutdown::Write)?;
    Ok(read_answer(&mut stream))
}

/// A named pipe opens like a file. A pipe has no half-close to tell the
/// server we are done, so read until its one-line answer (or its close, or
/// the watchdog) and then drop the handle.
#[cfg(windows)]
fn exchange(path: &Path, line: &[u8]) -> std::io::Result<String> {
    use std::io::Write;
    let mut pipe = std::fs::OpenOptions::new().read(true).write(true).open(path)?;
    pipe.write_all(line)?;
    pipe.flush()?;
    Ok(read_answer(&mut pipe))
}

#[cfg(not(any(unix, windows)))]
fn exchange(_path: &Path, _line: &[u8]) -> std::io::Result<String> {
    Ok(String::new())
}

/// Read until the server's one-line answer, its close, or an error.
#[cfg(any(unix, windows))]
fn read_answer(conn: &mut impl Read) -> String {
    let mut got = Vec::new();
    let mut buf = [0u8; 4096];
    while let Ok(n) = conn.read(&mut buf) {
        if n == 0 {
            break;
        }
        got.extend_from_slice(&buf[..n]);
        if buf[..n].contains(&b'\n') {
            break;
        }
    }
    String::from_utf8_lossy(&got).into_owned()
}

/// The pane a hook ran in: `SEAHELM_PANE_ID`, else `SEAHELMD_SESSION`
/// (the same value, kept by panes that predate the first export).
pub fn pane_id(seahelm_pane_id: Option<&str>, seahelmd_session: Option<&str>) -> Option<String> {
    seahelm_pane_id.filter(|s| !s.is_empty()).or(seahelmd_session.filter(|s| !s.is_empty())).map(str::to_string)
}

/// `payload` with `seahelm_pane_id` and `seahelm_source` put first; either
/// is left out when unknown or empty, never sent empty. A key the payload
/// already carries keeps the payload's value (the plugins send their own
/// pane id). None when the payload is not a JSON object: there is nothing
/// useful to forward.
pub fn splice(payload: &str, pane: Option<&str>, source: Option<&str>) -> Option<Map> {
    let Ok(Value::Object(body)) = serde_json::from_str::<Value>(payload.trim()) else { return None };
    let mut out = Map::new();
    if let Some(pane) = pane.filter(|p| !p.is_empty()) {
        out.insert("seahelm_pane_id".into(), pane.into());
    }
    if let Some(source) = source.filter(|s| !s.is_empty()) {
        out.insert("seahelm_source".into(), source.into());
    }
    for (k, v) in body {
        out.insert(k, v);
    }
    Some(out)
}

/// The request line for `params`, newline-terminated. Compact JSON, so a
/// pretty-printed payload cannot break the newline-delimited protocol.
pub fn request_line(params: Map) -> String {
    let req = serde_json::json!({"jsonrpc": "2.0", "id": "h", "method": "hook", "params": params});
    format!("{req}\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    // SeahelmHookInstallerTests, adapted: the script's shape is now this
    // splice and the request it builds.

    #[test]
    fn test_script_shape() {
        let params = splice(r#"{"hook_event_name":"Stop","session_id":"s","cwd":"/wt"}"#, Some("seahelm-repo-main"), Some("claude-code")).unwrap();
        let keys: Vec<&str> = params.keys().map(String::as_str).collect();
        assert_eq!(keys, vec!["seahelm_pane_id", "seahelm_source", "hook_event_name", "session_id", "cwd"]);
        let line = request_line(params);
        assert!(line.ends_with('\n') && line.matches('\n').count() == 1);
        assert!(line.contains(r#""method":"hook""#));
        assert!(line.contains(r#""id":"h""#));
        assert!(!line.contains("/webhook"));
    }

    #[test]
    fn untagged_calls_emit_no_empty_source() {
        let params = splice(r#"{"a":1}"#, Some("p"), None).unwrap();
        assert!(!params.contains_key("seahelm_source"));
        let params = splice(r#"{"a":1}"#, None, Some("")).unwrap();
        assert!(params.is_empty() || !params.contains_key("seahelm_pane_id"));
        assert!(!params.contains_key("seahelm_source"));
    }

    #[test]
    fn pretty_payloads_travel_as_one_line() {
        let line = request_line(splice("{\n  \"x\": \"a\\nb\"\n}\n", None, None).unwrap());
        assert_eq!(line.matches('\n').count(), 1);
    }

    #[test]
    fn non_objects_are_not_forwarded() {
        assert_eq!(splice("", Some("p"), Some("s")), None);
        assert_eq!(splice("[1]", Some("p"), Some("s")), None);
        assert_eq!(splice("not json", Some("p"), Some("s")), None);
    }

    #[test]
    fn the_pane_falls_back_to_the_seahelmd_session() {
        assert_eq!(pane_id(Some("a"), Some("b")).as_deref(), Some("a"));
        assert_eq!(pane_id(Some(""), Some("b")).as_deref(), Some("b"));
        assert_eq!(pane_id(None, None), None);
    }

    #[test]
    fn the_core_asks_for_stdout_in_its_result() {
        assert_eq!(agent_output(r#"{"jsonrpc":"2.0","id":"h","result":{"stdout":"hi"}}"#).as_deref(), Some("hi"));
        assert_eq!(agent_output(r#"{"jsonrpc":"2.0","id":"h","result":{}}"#), None);
        assert_eq!(agent_output(r#"{"jsonrpc":"2.0","id":"h","result":{"stdout":""}}"#), None);
        assert_eq!(agent_output(""), None);
    }

    #[cfg(unix)]
    #[test]
    fn the_default_socket_is_under_the_config_dir() {
        assert_eq!(default_socket_path(Path::new("/h"), None), PathBuf::from("/h/.config/seahelm/core.sock"));
    }
}
