//! One session's daemon: the process that owns its PTY.
//!
//! One daemon per session, unlike keep: a daemon that dies takes one pane
//! with it, not every agent at once. It listens on
//! `<dir>/<name>`, takes one thread per connection, and exits — removing its
//! socket — when the program it runs exits.

use std::io::Write;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::RecvTimeoutError;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use keep_vt::{Device, Facts};
use portable_pty::CommandBuilder;

use crate::proto::{self, Msg};
use crate::session::Session;

/// How much queued output one frame to a client may carry.
const COALESCE_BYTES: usize = 256 * 1024;

/// The size a session starts at, before anybody attaches and says otherwise.
const START_SIZE: (u16, u16) = (80, 24);

/// The session, started on demand: at once, or — held — when the first
/// client attaches (at that client's size) or the hold runs out.
///
/// Holding is what lets an agent start straight into a pane. Its startup
/// questions — colours, terminal identity, OSC 7501 — are asked once, and a
/// pane attached when it asks answers them the way the app will keep
/// answering; and it draws its first frame at the pane's size instead of
/// 80x24 and a reflow.
struct Lazy {
    session: Mutex<Option<Arc<Session>>>,
    pending: Mutex<Option<Box<dyn FnOnce(u16, u16) -> Result<Session> + Send>>>,
    started: Condvar,
}

impl Lazy {
    fn get(&self) -> Option<Arc<Session>> {
        self.session.lock().ok()?.clone()
    }

    /// The session, starting it at `size` if nobody has yet.
    fn get_or_start(&self, size: (u16, u16)) -> Result<Arc<Session>> {
        let mut slot = self.session.lock().map_err(|_| anyhow::anyhow!("poisoned"))?;
        if let Some(s) = slot.as_ref() {
            return Ok(Arc::clone(s));
        }
        let start = self.pending.lock().map_err(|_| anyhow::anyhow!("poisoned"))?.take();
        let start = start.ok_or_else(|| anyhow::anyhow!("session failed to start"))?;
        let session = Arc::new(start(size.0, size.1)?);
        *slot = Some(Arc::clone(&session));
        self.started.notify_all();
        Ok(session)
    }
}

pub fn serve(socket: &Path, name: &str, argv: &[String], hold: Option<Duration>) -> Result<()> {
    let mut command = match argv.split_first() {
        Some((program, args)) => {
            let mut c = CommandBuilder::new(program);
            c.args(args);
            c
        }
        None => CommandBuilder::new_default_prog(),
    };
    // portable-pty starts in $HOME unless told; the session belongs where it
    // was asked for.
    let start_dir = std::env::current_dir().context("cwd")?;
    command.cwd(&start_dir);
    // Also what seahelm's hook bridge reads to find the pane when nothing
    // better is set.
    command.env("SEAHELMD_SESSION", name);

    let facts = facts_from_env();
    let lazy = Arc::new(Lazy {
        session: Mutex::new(None),
        pending: Mutex::new(Some(Box::new(move |cols, rows| Session::spawn(command, cols, rows, facts)))),
        started: Condvar::new(),
    });
    let created = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);

    let listener = UnixListener::bind(socket).with_context(|| format!("bind {}", socket.display()))?;
    {
        let lazy = Arc::clone(&lazy);
        let name = name.to_string();
        let start_dir = start_dir.display().to_string();
        std::thread::Builder::new().name("seahelmd-accept".into()).spawn(move || {
            for stream in listener.incoming().flatten() {
                let lazy = Arc::clone(&lazy);
                let name = name.clone();
                let start_dir = start_dir.clone();
                let _ = std::thread::Builder::new()
                    .name("seahelmd-conn".into())
                    .spawn(move || handle(stream, &lazy, &name, created, &start_dir));
            }
        })?;
    }

    // Held: wait for the first attach to start it, or start it anyway.
    if let Some(hold) = hold {
        let deadline = Instant::now() + hold;
        let mut slot = lazy.session.lock().map_err(|_| anyhow::anyhow!("poisoned"))?;
        while slot.is_none() {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            slot = lazy.started.wait_timeout(slot, left).map_err(|_| anyhow::anyhow!("poisoned"))?.0;
        }
    }
    let session = match lazy.get_or_start(START_SIZE) {
        Ok(s) => s,
        Err(e) => {
            let _ = std::fs::remove_file(socket);
            return Err(e);
        }
    };

    while !session.is_finished() {
        std::thread::sleep(Duration::from_millis(100));
    }
    // Gone from `list` before the last clients hear the end.
    let _ = std::fs::remove_file(socket);
    std::thread::sleep(Duration::from_millis(300));
    Ok(())
}

fn handle(stream: UnixStream, lazy: &Arc<Lazy>, name: &str, created: u64, start_dir: &str) {
    let mut reader = match stream.try_clone() {
        Ok(r) => r,
        Err(_) => return,
    };
    let mut writer = stream;
    let first = match proto::read(&mut reader) {
        Ok(Some(m)) => m,
        _ => return,
    };
    // Questions about a session still held answer as for one with nobody
    // watching; anything that needs the program starts it.
    let reply = match first {
        Msg::Attach { cols, rows } => match lazy.get_or_start((cols, rows)) {
            Ok(session) => return attached(reader, writer, &session, cols, rows),
            Err(e) => Msg::Error(e.to_string()),
        },
        // The row seahelm parses (`SessionManager.parseSeahelmdSessions`). start_dir is
        // last because a path may hold spaces and it runs to the end of line.
        Msg::Info => {
            let session = lazy.get();
            Msg::Text(format!(
                "name={name}\tpid={}\tclients={}\tcreated={created}\tcmd={}\tcwd={}\tstart_dir={start_dir}",
                session.as_ref().and_then(|s| s.pid()).map(|p| p.to_string()).unwrap_or_default(),
                session.as_ref().map(|s| s.attached_clients()).unwrap_or(0),
                session.as_ref().map(|s| s.command()).unwrap_or_default(),
                session.as_ref().map(|s| s.cwd()).unwrap_or_else(|| start_dir.to_string()),
            ))
        }
        // A held session has drawn nothing and said nothing yet.
        Msg::Snapshot => match lazy.get().map(|s| s.snapshot()) {
            Some(Ok(json)) => Msg::Text(json),
            Some(Err(e)) => Msg::Error(e.to_string()),
            None => Msg::Text(r#"{"started":false}"#.to_string()),
        },
        Msg::History => match lazy.get().map(|s| s.history()) {
            Some(Ok(text)) => Msg::Text(text),
            Some(Err(e)) => Msg::Error(e.to_string()),
            None => Msg::Text(String::new()),
        },
        Msg::Send(bytes) => match lazy.get_or_start(START_SIZE).and_then(|s| s.send(&bytes)) {
            Ok(()) => Msg::Ok,
            Err(e) => Msg::Error(e.to_string()),
        },
        Msg::Kill => match lazy.get() {
            Some(session) => match session.kill() {
                Ok(()) => Msg::Ok,
                Err(e) => Msg::Error(e.to_string()),
            },
            // Never started: nothing to end but the daemon itself.
            None => {
                let _ = std::fs::remove_file(crate::client::socket_path(name).unwrap_or_default());
                let _ = proto::write(&mut writer, &Msg::Ok);
                std::process::exit(0);
            }
        },
        other => Msg::Error(format!("not a request: {other:?}")),
    };
    let _ = proto::write(&mut writer, &reply);
}

/// An attached client: a pump thread carries the session's output to it, and
/// this thread carries its keystrokes and size to the session. Only the pump
/// writes to the socket and only this thread reads it.
fn attached(mut reader: UnixStream, mut writer: UnixStream, session: &Arc<Session>, cols: u16, rows: u16) {
    let (repaint, attachment) = match session.attach(cols, rows) {
        Ok(a) => a,
        Err(e) => {
            let _ = proto::write(&mut writer, &Msg::Error(e.to_string()));
            return;
        }
    };
    let viewer = attachment.id();
    let stop = Arc::new(AtomicBool::new(false));
    let pump = {
        let stop = Arc::clone(&stop);
        std::thread::Builder::new().name("seahelmd-pump".into()).spawn(move || {
            if proto::write(&mut writer, &Msg::Repaint(repaint)).is_err() {
                return;
            }
            while !stop.load(Ordering::Acquire) {
                let msg = match attachment.output.recv_timeout(Duration::from_millis(100)) {
                    // Behind: what is queued is stale, the whole screen is not.
                    Ok(_) | Err(RecvTimeoutError::Timeout) if attachment.overflowed() => {
                        match attachment.resync() {
                            Ok(screen) => Msg::Repaint(screen),
                            Err(_) => break,
                        }
                    }
                    // Everything already queued goes in the same frame. A PTY
                    // read is small (about 1 KiB on macOS), and a frame per
                    // read left the pump a write and a wakeup behind the
                    // reader on every chunk, so a chatty program filled the
                    // backlog and was repaid in repaints, hundreds a second.
                    Ok(chunk) => {
                        let mut out = chunk.to_vec();
                        while out.len() < COALESCE_BYTES {
                            match attachment.output.try_recv() {
                                Ok(more) => out.extend_from_slice(&more),
                                Err(_) => break,
                            }
                        }
                        // Dropped while we drained: the screen, not the tail.
                        if attachment.overflowed() {
                            match attachment.resync() {
                                Ok(screen) => Msg::Repaint(screen),
                                Err(_) => break,
                            }
                        } else {
                            Msg::Output(out)
                        }
                    }
                    Err(RecvTimeoutError::Timeout) => continue,
                    Err(RecvTimeoutError::Disconnected) => {
                        let _ = proto::write(&mut writer, &Msg::Ended);
                        break;
                    }
                };
                if proto::write(&mut writer, &msg).is_err() {
                    break;
                }
            }
            let _ = writer.flush();
            // Dropping the attachment here unsubscribes.
        })
    };

    loop {
        match proto::read(&mut reader) {
            Ok(Some(Msg::Input(bytes))) => {
                if session.send(&bytes).is_err() {
                    break;
                }
            }
            Ok(Some(Msg::Resize { cols, rows })) => {
                let _ = session.set_viewer_size(viewer, cols, rows);
            }
            Ok(Some(_)) => {}
            Ok(None) | Err(_) => break,
        }
    }
    stop.store(true, Ordering::Release);
    if let Ok(pump) = pump {
        let _ = pump.join();
    }
    session.rebalance();
}

/// What the session answers for the terminal while nobody is attached.
///
/// `SEAHELMD_FACTS="fg=cdd6f4 bg=1e1e2e cursor=f5e0dc dark=1"` — seahelm
/// passes the palette it latched for the run. The device attributes and
/// version are Ghostty's, so a program asking before anyone attaches is told
/// the same thing it would be told after.
fn facts_from_env() -> Option<Facts> {
    let spec = std::env::var("SEAHELMD_FACTS").ok()?;
    let mut facts = Facts {
        device: Some(Device {
            conformance: 62,
            features: vec![22, 52],
            device_type: 1,
            firmware: 10,
            rom: 0,
            tertiary: None,
        }),
        xtversion: Some("ghostty".into()),
        terminfo: Some("xterm-ghostty".into()),
        ..Facts::default()
    };
    for pair in spec.split_whitespace() {
        let Some((key, value)) = pair.split_once('=') else { continue };
        match key {
            "fg" => facts.foreground = hex(value),
            "bg" => facts.background = hex(value),
            "cursor" => facts.cursor = hex(value),
            "dark" => facts.dark = Some(value == "1" || value == "true"),
            _ => {}
        }
    }
    Some(facts)
}

fn hex(s: &str) -> Option<[u8; 3]> {
    let s = s.trim_start_matches('#');
    if s.len() != 6 {
        return None;
    }
    let byte = |i: usize| u8::from_str_radix(&s[i..i + 2], 16).ok();
    Some([byte(0)?, byte(2)?, byte(4)?])
}

#[cfg(test)]
mod tests {
    use super::hex;

    #[test]
    fn colours_read_with_or_without_a_hash() {
        assert_eq!(hex("#1e1e2e"), Some([0x1e, 0x1e, 0x2e]));
        assert_eq!(hex("cdd6f4"), Some([0xcd, 0xd6, 0xf4]));
        assert_eq!(hex("fff"), None);
    }
}
