//! A page's live terminals: one seahelmd attachment per pane it opened.
//!
//! The gateway attaches straight to the pane's seahelmd socket, by default as
//! a passive viewer (size 0×0, so it never resizes the session the desktop
//! sized). A page that asks to be sized (`pane.vt_size`) becomes a viewer of
//! its own size instead, and the daemon fits the session to its smallest
//! viewer, as it does for any client. The gateway relays what the daemon sends: a `Repaint` becomes a snapshot frame (the
//! whole screen, which the page resets to), `Output` becomes data. A reader
//! thread per stream hands frames over a bounded channel, so a page that
//! cannot keep up holds the reader, the daemon's queue for this viewer fills,
//! and the daemon sends a fresh repaint instead of a backlog — slow-client
//! handling lives in one place, the daemon.

use std::collections::HashMap;
use std::net::Shutdown;
use std::sync::mpsc as std_mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use seahelmd::proto::{self, Msg};
use serde_json::{json, Value};
use tokio::sync::mpsc;

use super::frames::{VtEvent, KIND_DATA, KIND_SNAPSHOT};

/// A stream nobody kept alive for this long is dropped.
pub const LEASE: Duration = Duration::from_secs(60);
const DEFAULT_SIZE: (u16, u16) = (120, 32);
/// The smallest grid a page may ask for; below it nothing is readable anyway.
pub const MIN_SIZE: (u16, u16) = (20, 5);
/// And the largest, so a bad request cannot ask the program for a huge grid.
pub const MAX_SIZE: (u16, u16) = (500, 200);

struct Stream {
    input: std_mpsc::Sender<Vec<u8>>,
    socket: seahelmd::platform::Stream,
    last_seen: Instant,
    /// Whether this attachment still speaks for the pane. Its reader checks
    /// it, under the lock, before every frame it hands on, so once a
    /// replacement has cleared it nothing from the old attachment follows.
    live: Arc<Mutex<bool>>,
    /// The size this attachment asked for; (0, 0) is passive.
    size: (u16, u16),
}

impl Stream {
    fn retire(&self) {
        if let Ok(mut live) = self.live.lock() {
            *live = false;
        }
    }
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

    /// Attach to `pane` as a passive viewer; `{ok, cols, rows}` or
    /// `{ok: false, error}`. Blocking (two local socket round trips).
    pub fn open(&mut self, pane: &str) -> Value {
        if pane.is_empty() {
            return json!({"ok": false, "error": "missing pane_session_key"});
        }
        self.close(pane);
        self.attach(pane, (0, 0), None)
    }

    /// Give an open pane's attachment a size of its own, or (0, 0) to go back
    /// to passive. `{ok}` or `{ok: false, error}`; the new size reaches the
    /// page as the next snapshot frame.
    ///
    /// The daemon takes a viewer's size from its attach, and only repaints a
    /// viewer for a resize somebody else caused. So the size is changed by
    /// attaching afresh at it and dropping the old attachment once the new one
    /// has its screen: the page gets a whole screen at the new size, and the
    /// session is never left without this viewer in between (which would let
    /// it spring back to the desktop's size, and the program redraw twice).
    pub fn resize(&mut self, pane: &str, cols: u16, rows: u16) -> Value {
        let size = if cols == 0 || rows == 0 {
            (0, 0)
        } else {
            (cols.clamp(MIN_SIZE.0, MAX_SIZE.0), rows.clamp(MIN_SIZE.1, MAX_SIZE.1))
        };
        let Some(old) = self.streams.remove(pane) else {
            return json!({"ok": false, "error": "pane is not open"});
        };
        if old.size == size {
            self.streams.insert(pane.to_string(), old);
            return json!({"ok": true});
        }
        old.retire();
        self.attach(pane, size, Some(old.socket))
    }

    /// One attachment at `size`. `replacing` is the socket of the attachment
    /// this one takes over from: shut once this one has its first screen.
    fn attach(&mut self, pane: &str, size: (u16, u16), replacing: Option<seahelmd::platform::Stream>) -> Value {
        let drop_old = |old: &Option<seahelmd::platform::Stream>| {
            if let Some(o) = old {
                let _ = o.shutdown(Shutdown::Both);
            }
        };
        // Passive, the session keeps its size: read it now. Sized, the daemon
        // fits the session before its first repaint: read it then.
        let passive = size == (0, 0);
        let (cols, rows) = if passive { size_of(pane) } else { (0, 0) };
        let socket = match seahelmd::client::connect(pane) {
            Ok(s) => s,
            Err(e) => {
                drop_old(&replacing);
                return json!({"ok": false, "error": e.to_string()});
            }
        };
        let (Ok(mut reader), Ok(mut writer), Ok(closer)) = (socket.try_clone(), socket.try_clone(), socket.try_clone()) else {
            drop_old(&replacing);
            return json!({"ok": false, "error": "socket clone failed"});
        };
        if let Err(e) = proto::write(&mut writer, &Msg::Attach { cols: size.0, rows: size.1 }) {
            drop_old(&replacing);
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
        let live = Arc::new(Mutex::new(true));
        let still_live = Arc::clone(&live);
        let _ = std::thread::Builder::new().name("gateway-vt-out".into()).spawn(move || {
            let mut first = true;
            let mut replacing = replacing;
            loop {
                let event = match proto::read(&mut reader) {
                    Ok(Some(Msg::Repaint(data))) => {
                        // The first repaint answers the attach at the size it
                        // asked for; a later one may follow a resize.
                        let (cols, rows) = if first && passive { (cols, rows) } else { size_of(&key) };
                        first = false;
                        let mut payload = b"\x1b[H\x1b[2J".to_vec();
                        payload.extend_from_slice(&data);
                        VtEvent { kind: KIND_SNAPSHOT, pane: key.clone(), payload, cols, rows }
                    }
                    Ok(Some(Msg::Output(data))) => VtEvent { kind: KIND_DATA, pane: key.clone(), payload: data, cols: 0, rows: 0 },
                    Ok(Some(Msg::Ended | Msg::Error(_))) | Ok(None) | Err(_) => break,
                    Ok(Some(_)) => continue,
                };
                let sent = match still_live.lock() {
                    Ok(live) if *live => tx.blocking_send(event).is_ok(),
                    _ => false,
                };
                // The daemon has taken this attach: the one it replaces can go.
                drop_old(&replacing.take());
                if !sent {
                    break;
                }
            }
            drop_old(&replacing);
        });
        self.streams.insert(pane.to_string(), Stream { input, socket: closer, last_seen: Instant::now(), live, size });
        if passive {
            json!({"ok": true, "cols": cols, "rows": rows})
        } else {
            json!({"ok": true})
        }
    }

    pub fn close(&mut self, pane: &str) {
        if let Some(s) = self.streams.remove(pane) {
            // Ends both threads: the reader sees EOF, the writer's sender drops.
            s.retire();
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

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn next_snapshot(rx: &mut mpsc::Receiver<VtEvent>) -> (u16, u16) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            assert!(Instant::now() < deadline, "no snapshot frame");
            match rx.try_recv() {
                Ok(e) if e.kind == KIND_SNAPSHOT => return (e.cols, e.rows),
                Ok(_) => {}
                Err(_) => std::thread::sleep(Duration::from_millis(20)),
            }
        }
    }

    /// Growing goes through the old size: the old attachment holds it until
    /// the new one has its screen, then lets go, and the page is repainted.
    fn snapshot_until(rx: &mut mpsc::Receiver<VtEvent>, want: (u16, u16)) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while next_snapshot(rx) != want {
            assert!(Instant::now() < deadline, "the page never got a {want:?} screen");
        }
    }

    fn wait_size(pane: &str, want: (u16, u16)) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while size_of(pane) != want {
            assert!(Instant::now() < deadline, "session never became {want:?}, is {:?}", size_of(pane));
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// A page that asks for its own size shrinks the session while it looks,
    /// gets a whole screen at that size, and hands the size back when it stops.
    #[test]
    fn a_sized_page_fits_the_session_and_gives_it_back() {
        let dir = PathBuf::from(format!("/tmp/shgw-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // The only test in this crate that talks to a daemon.
        std::env::set_var("SEAHELMD_DIR", &dir);
        let name = "vt-size";
        let socket = seahelmd::client::socket_path(name).unwrap();
        std::thread::spawn(move || {
            let argv = vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 60".to_string()];
            let _ = seahelmd::daemon::serve(&socket, name, &argv, None);
        });

        // The desktop pane, attached at its size.
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut desk = loop {
            match seahelmd::client::connect(name) {
                Ok(s) => break s,
                Err(_) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
                Err(e) => panic!("{e}"),
            }
        };
        proto::write(&mut desk, &Msg::Attach { cols: 100, rows: 30 }).unwrap();
        wait_size(name, (100, 30));
        // Keep the desktop's queue drained so the daemon never drops it.
        let mut desk_reader = desk.try_clone().unwrap();
        std::thread::spawn(move || while let Ok(Some(_)) = proto::read(&mut desk_reader) {});

        let (tx, mut rx) = mpsc::channel(64);
        let mut vt = VtStreams::new(tx);
        assert_eq!(vt.open(name)["ok"], true);
        assert_eq!(next_snapshot(&mut rx), (100, 30), "passive: the desktop's size");

        assert_eq!(vt.resize(name, 60, 20)["ok"], true);
        assert_eq!(next_snapshot(&mut rx), (60, 20), "sized: a screen at the page's size");
        wait_size(name, (60, 20));

        // Wider than the desktop: the smaller of each wins.
        assert_eq!(vt.resize(name, 160, 24)["ok"], true);
        snapshot_until(&mut rx, (100, 24));
        wait_size(name, (100, 24));

        assert_eq!(vt.resize(name, 0, 0)["ok"], true);
        snapshot_until(&mut rx, (100, 30));
        wait_size(name, (100, 30));

        assert_eq!(vt.resize("no-such-pane", 60, 20)["ok"], false);
        drop(vt);
        let _ = seahelmd::client::request(name, &Msg::Kill);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
