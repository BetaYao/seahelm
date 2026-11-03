//! Talking to a session's daemon: one-shot requests, and `attach`, which
//! turns the terminal it runs in into a window on the session.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};

use crate::proto::{self, Msg};

/// Ctrl-\ detaches, as in zmx.
const DETACH_KEY: u8 = 0x1c;

/// Where the sockets live: `$SEAHELMD_DIR`, else `/tmp/seahelmd-<uid>`.
/// Short on purpose — a unix socket path has about 104 bytes, and session
/// names run long.
pub fn socket_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("SEAHELMD_DIR") {
        return PathBuf::from(dir);
    }
    PathBuf::from(format!("/tmp/seahelmd-{}", unsafe { libc::getuid() }))
}

pub fn socket_path(name: &str) -> Result<PathBuf> {
    if name.is_empty() || name.contains('/') || name.starts_with('.') {
        bail!("bad session name {name:?}");
    }
    let path = socket_dir().join(name);
    if path.as_os_str().len() > 100 {
        bail!("session name too long for a socket path: {name}");
    }
    Ok(path)
}

/// Whether a failed request means the daemon is gone (nothing listening on
/// its socket), as opposed to there but not answering.
pub fn is_gone(e: &anyhow::Error) -> bool {
    e.chain().filter_map(|c| c.downcast_ref::<std::io::Error>()).any(|io| {
        matches!(io.kind(), std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::NotFound)
    })
}

pub fn connect(name: &str) -> Result<UnixStream> {
    let path = socket_path(name)?;
    UnixStream::connect(&path).with_context(|| format!("no session {name}"))
}

/// One request, one answer.
pub fn request(name: &str, msg: &Msg) -> Result<Msg> {
    let mut stream = connect(name)?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    proto::write(&mut stream, msg)?;
    match proto::read(&mut stream)? {
        Some(Msg::Error(e)) => bail!("{e}"),
        Some(reply) => Ok(reply),
        None => bail!("session {name} hung up"),
    }
}

/// Start the session's daemon unless it is already running. True when it
/// was started here.
pub fn ensure(name: &str, argv: &[String]) -> Result<bool> {
    ensure_held(name, argv, None)
}

/// `ensure`, with the program held until the first attach (see `daemon::Lazy`).
pub fn ensure_held(name: &str, argv: &[String], hold: Option<std::time::Duration>) -> Result<bool> {
    let path = socket_path(name)?;
    if UnixStream::connect(&path).is_ok() {
        return Ok(false);
    }
    let dir = socket_dir();
    std::fs::create_dir_all(&dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    }
    // A socket nobody answers on is a daemon that died without cleaning up.
    let _ = std::fs::remove_file(&path);
    spawn_daemon(&path, name, argv, hold)?;
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if UnixStream::connect(&path).is_ok() {
            return Ok(true);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    bail!("session {name} did not start; see {}", log_path(&path).display())
}

fn log_path(socket: &Path) -> PathBuf {
    socket.with_extension("log")
}

fn spawn_daemon(socket: &Path, name: &str, argv: &[String], hold: Option<std::time::Duration>) -> Result<()> {
    use std::os::unix::process::CommandExt;
    let exe = std::env::current_exe()?;
    let log = std::fs::OpenOptions::new().create(true).append(true).open(log_path(socket))?;
    let mut cmd = Command::new(exe);
    cmd.arg("__serve");
    if let Some(hold) = hold {
        cmd.arg("--hold").arg(hold.as_secs_f64().to_string());
    }
    cmd.arg(name).arg("--").args(argv);
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(log);
    // Its own session, so closing the terminal that started it — the very
    // thing it exists to survive — sends it nothing.
    unsafe {
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    cmd.spawn().context("spawn daemon")?;
    Ok(())
}

static SAVED: OnceLock<libc::termios> = OnceLock::new();

fn restore_tty() {
    if let Some(t) = SAVED.get() {
        unsafe { libc::tcsetattr(0, libc::TCSANOW, t) };
    }
}

fn raw_tty() {
    unsafe {
        let mut t: libc::termios = std::mem::zeroed();
        if libc::tcgetattr(0, &mut t) != 0 {
            return;
        }
        let _ = SAVED.set(t);
        libc::cfmakeraw(&mut t);
        libc::tcsetattr(0, libc::TCSANOW, &t);
    }
}

fn tty_size() -> (u16, u16) {
    unsafe {
        let mut ws: libc::winsize = std::mem::zeroed();
        if libc::ioctl(0, libc::TIOCGWINSZ, &mut ws) == 0 && ws.ws_col > 0 {
            (ws.ws_col, ws.ws_row)
        } else {
            (80, 24)
        }
    }
}

/// Attach this terminal to the session until it ends or Ctrl-\ is pressed.
pub fn attach(name: &str) -> Result<()> {
    let stream = connect(name)?;
    let mut sock_in = stream.try_clone()?;
    let mut sock_out = stream.try_clone()?;
    let (cols, rows) = tty_size();
    proto::write(&mut sock_out, &Msg::Attach { cols, rows })?;
    raw_tty();

    // Session → screen. The end of the session ends the client.
    std::thread::spawn(move || {
        let mut out = std::io::stdout().lock();
        loop {
            match proto::read(&mut sock_in) {
                Ok(Some(Msg::Repaint(data))) => {
                    // A repaint is the whole screen from the top, not more
                    // output after whatever was showing.
                    let _ = out.write_all(b"\x1b[H\x1b[2J");
                    let _ = out.write_all(&data);
                    let _ = out.flush();
                }
                Ok(Some(Msg::Output(data))) => {
                    let _ = out.write_all(&data);
                    let _ = out.flush();
                }
                Ok(Some(Msg::Error(e))) => {
                    restore_tty();
                    eprintln!("seahelmd: {e}");
                    std::process::exit(1);
                }
                Ok(Some(_)) => {}
                Ok(None) | Err(_) => {
                    restore_tty();
                    std::process::exit(0);
                }
            }
        }
    });

    // The window's size, polled: cheaper to reason about than a signal
    // handler, and a 100ms lag on a resize is not one anybody sees.
    {
        let mut sock = stream.try_clone()?;
        std::thread::spawn(move || {
            let mut last = (cols, rows);
            loop {
                std::thread::sleep(Duration::from_millis(100));
                let now = tty_size();
                if now != last {
                    last = now;
                    if proto::write(&mut sock, &Msg::Resize { cols: now.0, rows: now.1 }).is_err() {
                        break;
                    }
                }
            }
        });
    }

    // Keyboard → session.
    let mut stdin = std::io::stdin().lock();
    let mut buf = [0u8; 4096];
    loop {
        let n = match stdin.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        if let Some(at) = buf[..n].iter().position(|&b| b == DETACH_KEY) {
            if at > 0 {
                let _ = proto::write(&mut sock_out, &Msg::Input(buf[..at].to_vec()));
            }
            break;
        }
        if proto::write(&mut sock_out, &Msg::Input(buf[..n].to_vec())).is_err() {
            break;
        }
    }
    restore_tty();
    Ok(())
}
