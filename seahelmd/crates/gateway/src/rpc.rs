//! Newline-delimited JSON-RPC over a local socket (a named pipe on Windows):
//! the client the gateway talks to seahelm-core with, and the server half
//! `gateway.sock` runs on. Blocking; async callers wrap it in
//! `spawn_blocking`.

use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use seahelmd::platform::{Listener, Stream};
use serde_json::{json, Value};

/// A JSON-RPC error.
#[derive(Debug, Clone)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

impl RpcError {
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }
    pub fn invalid_params(message: impl Into<String>) -> Self {
        Self::new(-32602, message)
    }
    pub fn not_found(method: &str) -> Self {
        Self::new(-32601, format!("method not found: {method}"))
    }
    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(-32603, message)
    }
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} ({})", self.message, self.code)
    }
}

pub type RpcResult = std::result::Result<Value, RpcError>;

pub fn write_line(w: &mut dyn Write, v: &Value) -> std::io::Result<()> {
    let mut bytes = serde_json::to_vec(v).map_err(std::io::Error::other)?;
    bytes.push(b'\n');
    w.write_all(&bytes)?;
    w.flush()
}

/// One call, waiting up to `timeout`. A JSON-RPC error comes back as
/// `Err(RpcError)` inside `Ok`; a transport failure as the outer `Err`.
pub fn call(socket: &Path, method: &str, params: Value, timeout: Duration) -> Result<RpcResult> {
    let mut stream = Stream::connect(socket).with_context(|| format!("connect {}", socket.display()))?;
    stream.set_read_timeout(Some(timeout))?;
    write_line(&mut stream, &json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    if line.trim().is_empty() {
        bail!("{method}: no reply");
    }
    let mut v: Value = serde_json::from_str(&line).with_context(|| format!("reply to {method}"))?;
    if let Some(err) = v.get("error") {
        return Ok(Err(RpcError::new(
            err.get("code").and_then(Value::as_i64).unwrap_or(-32603),
            err.get("message").and_then(Value::as_str).unwrap_or("error").to_string(),
        )));
    }
    Ok(Ok(v.get_mut("result").map(Value::take).unwrap_or(Value::Null)))
}

/// Open a subscription (`events.subscribe`, `message.subscribe`) and hand
/// every notification to `each` until it returns false or the stream ends.
/// The first line (the subscribe result) goes to `each` too, as
/// `{"result": …}`.
pub fn stream(socket: &Path, method: &str, params: Value, mut each: impl FnMut(Value) -> bool) -> Result<()> {
    let mut stream = Stream::connect(socket).with_context(|| format!("connect {}", socket.display()))?;
    // The core pings every 15 s; silence past this is a dead core.
    stream.set_read_timeout(Some(Duration::from_secs(45)))?;
    write_line(&mut stream, &json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))?;
    let reader = BufReader::new(stream);
    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
        if v.get("error").is_some() {
            bail!("{method}: {}", v["error"]);
        }
        if !each(v) {
            return Ok(());
        }
    }
    bail!("{method}: stream ended")
}

/// What a server does with one call.
pub enum Reply {
    Value(RpcResult),
    /// The connection becomes a stream: the function writes until it fails.
    Stream(Box<dyn FnOnce(&mut dyn Write) + Send>),
}

/// Bind owner-only; refuse when a live server already answers there.
pub fn bind(path: &Path) -> Result<Listener> {
    if Stream::connect(path).is_ok() {
        bail!("already running at {}", path.display());
    }
    #[cfg(unix)]
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    seahelmd::platform::remove_stale(path);
    let listener = Listener::bind(path).with_context(|| format!("bind {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(listener)
}

/// Serve until the listener fails, a thread per connection.
pub fn serve(listener: Listener, dispatch: std::sync::Arc<dyn Fn(&str, Value) -> Reply + Send + Sync>) {
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let dispatch = std::sync::Arc::clone(&dispatch);
        let _ = std::thread::Builder::new().name("gateway-admin".into()).spawn(move || connection(stream, dispatch));
    }
}

fn connection(stream: Stream, dispatch: std::sync::Arc<dyn Fn(&str, Value) -> Reply + Send + Sync>) {
    let Ok(read_half) = stream.try_clone() else { return };
    let mut writer = stream;
    for line in BufReader::new(read_half).lines() {
        let Ok(line) = line else { return };
        if line.trim().is_empty() {
            continue;
        }
        let (id, reply) = match serde_json::from_str::<Value>(&line) {
            Ok(req) => {
                let id = req.get("id").cloned().unwrap_or(Value::Null);
                let method = req.get("method").and_then(Value::as_str).unwrap_or_default().to_string();
                let params = req.get("params").cloned().unwrap_or_else(|| json!({}));
                (id, dispatch(&method, params))
            }
            Err(e) => (Value::Null, Reply::Value(Err(RpcError::new(-32700, format!("parse error: {e}"))))),
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
