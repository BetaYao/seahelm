//! Unix: sockets in a private directory, `setsid`, process groups, termios.

use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::OnceLock;

use anyhow::{bail, Result};

pub use std::os::unix::net::{UnixListener as Listener, UnixStream as Stream};

/// Where the sockets live: `$SEAHELMD_DIR`, else `/tmp/seahelmd-<uid>`.
/// Short on purpose — a unix socket path has about 104 bytes, and session
/// names run long.
pub fn socket_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("SEAHELMD_DIR") {
        return PathBuf::from(dir);
    }
    PathBuf::from(format!("/tmp/seahelmd-{}", unsafe { libc::getuid() }))
}

/// The socket a session listens on.
pub fn address(name: &str) -> Result<PathBuf> {
    super::check_name(name)?;
    let path = socket_dir().join(name);
    if path.as_os_str().len() > 100 {
        bail!("session name too long for a socket path: {name}");
    }
    Ok(path)
}

/// Make the socket directory, owner-only, before a daemon binds in it.
pub fn prepare() -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let dir = socket_dir();
    std::fs::create_dir_all(&dir)?;
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}

/// A socket nobody answers on is a daemon that died without cleaning up;
/// it has to go before a new daemon can bind there.
pub fn remove_stale(address: &Path) {
    let _ = std::fs::remove_file(address);
}

/// Where a session's daemon writes what it has to say: beside its socket.
pub fn log_path(name: &str) -> PathBuf {
    socket_dir().join(format!("{name}.log"))
}

/// Every session with a socket, sorted.
pub fn session_names() -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(socket_dir()) else { return Vec::new() };
    let mut names: Vec<String> = entries
        .flatten()
        .filter(|e| e.file_type().map(|t| !t.is_file() && !t.is_dir()).unwrap_or(false))
        .filter_map(|e| e.file_name().into_string().ok())
        .collect();
    names.sort();
    names
}

/// Start the daemon in a session of its own, so closing the terminal that
/// started it — the very thing it exists to survive — sends it nothing.
pub fn spawn_detached(cmd: &mut Command) -> std::io::Result<Child> {
    use std::os::unix::process::CommandExt;
    unsafe {
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    cmd.spawn()
}

/// Whoever holds the terminal: its foreground process group's leader (the
/// running command, or the shell waiting at its prompt).
pub fn foreground_pid(master: &dyn portable_pty::MasterPty, _program: Option<u32>) -> Option<u32> {
    master.process_group_leader().and_then(|p| u32::try_from(p).ok())
}

/// Run `then` once the program has exited. Nothing to do on Unix: the
/// last process leaving the PTY is its end of file.
pub fn on_exit(_pid: u32, _then: impl FnOnce() + Send + 'static) {}

/// End the program and everything it started, as closing a terminal would:
/// an agent's children must not outlive the pane.
pub fn kill_tree(pid: u32) {
    unsafe { libc::killpg(pid as i32, libc::SIGHUP) };
}

#[cfg(target_os = "macos")]
pub fn process_cwd(pid: u32) -> Option<String> {
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
    let read = unsafe {
        libc::proc_pidinfo(pid as i32, libc::PROC_PIDVNODEPATHINFO, 0, &mut info as *mut _ as *mut libc::c_void, size)
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
pub fn process_cwd(pid: u32) -> Option<String> {
    std::fs::read_link(format!("/proc/{pid}/cwd"))
        .ok()
        .and_then(|p| p.into_os_string().into_string().ok())
        .filter(|p| !p.is_empty())
}

#[cfg(target_os = "macos")]
pub fn process_name(pid: u32) -> Option<String> {
    const MAX_PATH: usize = 4 * 1024;
    let mut buf = vec![0u8; MAX_PATH];
    let written = unsafe { libc::proc_pidpath(pid as i32, buf.as_mut_ptr() as *mut libc::c_void, MAX_PATH as u32) };
    if written <= 0 {
        return None;
    }
    buf.truncate(written as usize);
    let path = String::from_utf8(buf).ok()?;
    let name = path.rsplit('/').next()?.to_owned();
    (!name.is_empty()).then_some(name)
}

#[cfg(not(target_os = "macos"))]
pub fn process_name(pid: u32) -> Option<String> {
    let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).ok()?;
    let name = comm.trim().to_owned();
    (!name.is_empty()).then_some(name)
}

/// The attach CLI's terminal, put in raw mode for as long as this lives.
pub struct RawTty;

static SAVED: OnceLock<libc::termios> = OnceLock::new();

impl RawTty {
    pub fn enter() -> RawTty {
        unsafe {
            let mut t: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(0, &mut t) == 0 {
                let _ = SAVED.set(t);
                libc::cfmakeraw(&mut t);
                libc::tcsetattr(0, libc::TCSANOW, &t);
            }
        }
        RawTty
    }

    /// Put the terminal back. Also what `Drop` does; callable from a thread
    /// that ends the process without unwinding to the guard.
    pub fn restore() {
        if let Some(t) = SAVED.get() {
            unsafe { libc::tcsetattr(0, libc::TCSANOW, t) };
        }
    }
}

impl Drop for RawTty {
    fn drop(&mut self) {
        RawTty::restore();
    }
}

/// Standard input, as the bytes the terminal writes.
pub fn stdin_bytes() -> Box<dyn std::io::Read + Send> {
    Box::new(std::io::stdin())
}

/// Standard output, taking any bytes.
pub fn stdout_bytes() -> Box<dyn std::io::Write + Send> {
    Box::new(std::io::stdout())
}

/// The attach CLI's window, in cells; 80x24 when it cannot be read.
pub fn tty_size() -> (u16, u16) {
    unsafe {
        let mut ws: libc::winsize = std::mem::zeroed();
        if libc::ioctl(0, libc::TIOCGWINSZ, &mut ws) == 0 && ws.ws_col > 0 {
            (ws.ws_col, ws.ws_row)
        } else {
            (80, 24)
        }
    }
}
