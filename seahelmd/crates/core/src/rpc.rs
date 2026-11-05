//! The wire: newline-delimited JSON-RPC 2.0 over a local socket (a named
//! pipe on Windows, through seahelmd's `platform`), the same
//! shape the macOS app's control socket speaks (`ControlProtocol.swift`), so a
//! client that talks to one talks to the other.
//!
//! The server takes one thread per connection. A connection is a stream of
//! requests answered in order, except `events.subscribe`, which turns the
//! connection into a stream of notifications until the client goes away.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use seahelmd::platform::{Listener, Stream};
use serde_json::{json, Value};

/// A JSON-RPC error: code and message, as the app uses them.
#[derive(Debug, Clone)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

impl RpcError {
    pub fn invalid_params(message: impl Into<String>) -> Self {
        Self { code: -32602, message: message.into() }
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self { code: -32603, message: message.into() }
    }

    pub fn not_found(method: &str) -> Self {
        Self { code: -32601, message: format!("method not found: {method}") }
    }

    /// No pane by that name: the app's `ControlError.notFound`, code and
    /// wording, so the `seahelm` CLI can try the app for a pane the core has
    /// not heard of yet (one split a moment ago).
    pub fn pane_not_found(hint: &str) -> Self {
        Self { code: PANE_NOT_FOUND, message: format!("pane not found: {hint}") }
    }
}

pub const PANE_NOT_FOUND: i64 = -32004;

pub type RpcResult = std::result::Result<Value, RpcError>;

/// What a dispatcher does with one call. `Stream` hands the connection over
/// to a subscription: the function writes notifications until it fails.
pub enum Reply {
    Value(RpcResult),
    Stream(Box<dyn FnOnce(&mut dyn Write) + Send>),
}

pub trait Dispatch: Send + Sync + 'static {
    /// Takes the `Arc` so a stream can keep the dispatcher for as long as
    /// its connection lasts.
    fn call(self: std::sync::Arc<Self>, method: &str, params: Value) -> Reply;
}

/// The app's socket and ours: `~/.config/seahelm/`.
pub fn config_dir() -> PathBuf {
    let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")).unwrap_or_default();
    PathBuf::from(home).join(".config/seahelm")
}

/// The current user, for pipe names: pipes are machine-wide.
#[cfg(windows)]
fn user() -> String {
    std::env::var("USERNAME").ok().filter(|u| !u.is_empty()).unwrap_or_else(|| "default".into())
}

/// `$SEAHELM_CORE_SOCKET`, else `~/.config/seahelm/core.sock` (on Windows
/// the pipe `\\.\pipe\seahelm-core-<user>`).
pub fn core_socket() -> PathBuf {
    if let Some(p) = std::env::var_os("SEAHELM_CORE_SOCKET") {
        return PathBuf::from(p);
    }
    #[cfg(windows)]
    return PathBuf::from(format!(r"\\.\pipe\seahelm-core-{}", user()));
    #[cfg(not(windows))]
    config_dir().join("core.sock")
}


/// Serve until the listener fails. Binding is the caller's (`bind`), so it
/// can tell "already running" apart from "cannot listen".
pub fn serve(listener: Listener, dispatch: std::sync::Arc<dyn Dispatch>) -> Result<()> {
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let dispatch = std::sync::Arc::clone(&dispatch);
        std::thread::Builder::new().name("core-conn".into()).spawn(move || connection(stream, dispatch))?;
    }
    Ok(())
}

fn connection(stream: Stream, dispatch: std::sync::Arc<dyn Dispatch>) {
    let Ok(read_half) = stream.try_clone() else { return };
    let mut writer = stream;
    let reader = BufReader::new(read_half);
    for line in reader.lines() {
        let Ok(line) = line else { return };
        if line.trim().is_empty() {
            continue;
        }
        let (id, reply) = match serde_json::from_str::<Value>(&line) {
            Ok(req) => {
                let id = req.get("id").cloned().unwrap_or(Value::Null);
                let method = req.get("method").and_then(Value::as_str).unwrap_or_default().to_string();
                let params = req.get("params").cloned().unwrap_or_else(|| json!({}));
                (id, std::sync::Arc::clone(&dispatch).call(&method, params))
            }
            Err(e) => (Value::Null, Reply::Value(Err(RpcError { code: -32700, message: format!("parse error: {e}") }))),
        };
        match reply {
            Reply::Value(result) => {
                let msg = match result {
                    Ok(v) => json!({"jsonrpc": "2.0", "id": id, "result": v}),
                    Err(e) => json!({"jsonrpc": "2.0", "id": id, "error": {"code": e.code, "message": e.message}}),
                };
                if write_line(&mut writer, &msg).is_err() {
                    return;
                }
            }
            Reply::Stream(run) => {
                run(&mut writer);
                return;
            }
        }
    }
}

pub fn write_line(w: &mut dyn Write, v: &Value) -> std::io::Result<()> {
    let mut bytes = serde_json::to_vec(v).map_err(std::io::Error::other)?;
    bytes.push(b'\n');
    w.write_all(&bytes)?;
    w.flush()
}

/// Bind the socket, owner-only. Refuses when a live server already answers
/// there, so two cores never split the panes between them; a socket nobody
/// answers on is left over from a core that died, and is replaced.
pub fn bind(path: &Path) -> Result<Listener> {
    if Stream::connect(path).is_ok() {
        bail!("seahelm-core is already running at {}", path.display());
    }
    #[cfg(unix)]
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    seahelmd::platform::remove_stale(path);
    let listener = Listener::bind(path).with_context(|| format!("bind {}", path.display()))?;
    // A pipe is owner-only by its DACL; a socket by its mode.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(listener)
}

/// One call to a JSON-RPC socket (ours or the app's), with a timeout.
pub fn call(socket: &Path, method: &str, params: Value) -> Result<Value> {
    call_with_timeout(socket, method, params, Duration::from_secs(10))
}

/// `call`, waiting up to `timeout` for the answer (a wait, a worktree add).
pub fn call_with_timeout(socket: &Path, method: &str, params: Value, timeout: Duration) -> Result<Value> {
    let mut stream = Stream::connect(socket).with_context(|| format!("connect {}", socket.display()))?;
    stream.set_read_timeout(Some(timeout))?;
    write_line(&mut stream, &json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    let mut v: Value = serde_json::from_str(&line).with_context(|| format!("reply to {method}"))?;
    if let Some(err) = v.get("error") {
        bail!("{method}: {err}");
    }
    Ok(v.get_mut("result").map(Value::take).unwrap_or(Value::Null))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    struct Echo;
    impl Dispatch for Echo {
        fn call(self: Arc<Self>, method: &str, params: Value) -> Reply {
            match method {
                "echo" => Reply::Value(Ok(params)),
                "count" => Reply::Stream(Box::new(|w| {
                    for i in 0..3 {
                        let _ = write_line(w, &json!({"jsonrpc": "2.0", "method": "tick", "params": {"i": i}}));
                    }
                })),
                other => Reply::Value(Err(RpcError::not_found(other))),
            }
        }
    }

    #[test]
    fn requests_are_answered_and_streams_stream() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("t.sock");
        let listener = bind(&sock).unwrap();
        std::thread::spawn(move || serve(listener, Arc::new(Echo)));
        assert_eq!(call(&sock, "echo", json!({"a": 1})).unwrap(), json!({"a": 1}));
        assert!(call(&sock, "nope", json!({})).unwrap_err().to_string().contains("-32601"));
        assert!(bind(&sock).is_err(), "a live server is not replaced");

        let mut s = Stream::connect(&sock).unwrap();
        write_line(&mut s, &json!({"jsonrpc": "2.0", "id": 1, "method": "count"})).unwrap();
        let lines: Vec<String> = BufReader::new(s).lines().map_while(|l| l.ok()).collect();
        assert_eq!(lines.len(), 3);
    }
}
