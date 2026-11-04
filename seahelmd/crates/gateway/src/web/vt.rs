//! A page's live terminals: one seahelmd attachment per pane it opened.
//!
//! The gateway attaches straight to the pane's seahelmd socket as a passive
//! viewer (size 0×0, so it never resizes the session the desktop sized) and
//! relays what the daemon sends: a `Repaint` becomes a snapshot frame (the
//! whole screen, which the page resets to), `Output` becomes data. A reader
//! thread per stream hands frames over a bounded channel, so a page that
//! cannot keep up holds the reader, the daemon's queue for this viewer fills,
//! and the daemon sends a fresh repaint instead of a backlog — slow-client
//! handling lives in one place, the daemon.

use std::collections::HashMap;
use std::net::Shutdown;
use std::sync::mpsc as std_mpsc;
use std::time::{Duration, Instant};

use seahelmd::proto::{self, Msg};
use serde_json::{json, Value};
use tokio::sync::mpsc;

use super::frames::{VtEvent, KIND_DATA, KIND_SNAPSHOT};

/// A stream nobody kept alive for this long is dropped.
pub const LEASE: Duration = Duration::from_secs(60);
const DEFAULT_SIZE: (u16, u16) = (120, 32);

struct Stream {
    input: std_mpsc::Sender<Vec<u8>>,
    socket: seahelmd::platform::Stream,
    last_seen: Instant,
}

pub struct VtStreams {
    streams: HashMap<String, Stream>,
    tx: mpsc::Sender<VtEvent>,
}

impl VtStreams {
    pub fn new(tx: mpsc::Sender<VtEvent>) -> VtStreams {
        VtStreams { streams: HashMap::new(), tx }
    }

    pub fn is_open(&self, pane: &str) -> bool {
        self.streams.contains_key(pane)
    }

    /// Attach to `pane`; `{ok, cols, rows}` or `{ok: false, error}`.
    /// Blocking (two local socket round trips).
    pub fn open(&mut self, pane: &str) -> Value {
        if pane.is_empty() {
            return json!({"ok": false, "error": "missing pane_session_key"});
        }
        self.close(pane);
        let (cols, rows) = size_of(pane);
        let socket = match seahelmd::client::connect(pane) {
            Ok(s) => s,
            Err(e) => return json!({"ok": false, "error": e.to_string()}),
        };
        let (Ok(mut reader), Ok(mut writer), Ok(closer)) = (socket.try_clone(), socket.try_clone(), socket.try_clone()) else {
            return json!({"ok": false, "error": "socket clone failed"});
        };
        if let Err(e) = proto::write(&mut writer, &Msg::Attach { cols: 0, rows: 0 }) {
            return json!({"ok": false, "error": e.to_string()});
        }
        let (input, keys) = std_mpsc::channel::<Vec<u8>>();
        let _ = std::thread::Builder::new().name("gateway-vt-in".into()).spawn(move || {
            while let Ok(bytes) = keys.recv() {
                if proto::write(&mut writer, &Msg::Input(bytes)).is_err() {
                    break;
                }
            }
        });
        let tx = self.tx.clone();
        let key = pane.to_string();
        let _ = std::thread::Builder::new().name("gateway-vt-out".into()).spawn(move || {
            let mut first = true;
            loop {
                let event = match proto::read(&mut reader) {
                    Ok(Some(Msg::Repaint(data))) => {
                        // The first repaint answers the attach at the size read
                        // above; a later one may follow a resize.
                        let (cols, rows) = if first { (cols, rows) } else { size_of(&key) };
                        first = false;
                        let mut payload = b"\x1b[H\x1b[2J".to_vec();
                        payload.extend_from_slice(&data);
                        VtEvent { kind: KIND_SNAPSHOT, pane: key.clone(), payload, cols, rows }
                    }
                    Ok(Some(Msg::Output(data))) => VtEvent { kind: KIND_DATA, pane: key.clone(), payload: data, cols: 0, rows: 0 },
                    Ok(Some(Msg::Ended | Msg::Error(_))) | Ok(None) | Err(_) => break,
                    Ok(Some(_)) => continue,
                };
                if tx.blocking_send(event).is_err() {
                    break;
                }
            }
        });
        self.streams.insert(pane.to_string(), Stream { input, socket: closer, last_seen: Instant::now() });
        json!({"ok": true, "cols": cols, "rows": rows})
    }

    pub fn close(&mut self, pane: &str) {
        if let Some(s) = self.streams.remove(pane) {
            // Ends both threads: the reader sees EOF, the writer's sender drops.
            let _ = s.socket.shutdown(Shutdown::Both);
        }
    }

    pub fn close_all(&mut self) {
        for key in self.streams.keys().cloned().collect::<Vec<_>>() {
            self.close(&key);
        }
    }

    pub fn keepalive(&mut self, pane: &str) {
        if let Some(s) = self.streams.get_mut(pane) {
            s.last_seen = Instant::now();
        }
    }

    pub fn send(&mut self, pane: &str, bytes: Vec<u8>) -> bool {
        match self.streams.get_mut(pane) {
            Some(s) if !bytes.is_empty() => {
                s.last_seen = Instant::now();
                s.input.send(bytes).is_ok()
            }
            _ => false,
        }
    }

    /// Drop streams whose lease ran out.
    pub fn reap(&mut self) {
        let stale: Vec<String> = self.streams.iter().filter(|(_, s)| s.last_seen.elapsed() > LEASE).map(|(k, _)| k.clone()).collect();
        for k in stale {
            self.close(&k);
        }
    }
}

impl Drop for VtStreams {
    fn drop(&mut self) {
        self.close_all();
    }
}

/// The session's size as its daemon reports it.
fn size_of(pane: &str) -> (u16, u16) {
    let Ok(Msg::Text(json)) = seahelmd::client::request(pane, &Msg::Snapshot) else { return DEFAULT_SIZE };
    let Ok(v) = serde_json::from_str::<Value>(&json) else { return DEFAULT_SIZE };
    let n = |k: &str| v.get(k).and_then(Value::as_u64).filter(|n| *n > 0 && *n <= u16::MAX as u64).map(|n| n as u16);
    match (n("cols"), n("rows")) {
        (Some(c), Some(r)) => (c, r),
        _ => DEFAULT_SIZE,
    }
}
