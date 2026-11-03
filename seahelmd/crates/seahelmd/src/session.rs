//! A session: one program on one PTY, plus the screen it has drawn.
//!
//! Adapted from keep's `keepd/src/tab.rs` (MIT, Copyright (c) the Keep
//! authors — see crates/keep-vt/LICENSE-keep). What changed: unix only for
//! now, and the grid answers the program's questions whenever nobody is
//! attached, with the colours seahelm latched for the run (`Facts`) — a zmx
//! session started detached swallows OSC 10/11, and an agent that asked then
//! paints without colours for the rest of its life.

use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use keep_vt::{Facts, Format, Terminal};
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};

/// How much we read from the PTY per syscall.
const READ_CHUNK: usize = 64 * 1024;

/// How many chunks may sit unread for one client before the daemon stops
/// queueing for it and repays it with a repaint instead (`Attachment::resync`).
/// A stalled client — a hidden window, a sleeping laptop — must not make the
/// daemon buffer everything a chatty program writes.
const CLIENT_BACKLOG: usize = 64;

/// How much history the grid keeps, in bytes.
const SCROLLBACK_BYTES: usize = 16 << 20;

struct Subscriber {
    id: u64,
    tx: SyncSender<Arc<[u8]>>,
    overflowed: Arc<AtomicBool>,
    /// The size this client shows. Zero in either direction means "not
    /// looking" and is left out of the negotiation.
    size: (u16, u16),
}

/// Screen state and the clients watching it, under one lock on purpose:
/// attaching takes a snapshot and subscribes in one step, so a client neither
/// misses output produced between the two nor replays what the snapshot has.
struct Inner {
    terminal: Terminal,
    subscribers: Vec<Subscriber>,
    next_id: u64,
}

pub struct Session {
    inner: Arc<Mutex<Inner>>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    master: Mutex<Box<dyn MasterPty + Send>>,
    child: Mutex<Box<dyn Child + Send + Sync>>,
    finished: Arc<AtomicBool>,
    size: Mutex<(u16, u16)>,
    pid: Option<u32>,
    facts: Option<Facts>,
}

/// A live feed of everything the session writes from the moment of attach.
/// Dropping it unsubscribes.
pub struct Attachment {
    pub output: Receiver<Arc<[u8]>>,
    inner: Arc<Mutex<Inner>>,
    id: u64,
    overflowed: Arc<AtomicBool>,
}

impl Attachment {
    pub fn id(&self) -> u64 {
        self.id
    }

    pub fn overflowed(&self) -> bool {
        self.overflowed.load(Ordering::Acquire)
    }

    /// Recover from a drop: discard what is queued and return the whole screen
    /// in its place. Both under the lock the reader holds while it parses and
    /// enqueues, so the screen accounts for every byte this client missed.
    pub fn resync(&self) -> Result<Vec<u8>> {
        let guard = self.inner.lock().map_err(|_| anyhow::anyhow!("session poisoned"))?;
        while self.output.try_recv().is_ok() {}
        self.overflowed.store(false, Ordering::Release);
        guard.terminal.snapshot(Format::Vt).map_err(|e| anyhow::anyhow!("snapshot: {e}"))
    }
}

impl Drop for Attachment {
    fn drop(&mut self) {
        if let Ok(mut guard) = self.inner.lock() {
            guard.subscribers.retain(|s| s.id != self.id);
        }
    }
}

impl Session {
    pub fn spawn(command: CommandBuilder, cols: u16, rows: u16, facts: Option<Facts>) -> Result<Self> {
        let pair = native_pty_system()
            .openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .context("openpty")?;
        let child = pair.slave.spawn_command(command).context("spawn child")?;
        let pid = child.process_id();
        // Drop the slave, or the master never sees EOF when the child exits.
        drop(pair.slave);

        let writer: Arc<Mutex<Box<dyn Write + Send>>> =
            Arc::new(Mutex::new(pair.master.take_writer().context("pty writer")?));
        let mut reader = pair.master.try_clone_reader().context("pty reader")?;

        let terminal = new_terminal(cols, rows, facts.as_ref())?;
        let inner = Arc::new(Mutex::new(Inner { terminal, subscribers: Vec::new(), next_id: 0 }));
        let finished = Arc::new(AtomicBool::new(false));

        // Reader thread. The lock is held for the parse and fan-out only,
        // never across the read syscall.
        let sink = Arc::clone(&inner);
        let done = Arc::clone(&finished);
        let answer = Arc::clone(&writer);
        std::thread::Builder::new()
            .name("seahelmd-pty-reader".into())
            .spawn(move || {
                let mut buf = vec![0u8; READ_CHUNK];
                loop {
                    let n = match reader.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => n,
                    };
                    let Ok(mut guard) = sink.lock() else { break };
                    guard.terminal.write(&buf[..n]);
                    // The grid's answers go to the program only while nobody
                    // is attached: an attached client is handed the question
                    // in the output below and answers it itself, and two
                    // answers are one too many. Taken every time either way,
                    // so they never pile up.
                    let events = guard.terminal.take_events();
                    let unanswered = (guard.subscribers.is_empty() && !events.replies.is_empty())
                        .then_some(events.replies);

                    // One allocation for the whole fan-out.
                    let chunk: Arc<[u8]> = Arc::from(&buf[..n]);
                    guard.subscribers.retain(|s| match s.tx.try_send(Arc::clone(&chunk)) {
                        Ok(()) => true,
                        // Too far behind: keep the slot, repaint it later.
                        // Blocking here would stall every other client.
                        Err(TrySendError::Full(_)) => {
                            s.overflowed.store(true, Ordering::Release);
                            true
                        }
                        Err(TrySendError::Disconnected(_)) => false,
                    });
                    // After the lock: the PTY's input can be full, and the
                    // grid must not wait on it.
                    drop(guard);
                    if let Some(replies) = unanswered {
                        if let Ok(mut w) = answer.lock() {
                            let _ = w.write_all(&replies);
                            let _ = w.flush();
                        }
                    }
                }
                done.store(true, Ordering::Release);
                // Dropping the senders lets attached clients notice the end.
                if let Ok(mut guard) = sink.lock() {
                    guard.subscribers.clear();
                }
            })
            .context("spawn reader thread")?;

        Ok(Self {
            inner,
            writer,
            master: Mutex::new(pair.master),
            child: Mutex::new(child),
            finished,
            size: Mutex::new((cols, rows)),
            pid,
            facts,
        })
    }

    /// Subscribe: the screen as it stands, plus a feed of everything after.
    pub fn attach(&self, cols: u16, rows: u16) -> Result<(Vec<u8>, Attachment)> {
        let attachment = {
            let mut guard = self.inner.lock().map_err(|_| anyhow::anyhow!("session poisoned"))?;
            let (tx, rx) = sync_channel(CLIENT_BACKLOG);
            let id = guard.next_id;
            guard.next_id += 1;
            let overflowed = Arc::new(AtomicBool::new(false));
            guard.subscribers.push(Subscriber { id, tx, overflowed: Arc::clone(&overflowed), size: (cols, rows) });
            Attachment { output: rx, inner: Arc::clone(&self.inner), id, overflowed }
        };
        // Size first, screen second: the repaint is the screen the new size
        // produced, taken under the same lock as the drain.
        self.negotiate(Some(attachment.id))?;
        let repaint = self.handover(&attachment)?;
        Ok((repaint, attachment))
    }

    /// Everything a terminal that has seen nothing needs to become this one:
    /// both screens — the shell's history under a full-screen program too,
    /// which a plain snapshot leaves out — every row of history with its
    /// wraps and links, the modes, title and colours.
    ///
    /// Reading the main screen from under the alternate one moves the grid
    /// there, so the grid is then rebuilt from the handover itself: fed to a
    /// fresh terminal, a handover is the terminal it came from.
    fn handover(&self, attachment: &Attachment) -> Result<Vec<u8>> {
        let mut guard = self.inner.lock().map_err(|_| anyhow::anyhow!("session poisoned"))?;
        while attachment.output.try_recv().is_ok() {}
        attachment.overflowed.store(false, Ordering::Release);
        let out = guard.terminal.handover(None);
        let (cols, rows) = guard.terminal.size();
        let mut fresh = new_terminal(cols, rows, self.facts.as_ref())?;
        fresh.write(&out);
        // What the rebuild made the grid say to itself is not the program's
        // business.
        let _ = fresh.take_events();
        guard.terminal = fresh;
        Ok(out)
    }

    /// Fit the PTY to the smallest viewer. A viewer larger than the grid shows
    /// margin; one smaller than it garbles. Nobody looking leaves it alone.
    fn negotiate(&self, caused_by: Option<u64>) -> Result<()> {
        let (wanted, viewers) = {
            let guard = self.inner.lock().map_err(|_| anyhow::anyhow!("session poisoned"))?;
            let looking: Vec<(u16, u16)> =
                guard.subscribers.iter().map(|s| s.size).filter(|(c, r)| *c > 0 && *r > 0).collect();
            let Some(cols) = looking.iter().map(|(c, _)| *c).min() else { return Ok(()) };
            let rows = looking.iter().map(|(_, r)| *r).min().unwrap_or(0);
            ((cols, rows), guard.subscribers.len())
        };
        if wanted == self.size() {
            return Ok(());
        }
        self.resize(wanted.0, wanted.1)?;
        // Everyone else was painted for the old size.
        if viewers > 1 {
            if let Ok(guard) = self.inner.lock() {
                for s in guard.subscribers.iter().filter(|s| Some(s.id) != caused_by) {
                    s.overflowed.store(true, Ordering::Release);
                }
            }
        }
        Ok(())
    }

    pub fn set_viewer_size(&self, viewer: u64, cols: u16, rows: u16) -> Result<()> {
        {
            let mut guard = self.inner.lock().map_err(|_| anyhow::anyhow!("session poisoned"))?;
            let Some(s) = guard.subscribers.iter_mut().find(|s| s.id == viewer) else { return Ok(()) };
            if s.size == (cols, rows) {
                return Ok(());
            }
            s.size = (cols, rows);
        }
        self.negotiate(Some(viewer))
    }

    /// A viewer has gone; whoever is left may have room they did not have.
    pub fn rebalance(&self) {
        let _ = self.negotiate(None);
    }

    pub fn send(&self, bytes: &[u8]) -> Result<()> {
        let mut w = self.writer.lock().map_err(|_| anyhow::anyhow!("writer poisoned"))?;
        w.write_all(bytes)?;
        w.flush()?;
        Ok(())
    }

    /// Screen and scrollback as plain text — what `zmx history` answers.
    pub fn history(&self) -> Result<String> {
        let guard = self.inner.lock().map_err(|_| anyhow::anyhow!("session poisoned"))?;
        let bytes = guard.terminal.snapshot(Format::Plain).map_err(|e| anyhow::anyhow!("snapshot: {e}"))?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }

    /// Resize the PTY and the grid together: the program draws for the size
    /// the kernel reports, and the grid interprets what it draws.
    pub fn resize(&self, cols: u16, rows: u16) -> Result<()> {
        if cols == 0 || rows == 0 {
            return Ok(());
        }
        {
            let mut guard = self.inner.lock().map_err(|_| anyhow::anyhow!("session poisoned"))?;
            guard.terminal.resize(cols, rows).map_err(|e| anyhow::anyhow!("resize grid: {e}"))?;
        }
        self.master
            .lock()
            .map_err(|_| anyhow::anyhow!("master poisoned"))?
            .resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .context("resize pty")?;
        if let Ok(mut s) = self.size.lock() {
            *s = (cols, rows);
        }
        Ok(())
    }

    pub fn size(&self) -> (u16, u16) {
        self.size.lock().map(|s| *s).unwrap_or((80, 24))
    }

    pub fn attached_clients(&self) -> usize {
        self.inner.lock().map(|g| g.subscribers.len()).unwrap_or(0)
    }

    pub fn pid(&self) -> Option<u32> {
        self.pid
    }

    /// Whoever holds the terminal: the running command, or the shell waiting.
    fn foreground_pid(&self) -> Option<i32> {
        self.master.lock().ok()?.process_group_leader()
    }

    /// Where the session is working: the foreground process's directory,
    /// then the program's, then what the shell said over OSC 7.
    pub fn cwd(&self) -> String {
        self.foreground_pid()
            .and_then(process_cwd)
            .or_else(|| self.pid.and_then(|p| process_cwd(p as i32)))
            .or_else(|| {
                let pwd = self.inner.lock().ok().map(|g| g.terminal.pwd())?;
                (!pwd.is_empty()).then_some(pwd)
            })
            .unwrap_or_default()
    }

    /// What holds the terminal, by name: `claude`, `zsh`.
    pub fn command(&self) -> String {
        self.foreground_pid()
            .and_then(process_name)
            .or_else(|| self.pid.and_then(|p| process_name(p as i32)))
            .unwrap_or_default()
    }

    pub fn is_finished(&self) -> bool {
        self.finished.load(Ordering::Acquire)
    }

    pub fn kill(&self) -> Result<()> {
        // The whole process group, as closing a terminal would: an agent's
        // children must not outlive the pane.
        if let Some(pid) = self.pid {
            unsafe { libc::killpg(pid as i32, libc::SIGHUP) };
        }
        let mut c = self.child.lock().map_err(|_| anyhow::anyhow!("child poisoned"))?;
        let _ = c.kill();
        Ok(())
    }
}

fn new_terminal(cols: u16, rows: u16, facts: Option<&Facts>) -> Result<Terminal> {
    let mut terminal = Terminal::new(cols, rows).map_err(|e| anyhow::anyhow!("terminal: {e}"))?;
    terminal
        .set_scrollback_limit(SCROLLBACK_BYTES)
        .map_err(|e| anyhow::anyhow!("scrollback: {e}"))?;
    // Stand in for the terminal while nobody is attached. With facts the
    // colours are seahelm's; without, the questions libghostty-vt can answer
    // on its own still get answers.
    match facts {
        Some(facts) => terminal.act_as_terminal(facts.clone()),
        None => terminal.answer_queries(),
    }
    .map_err(|e| anyhow::anyhow!("terminal: {e}"))?;
    Ok(terminal)
}

#[cfg(target_os = "macos")]
fn process_cwd(pid: i32) -> Option<String> {
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
    let read = unsafe {
        libc::proc_pidinfo(pid, libc::PROC_PIDVNODEPATHINFO, 0, &mut info as *mut _ as *mut libc::c_void, size)
    };
    // A short reply is a failed one: the pid is gone, or not ours to ask about.
    if read < size {
        return None;
    }
    let path = unsafe {
        std::slice::from_raw_parts(
            info.pvi_cdir.vip_path.as_ptr() as *const u8,
            std::mem::size_of_val(&info.pvi_cdir.vip_path),
        )
    };
    let end = path.iter().position(|&b| b == 0).unwrap_or(path.len());
    String::from_utf8(path[..end].to_vec()).ok().filter(|p| !p.is_empty())
}

#[cfg(not(target_os = "macos"))]
fn process_cwd(pid: i32) -> Option<String> {
    std::fs::read_link(format!("/proc/{pid}/cwd"))
        .ok()
        .and_then(|p| p.into_os_string().into_string().ok())
        .filter(|p| !p.is_empty())
}

#[cfg(target_os = "macos")]
fn process_name(pid: i32) -> Option<String> {
    const MAX_PATH: usize = 4 * 1024;
    let mut buf = vec![0u8; MAX_PATH];
    let written = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr() as *mut libc::c_void, MAX_PATH as u32) };
    if written <= 0 {
        return None;
    }
    buf.truncate(written as usize);
    let path = String::from_utf8(buf).ok()?;
    let name = path.rsplit('/').next()?.to_owned();
    (!name.is_empty()).then_some(name)
}

#[cfg(not(target_os = "macos"))]
fn process_name(pid: i32) -> Option<String> {
    let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).ok()?;
    let name = comm.trim().to_owned();
    (!name.is_empty()).then_some(name)
}
