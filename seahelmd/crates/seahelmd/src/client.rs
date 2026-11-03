//! Talking to a session's daemon: one-shot requests, and `attach`, which
//! turns the terminal it runs in into a window on the session.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};

use crate::platform::{self, RawTty, Stream};
use crate::proto::{self, Msg};

/// Ctrl-\ detaches.
const DETACH_KEY: u8 = 0x1c;

/// Where a session listens (see `platform::address`).
pub fn socket_path(name: &str) -> Result<PathBuf> {
    platform::address(name)
}

/// Whether a failed request means the daemon is gone (nothing listening
/// where it should be), as opposed to there but not answering.
pub fn is_gone(e: &anyhow::Error) -> bool {
    e.chain().filter_map(|c| c.downcast_ref::<std::io::Error>()).any(|io| {
        matches!(io.kind(), std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::NotFound)
    })
}

pub fn connect(name: &str) -> Result<Stream> {
    let path = socket_path(name)?;
    Stream::connect(&path).with_context(|| format!("no session {name}"))
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
    if Stream::connect(&path).is_ok() {
        return Ok(false);
    }
    platform::prepare()?;
    platform::remove_stale(&path);
    spawn_daemon(name, argv, hold)?;
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if Stream::connect(&path).is_ok() {
            return Ok(true);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    bail!("session {name} did not start; see {}", platform::log_path(name).display())
}

fn spawn_daemon(name: &str, argv: &[String], hold: Option<std::time::Duration>) -> Result<()> {
    let exe = std::env::current_exe()?;
    let log = std::fs::OpenOptions::new().create(true).append(true).open(platform::log_path(name))?;
    let mut cmd = Command::new(exe);
    cmd.arg("__serve");
    if let Some(hold) = hold {
        cmd.arg("--hold").arg(hold.as_secs_f64().to_string());
    }
    cmd.arg(name).arg("--").args(argv);
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(log);
    platform::spawn_detached(&mut cmd).context("spawn daemon")?;
    Ok(())
}

/// Attach this terminal to the session until it ends or Ctrl-\ is pressed.
pub fn attach(name: &str) -> Result<()> {
    let stream = connect(name)?;
    let mut sock_in = stream.try_clone()?;
    let mut sock_out = stream.try_clone()?;
    let (cols, rows) = platform::tty_size();
    proto::write(&mut sock_out, &Msg::Attach { cols, rows })?;
    let _raw = RawTty::enter();

    // Session → screen. The end of the session ends the client.
    std::thread::spawn(move || {
        let mut out = platform::stdout_bytes();
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
                    RawTty::restore();
                    eprintln!("seahelmd: {e}");
                    std::process::exit(1);
                }
                Ok(Some(_)) => {}
                Ok(None) | Err(_) => {
                    RawTty::restore();
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
                let now = platform::tty_size();
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
    let mut stdin = platform::stdin_bytes();
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
    RawTty::restore();
    Ok(())
}
