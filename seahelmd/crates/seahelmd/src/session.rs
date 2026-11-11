//! A session: one program on one PTY, plus the screen it has drawn.
//!
//! Adapted from keep's `keepd/src/tab.rs` (MIT, Copyright (c) the Keep
//! authors — see crates/keep-vt/LICENSE-keep). What changed: the platform
//! specifics live in `platform`; the stream is also read for OSC 7501 / 133 / 9;4, which a status
//! reader gets from `snapshot`; and the grid answers the program's questions whenever nobody is
//! attached, with the colours seahelm gives it (`Facts`) — a session
//! started detached that swallowed OSC 10/11 would leave an agent that asked
//! then painting without colours for the rest of its life.

use std::borrow::Cow;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use keep_vt::osc_scan::{Osc, Scanner};
use keep_vt::program_status::{self, Command, Store};
use keep_vt::{Facts, Format, Terminal};
use crate::platform;
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
    /// Attached with `TakeOver`: while any such viewer looks, the session is
    /// sized for those alone.
    takes_over: bool,
    /// Shown the notice: a taker sized the session past this viewer.
    parked: Arc<AtomicBool>,
}

/// Screen state and the clients watching it, under one lock on purpose:
/// attaching takes a snapshot and subscribes in one step, so a client neither
/// misses output produced between the two nor replays what the snapshot has.
struct Inner {
    terminal: Terminal,
    subscribers: Vec<Subscriber>,
    next_id: u64,
    /// What the program has said beside the screen, read off the stream by
    /// `Scanner` (see `Session::snapshot`).
    signals: Signals,
}

/// The OSC traffic a status reader wants and the grid does not keep.
#[derive(Default)]
struct Signals {
    /// Bumped on every write the grid parses, so a reader can tell an
    /// unchanged screen without reading it.
    generation: u64,
    /// OSC 7501 records (program status).
    program: Store,
    /// Bumped whenever the live root record changes, so a reader polling
    /// every few seconds still sees each change of it.
    program_seq: u64,
    /// OSC 9;4: (state, percent); None once cleared.
    progress: Option<(u8, Option<u8>)>,
}

impl Signals {
    /// The live root record as a reader sees it: what it says, not when.
    fn root_seen(&self) -> Option<(program_status::Report, String)> {
        self.program.live_root().map(|r| (r.report.clone(), r.app.clone()))
    }

    /// Take in what the scanner found. Returns what the terminal answers to
    /// it (the 7501 support query), for the caller to send or not.
    fn take(&mut self, found: Vec<Osc>) -> Vec<u8> {
        let mut replies = Vec::new();
        for osc in found {
            match osc {
                Osc::ProgramStatus { body, bel } => match program_status::parse(&body) {
                    Some(Command::Query) => {
                        replies.extend_from_slice(b"\x1b]7501;");
                        replies.extend_from_slice(program_status::QUERY_REPLY.as_bytes());
                        replies.extend_from_slice(if bel { b"\x07" } else { b"\x1b\\" });
                    }
                    Some(Command::Report(report)) => {
                        let before = self.root_seen();
                        self.program.apply(report);
                        if self.root_seen() != before {
                            self.program_seq += 1;
                        }
                    }
                    None => {}
                },
                // The shell has the terminal back: the program's records end.
                Osc::Shell { mark: b'D', .. } => {
                    let before = self.root_seen();
                    self.program.prompt_returned();
                    if self.root_seen() != before {
                        self.program_seq += 1;
                    }
                }
                Osc::Shell { .. } => {}
                Osc::Progress { state, percent } => {
                    self.progress = (state != 0).then_some((state, percent));
                }
            }
        }
        replies
    }
}

pub struct Session {
    inner: Arc<Mutex<Inner>>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    /// Taken (closed) on Windows once the program exits: see `spawn`.
    master: Arc<Mutex<Option<Box<dyn MasterPty + Send>>>>,
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
    parked: Arc<AtomicBool>,
}

impl Attachment {
    pub fn id(&self) -> u64 {
        self.id
    }

    pub fn overflowed(&self) -> bool {
        self.overflowed.load(Ordering::Acquire)
    }

    /// Whether a taker has sized the session past this viewer.
    pub fn parked(&self) -> bool {
        self.parked.load(Ordering::Acquire)
    }

    /// What a parked viewer is shown in place of the screen.
    pub fn notice(&self) -> Vec<u8> {
        let (cols, rows) = self.inner.lock().map(|g| g.terminal.size()).unwrap_or((0, 0));
        format!(
            "\r\n  \x1b[1mThis pane is shown on another screen, at {cols}\u{d7}{rows}.\x1b[0m\r\n\r\n  \x1b[2mIt comes back here when that screen lets go. Keys typed here still reach it.\x1b[0m\r\n"
        )
        .into_bytes()
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
        let inner = Arc::new(Mutex::new(Inner {
            terminal,
            subscribers: Vec::new(),
            next_id: 0,
            signals: Signals::default(),
        }));
        let finished = Arc::new(AtomicBool::new(false));
        let master: Arc<Mutex<Option<Box<dyn MasterPty + Send>>>> = Arc::new(Mutex::new(Some(pair.master)));

        // A pseudoconsole outlives the program it was made for: its output
        // stays open until it is closed, so the reader below would wait for
        // an end that never comes. The program exiting is what closes it, as
        // the last process leaving a Unix PTY does there (where this is a
        // no-op). Out of the lock before it is dropped: closing waits for the
        // console host to finish.
        if let Some(pid) = pid {
            let slot = Arc::clone(&master);
            platform::on_exit(pid, move || {
                let closed = slot.lock().ok().and_then(|mut m| m.take());
                drop(closed);
            });
        }

        // Reader thread. The lock is held for the parse and fan-out only,
        // never across the read syscall.
        let sink = Arc::clone(&inner);
        let done = Arc::clone(&finished);
        let answer = Arc::clone(&writer);
        std::thread::Builder::new()
            .name("seahelmd-pty-reader".into())
            .spawn(move || {
                let mut buf = vec![0u8; READ_CHUNK];
                let mut scanner = Scanner::new();
                loop {
                    let n = match reader.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => n,
                    };
                    let Ok(mut guard) = sink.lock() else { break };
                    // The grid does not know OSC 7501, so its support query
                    // is answered here, in its place among the grid's
                    // answers: the chunk goes in up to each query, so that
                    // what came before it is answered first. Claude Code
                    // sends it beside DA1 and reads DA1's answer as "none of
                    // the rest are coming"; a 7501 answer after it is ignored.
                    let mut replies = Vec::new();
                    let mut at = 0;
                    for (end, osc) in scanner.feed(&buf[..n]) {
                        if matches!(&osc, Osc::ProgramStatus { body, .. } if body.as_slice() == b"?") {
                            guard.terminal.write(&buf[at..end]);
                            replies.append(&mut guard.terminal.take_events().replies);
                            at = end;
                        }
                        replies.append(&mut guard.signals.take(vec![osc]));
                    }
                    guard.terminal.write(&buf[at..n]);
                    guard.signals.generation += 1;
                    replies.append(&mut guard.terminal.take_events().replies);
                    // The grid's answers go to the program only while nobody
                    // is attached: an attached client is handed the question
                    // in the output below and answers it itself, and two
                    // answers are one too many. Taken every time either way,
                    // so they never pile up.
                    //
                    // Except under ConPTY, where the grid always answers where
                    // the cursor is and the question goes no further: ConPTY
                    // asks it as it opens and holds the program's output back
                    // until it hears — from whoever is watching, which may be
                    // a client that does not answer, or nobody yet. The grid
                    // is drawn from the same stream as every client's screen,
                    // so its answer is theirs.
                    let attached = !guard.subscribers.is_empty();
                    let unanswered = match (attached, CONPTY) {
                        (false, _) => (!replies.is_empty()).then_some(replies),
                        (true, true) => Some(cursor_reports(&replies)).filter(|r| !r.is_empty()),
                        (true, false) => None,
                    };

                    // One allocation for the whole fan-out.
                    let forward = if CONPTY { without_cursor_queries(&buf[..n]) } else { Cow::Borrowed(&buf[..n]) };
                    let chunk: Arc<[u8]> = Arc::from(&forward[..]);
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
            master,
            child: Mutex::new(child),
            finished,
            size: Mutex::new((cols, rows)),
            pid,
            facts,
        })
    }

    /// Subscribe: the screen as it stands, plus a feed of everything after.
    pub fn attach(&self, cols: u16, rows: u16, takes_over: bool) -> Result<(Vec<u8>, Attachment)> {
        let attachment = {
            let mut guard = self.inner.lock().map_err(|_| anyhow::anyhow!("session poisoned"))?;
            let (tx, rx) = sync_channel(CLIENT_BACKLOG);
            let id = guard.next_id;
            guard.next_id += 1;
            let overflowed = Arc::new(AtomicBool::new(false));
            let parked = Arc::new(AtomicBool::new(false));
            guard.subscribers.push(Subscriber {
                id,
                tx,
                overflowed: Arc::clone(&overflowed),
                size: (cols, rows),
                takes_over,
                parked: Arc::clone(&parked),
            });
            Attachment { output: rx, inner: Arc::clone(&self.inner), id, overflowed, parked }
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
    ///
    /// While a viewer that takes over looks, only takers count, and every
    /// other viewer the grid no longer fits is parked: shown a notice rather
    /// than the screen. The last taker leaving unparks them, each repainted.
    fn negotiate(&self, caused_by: Option<u64>) -> Result<()> {
        let looks = |s: &Subscriber| s.size.0 > 0 && s.size.1 > 0;
        let (wanted, viewers) = {
            let guard = self.inner.lock().map_err(|_| anyhow::anyhow!("session poisoned"))?;
            let taking = guard.subscribers.iter().any(|s| looks(s) && s.takes_over);
            let looking: Vec<(u16, u16)> =
                guard.subscribers.iter().filter(|s| looks(s) && (s.takes_over || !taking)).map(|s| s.size).collect();
            let Some(cols) = looking.iter().map(|(c, _)| *c).min() else { return Ok(()) };
            let rows = looking.iter().map(|(_, r)| *r).min().unwrap_or(0);
            let wanted = (cols, rows);
            for s in &guard.subscribers {
                let park = taking && !s.takes_over && looks(s) && (s.size.0 < wanted.0 || s.size.1 < wanted.1);
                let was = s.parked.swap(park, Ordering::AcqRel);
                if was && !park {
                    s.overflowed.store(true, Ordering::Release);
                }
            }
            (wanted, guard.subscribers.len())
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

    /// What a status reader polls (`seahelmd snapshot`): the visible screen,
    /// and what the program has said beside it. JSON, one object.
    pub fn snapshot(&self) -> Result<String> {
        let guard = self.inner.lock().map_err(|_| anyhow::anyhow!("session poisoned"))?;
        let t = &guard.terminal;
        let (cols, rows) = t.size();
        let viewport = t.viewport_text().map_err(|e| anyhow::anyhow!("viewport: {e}"))?;
        let sig = &guard.signals;
        let mut j = Json::object();
        j.num("generation", sig.generation as i64);
        j.num("cols", cols as i64);
        j.num("rows", rows as i64);
        // This daemon knows `Msg::TakeOver`.
        j.boolean("take_over", true);
        j.boolean("alt_screen", t.alternate_screen().is_some());
        j.string("title", &t.title());
        j.string("pwd", &t.pwd());
        match sig.progress {
            Some((state, percent)) => {
                let mut p = Json::object();
                p.num("state", state as i64);
                p.opt_num("percent", percent.map(|v| v as i64));
                j.raw("progress", &p.finish());
            }
            None => j.raw("progress", "null"),
        }
        j.num("program_seq", sig.program_seq as i64);
        match sig.program.live_root() {
            Some(rec) => {
                let r = &rec.report;
                let mut p = Json::object();
                p.string("state", r.state.name());
                p.opt_string("kind", r.kind.map(|k| k.name()));
                p.opt_num("progress", r.progress.map(|v| v as i64));
                p.string("app", &rec.app);
                p.string("title", &r.title);
                p.string("msg", &r.msg);
                j.raw("program", &p.finish());
            }
            None => j.raw("program", "null"),
        }
        j.string("viewport", &viewport);
        Ok(j.finish())
    }

    /// Screen and scrollback as plain text — what `seahelmd history` answers.
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
        if let Some(m) = self.master.lock().map_err(|_| anyhow::anyhow!("master poisoned"))?.as_ref() {
            m.resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 }).context("resize pty")?;
        }
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
    fn foreground_pid(&self) -> Option<u32> {
        let master = self.master.lock().ok()?;
        platform::foreground_pid(&**master.as_ref()?, self.pid)
    }

    /// Where the session is working: the foreground process's directory,
    /// then the program's, then what the shell said over OSC 7.
    pub fn cwd(&self) -> String {
        self.foreground_pid()
            .and_then(platform::process_cwd)
            .or_else(|| self.pid.and_then(platform::process_cwd))
            .or_else(|| {
                let pwd = self.inner.lock().ok().map(|g| g.terminal.pwd())?;
                (!pwd.is_empty()).then_some(pwd)
            })
            .unwrap_or_default()
    }

    /// What holds the terminal, by name: `claude`, `zsh`.
    pub fn command(&self) -> String {
        self.foreground_pid()
            .and_then(platform::process_name)
            .or_else(|| self.pid.and_then(platform::process_name))
            .unwrap_or_default()
    }

    pub fn is_finished(&self) -> bool {
        self.finished.load(Ordering::Acquire)
    }

    pub fn kill(&self) -> Result<()> {
        // The whole process group, as closing a terminal would: an agent's
        // children must not outlive the pane.
        if let Some(pid) = self.pid {
            platform::kill_tree(pid);
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

/// Whether the PTY is a Windows pseudoconsole, with its cursor-position
/// handshake (see the reader in `Session::spawn`).
const CONPTY: bool = cfg!(windows);

/// The bytes with every cursor position query (`CSI 6 n`) taken out.
fn without_cursor_queries(bytes: &[u8]) -> Cow<'_, [u8]> {
    const QUERY: &[u8] = b"\x1b[6n";
    if !bytes.windows(QUERY.len()).any(|w| w == QUERY) {
        return Cow::Borrowed(bytes);
    }
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at..].starts_with(QUERY) {
            at += QUERY.len();
        } else {
            out.push(bytes[at]);
            at += 1;
        }
    }
    Cow::Owned(out)
}

/// The cursor position reports (`CSI row ; col R`) among a run of replies.
fn cursor_reports(replies: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut at = 0;
    while at < replies.len() {
        if replies[at] == 0x1b && replies.get(at + 1) == Some(&b'[') {
            let mut end = at + 2;
            while end < replies.len() && (replies[end].is_ascii_digit() || replies[end] == b';') {
                end += 1;
            }
            if end < replies.len() {
                if replies[end] == b'R' {
                    out.extend_from_slice(&replies[at..=end]);
                }
                at = end + 1;
                continue;
            }
        }
        at += 1;
    }
    out
}

/// Just enough JSON to write a snapshot without a dependency.
struct Json(String);

impl Json {
    fn object() -> Self {
        Json(String::from("{"))
    }

    fn key(&mut self, k: &str) {
        if self.0.len() > 1 {
            self.0.push(',');
        }
        escape(k, &mut self.0);
        self.0.push(':');
    }

    fn raw(&mut self, k: &str, v: &str) {
        self.key(k);
        self.0.push_str(v);
    }

    fn num(&mut self, k: &str, v: i64) {
        self.raw(k, &v.to_string());
    }

    fn opt_num(&mut self, k: &str, v: Option<i64>) {
        match v {
            Some(v) => self.num(k, v),
            None => self.raw(k, "null"),
        }
    }

    fn boolean(&mut self, k: &str, v: bool) {
        self.raw(k, if v { "true" } else { "false" });
    }

    fn string(&mut self, k: &str, v: &str) {
        self.key(k);
        escape(v, &mut self.0);
    }

    fn opt_string(&mut self, k: &str, v: Option<&str>) {
        match v {
            Some(v) => self.string(k, v),
            None => self.raw(k, "null"),
        }
    }

    fn finish(mut self) -> String {
        self.0.push('}');
        self.0
    }
}

fn escape(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_queries_are_cut_and_cursor_reports_picked_out() {
        assert_eq!(&*without_cursor_queries(b"a\x1b[6nb\x1b[6n"), b"ab");
        assert!(matches!(without_cursor_queries(b"plain"), Cow::Borrowed(_)));
        // A DA1 answer and a palette answer around a cursor report.
        let replies = b"\x1b[?62;22c\x1b[12;40R\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\";
        assert_eq!(cursor_reports(replies), b"\x1b[12;40R");
        assert!(cursor_reports(b"\x1b[?62;22c").is_empty());
    }

    #[test]
    fn json_strings_are_escaped() {
        let mut j = Json::object();
        j.string("a", "q\"b\\s\nl\u{1}");
        j.num("n", 3);
        assert_eq!(j.finish(), r#"{"a":"q\"b\\s\nl\u0001","n":3}"#);
    }

    #[test]
    fn a_query_is_answered_and_reports_are_kept() {
        let mut sig = Signals::default();
        let r = sig.take(vec![Osc::ProgramStatus { body: b"?".to_vec(), bel: true }]);
        assert_eq!(r, format!("\x1b]7501;{}\x07", program_status::QUERY_REPLY).into_bytes());
        assert!(sig.take(vec![Osc::ProgramStatus { body: b"state=working:app=claude-code".to_vec(), bel: false }]).is_empty());
        assert_eq!(sig.program_seq, 1);
        assert_eq!(sig.program.live_root().unwrap().report.state, program_status::State::Working);
        // The same report again changes nothing a reader sees.
        sig.take(vec![Osc::ProgramStatus { body: b"state=working:app=claude-code".to_vec(), bel: false }]);
        assert_eq!(sig.program_seq, 1);
        sig.take(vec![Osc::Shell { mark: b'D', exit: Some(0) }]);
        assert!(sig.program.live_root().is_none());
        assert_eq!(sig.program_seq, 2);
    }
}
