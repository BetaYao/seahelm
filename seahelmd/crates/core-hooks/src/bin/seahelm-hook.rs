//! `seahelm-hook [<source>]`: the command hook agents run on every
//! lifecycle event.
//!
//! Reads the hook JSON on stdin, tags it with the pane it ran in
//! (`SEAHELM_PANE_ID`, else `SEAHELMD_SESSION`) and the source it was
//! invoked with, and sends it as one JSON-RPC `hook` line to
//! `$SEAHELM_SOCKET_PATH` (default `~/.config/seahelm/seahelm.sock`; a
//! named pipe on Windows). See `seahelm_core_hooks::wire`.
//!
//! It replaces the `/bin/sh` + `nc -U` script and keeps that script's
//! contract with the agent: fire-and-forget, never more than two seconds,
//! always exit 0, and never a byte on stdout — Claude Code reads a command
//! hook's stdout as a decision, and Stop is observation-only. A missing
//! socket or a seahelm that is not running is not the agent's problem.

use std::io::Read;
use std::path::Path;

use seahelm_core_hooks::wire;

fn main() {
    // Whatever happens below — a hung read, a server that never answers, a
    // panic — the agent gets its exit 0 and moves on.
    std::thread::spawn(|| {
        std::thread::sleep(wire::TIMEOUT);
        std::process::exit(0);
    });
    let _ = std::panic::catch_unwind(run);
    std::process::exit(0);
}

fn run() {
    let mut payload = Vec::new();
    if std::io::stdin().read_to_end(&mut payload).is_err() {
        return;
    }
    let payload = String::from_utf8_lossy(&payload);
    let source = std::env::args().nth(1);
    let pane = wire::pane_id(
        std::env::var("SEAHELM_PANE_ID").ok().as_deref(),
        std::env::var("SEAHELMD_SESSION").ok().as_deref(),
    );
    let Some(params) = wire::splice(&payload, pane.as_deref(), source.as_deref()) else { return };
    let _ = send(&wire::socket_path_from_env(), wire::request_line(params).as_bytes());
}

/// Write the line, close our half, and wait (bounded) for the server's
/// acknowledgement — the response itself is discarded.
#[cfg(unix)]
fn send(path: &Path, line: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::net::UnixStream;
    let mut stream = UnixStream::connect(path)?;
    stream.set_write_timeout(Some(wire::TIMEOUT))?;
    stream.set_read_timeout(Some(wire::TIMEOUT))?;
    stream.write_all(line)?;
    stream.shutdown(std::net::Shutdown::Write)?;
    await_answer(&mut stream);
    Ok(())
}

/// A named pipe opens like a file. A pipe has no half-close to tell the
/// server we are done, so read until its one-line answer (or its close, or
/// the watchdog) and then drop the handle.
#[cfg(windows)]
fn send(path: &Path, line: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut pipe = std::fs::OpenOptions::new().read(true).write(true).open(path)?;
    pipe.write_all(line)?;
    pipe.flush()?;
    await_answer(&mut pipe);
    Ok(())
}

/// Read until the server's one-line answer, its close, or an error.
#[cfg(any(unix, windows))]
fn await_answer(conn: &mut impl Read) {
    let mut buf = [0u8; 512];
    while let Ok(n) = conn.read(&mut buf) {
        if n == 0 || buf[..n].contains(&b'\n') {
            return;
        }
    }
}

#[cfg(not(any(unix, windows)))]
fn send(_path: &Path, _line: &[u8]) -> std::io::Result<()> {
    Ok(())
}
