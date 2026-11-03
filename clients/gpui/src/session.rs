//! One seahelmd session, attached: the socket, the grid the session's output
//! is parsed into, and the thread that does the parsing.
//!
//! The parse happens off the UI thread, as the bytes arrive; the UI only
//! takes the changed rows when it draws. Between the two sits one lock, held
//! by the reader for a parse and by the UI for `View::begin`.

use std::io::Write;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{bail, Context, Result};
use futures::channel::mpsc;
use keep_vt::osc_scan::{Osc, Scanner};
use keep_vt::program_status::{self, Command as ProgramCommand};
use keep_vt::{Facts, Terminal};
use seahelmd::proto::{self, Msg};

use crate::theme;

/// What the reader and the UI share.
pub struct Grid {
    pub terminal: Terminal,
    /// Bumped whenever `terminal` is replaced (a repaint), so a renderer
    /// knows its dirty tracking no longer applies.
    pub generation: u64,
    pub ended: bool,
    pub title: String,
}

pub struct Session {
    pub name: String,
    pub grid: Arc<Mutex<Grid>>,
    writer: Arc<Mutex<crate::platform::Stream>>,
    size: Mutex<(u16, u16)>,
    /// Bytes of output parsed so far, for the stats line.
    pub bytes_in: Arc<AtomicU64>,
    /// Whole-screen repaints received: the daemon's answer to a client that
    /// fell behind.
    pub repaints: Arc<AtomicU64>,
    /// Set by the reader when it has woken the UI, cleared by the UI before
    /// it reads: output in between wakes it once, not once per chunk.
    pending: Arc<AtomicBool>,
}

/// Where the seahelmd binary is: `$SEAHELMD_BIN`, the one built beside this
/// client, then `seahelmd` on PATH.
pub fn daemon_binary() -> PathBuf {
    if let Some(bin) = std::env::var_os("SEAHELMD_BIN") {
        return PathBuf::from(bin);
    }
    let built = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../seahelmd/target/release")
        .join(format!("seahelmd{}", std::env::consts::EXE_SUFFIX));
    if built.exists() {
        return built;
    }
    PathBuf::from("seahelmd")
}

/// Make sure the session exists: on `cmd` when given (held until we attach,
/// so it starts at our size), on the user's shell otherwise.
pub fn ensure(name: &str, cmd: &[String]) -> Result<()> {
    ensure_in(name, cmd, None)
}

/// `ensure`, the session started in `cwd`.
pub fn ensure_in(name: &str, cmd: &[String], cwd: Option<&str>) -> Result<()> {
    if seahelmd::client::connect(name).is_ok() {
        return Ok(());
    }
    let mut c = Command::new(daemon_binary());
    if let Some(dir) = cwd {
        c.current_dir(dir);
    }
    if cmd.is_empty() {
        c.arg("run").arg(name);
    } else {
        c.args(["new", "--hold", "10", name, "--"]).args(cmd);
    }
    // The grid draws truecolour; say so to whatever runs inside.
    c.env("TERM", "xterm-256color").env("COLORTERM", "truecolor");
    c.env("SEAHELMD_FACTS", theme::facts_env());
    let status = c.status().with_context(|| format!("run {}", daemon_binary().display()))?;
    if !status.success() {
        bail!("seahelmd could not start session {name}");
    }
    Ok(())
}

/// Resident memory of the session's program and everything under it.
/// Read from `ps`, so Unix only for now.
#[cfg(unix)]
pub fn memory(name: &str) -> Option<u64> {
    let Ok(Msg::Text(info)) = seahelmd::client::request(name, &Msg::Info) else { return None };
    let root: u32 = info.split('\t').find_map(|f| f.strip_prefix("pid="))?.parse().ok()?;
    let out = Command::new("ps").args(["-A", "-o", "pid=,ppid=,rss="]).output().ok()?;
    let table: Vec<(u32, u32, u64)> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let mut it = l.split_whitespace().filter_map(|n| n.parse::<u64>().ok());
            Some((it.next()? as u32, it.next()? as u32, it.next()?))
        })
        .collect();
    let mut total = 0u64;
    let mut stack = vec![root];
    while let Some(pid) = stack.pop() {
        for &(p, pp, rss) in &table {
            if p == pid {
                total += rss * 1024;
            }
            if pp == pid {
                stack.push(p);
            }
        }
    }
    Some(total)
}

#[cfg(not(unix))]
pub fn memory(_name: &str) -> Option<u64> {
    None
}

fn new_terminal(cols: u16, rows: u16) -> Result<Terminal> {
    let mut t = Terminal::new(cols, rows).map_err(|e| anyhow::anyhow!("terminal: {e}"))?;
    t.set_scrollback_limit(16 << 20).map_err(|e| anyhow::anyhow!("scrollback: {e}"))?;
    // Attached, the daemon hands every question to us: this grid answers as
    // the terminal the user is looking at.
    t.act_as_terminal(Facts {
        foreground: Some(theme::FG),
        background: Some(theme::BG),
        cursor: Some(theme::CURSOR),
        palette: Some(theme::palette()),
        dark: Some(true),
        ..Facts::default()
    })
    .map_err(|e| anyhow::anyhow!("terminal: {e}"))?;
    Ok(t)
}

impl Session {
    /// Attach at this size. `wake` is told, at most once per drawn frame,
    /// that there is something new to draw.
    pub fn attach(name: &str, cols: u16, rows: u16, wake: mpsc::UnboundedSender<()>) -> Result<Arc<Self>> {
        let stream = seahelmd::client::connect(name)?;
        // Buffered: one syscall brings in many frames when output is heavy.
        let mut reader = std::io::BufReader::with_capacity(256 * 1024, stream.try_clone()?);
        let writer = Arc::new(Mutex::new(stream));
        proto::write(&mut *writer.lock().unwrap(), &Msg::Attach { cols, rows })?;

        let grid = Arc::new(Mutex::new(Grid {
            terminal: new_terminal(cols, rows)?,
            generation: 0,
            ended: false,
            title: String::new(),
        }));
        let session = Arc::new(Self {
            name: name.to_string(),
            grid: Arc::clone(&grid),
            writer: Arc::clone(&writer),
            size: Mutex::new((cols, rows)),
            bytes_in: Arc::new(AtomicU64::new(0)),
            repaints: Arc::new(AtomicU64::new(0)),
            pending: Arc::new(AtomicBool::new(false)),
        });

        let pending = Arc::clone(&session.pending);
        let me = Arc::downgrade(&session);
        let bytes_in = Arc::clone(&session.bytes_in);
        let repaints = Arc::clone(&session.repaints);
        std::thread::Builder::new().name("seahelm-gpui-reader".into()).spawn(move || {
            let notify = |pending: &AtomicBool| {
                if !pending.swap(true, Ordering::AcqRel) {
                    let _ = wake.unbounded_send(());
                }
            };
            // OSC 7501 is not the grid's: its support query is answered
            // here, as Ghostty's patch answers it in the macOS app. Claude
            // Code only reports program status to a terminal that answers.
            let mut scanner = Scanner::new();
            loop {
                let msg = match proto::read(&mut reader) {
                    Ok(Some(m)) => m,
                    _ => break,
                };
                let replies = {
                    let Ok(mut g) = grid.lock() else { break };
                    match msg {
                        Msg::Repaint(data) => {
                            repaints.fetch_add(1, Ordering::Relaxed);
                            // A handover fed to a fresh terminal is the
                            // terminal it came from.
                            let (cols, rows) = me.upgrade().map(|s| *s.size.lock().unwrap()).unwrap_or((80, 24));
                            let Ok(mut fresh) = new_terminal(cols, rows) else { break };
                            fresh.write(&data);
                            let _ = fresh.take_events();
                            g.terminal = fresh;
                            g.generation += 1;
                            Vec::new()
                        }
                        Msg::Output(data) => {
                            bytes_in.fetch_add(data.len() as u64, Ordering::Relaxed);
                            // In order: each 7501 query is answered after
                            // whatever the grid answers before it (see
                            // seahelmd's session reader for why).
                            let mut replies = Vec::new();
                            let mut titled = false;
                            let mut at = 0;
                            for (end, osc) in scanner.feed(&data) {
                                let Osc::ProgramStatus { body, bel } = osc else { continue };
                                if program_status::parse(&body) != Some(ProgramCommand::Query) {
                                    continue;
                                }
                                g.terminal.write(&data[at..end]);
                                let mut events = g.terminal.take_events();
                                titled |= events.title;
                                replies.append(&mut events.replies);
                                replies.extend_from_slice(b"\x1b]7501;");
                                replies.extend_from_slice(program_status::QUERY_REPLY.as_bytes());
                                replies.extend_from_slice(if bel { b"\x07" } else { b"\x1b\\" });
                                at = end;
                            }
                            g.terminal.write(&data[at..]);
                            let mut events = g.terminal.take_events();
                            replies.append(&mut events.replies);
                            if titled || events.title {
                                g.title = g.terminal.title();
                            }
                            replies
                        }
                        Msg::Ended => {
                            g.ended = true;
                            Vec::new()
                        }
                        Msg::Error(e) => {
                            eprintln!("seahelmd: {e}");
                            Vec::new()
                        }
                        _ => Vec::new(),
                    }
                };
                if !replies.is_empty() {
                    if let Ok(mut w) = writer.lock() {
                        let _ = proto::write(&mut *w, &Msg::Input(replies));
                    }
                }
                notify(&pending);
            }
            if let Ok(mut g) = grid.lock() {
                g.ended = true;
            }
            notify(&pending);
        })?;
        Ok(session)
    }

    /// The UI is about to read the grid: the next output wakes it again.
    pub fn take_wake(&self) {
        self.pending.store(false, Ordering::Release);
    }

    pub fn send(&self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        if let Ok(mut w) = self.writer.lock() {
            let _ = proto::write(&mut *w, &Msg::Input(bytes.to_vec()));
            let _ = w.flush();
        }
    }

    pub fn size(&self) -> (u16, u16) {
        *self.size.lock().unwrap()
    }

    /// The pane is now this many cells: the grid and the daemon both.
    pub fn resize(&self, cols: u16, rows: u16) {
        {
            let mut size = self.size.lock().unwrap();
            if *size == (cols, rows) || cols == 0 || rows == 0 {
                return;
            }
            *size = (cols, rows);
        }
        if let Ok(mut g) = self.grid.lock() {
            let _ = g.terminal.resize(cols, rows);
        }
        if let Ok(mut w) = self.writer.lock() {
            let _ = proto::write(&mut *w, &Msg::Resize { cols, rows });
        }
    }
}

