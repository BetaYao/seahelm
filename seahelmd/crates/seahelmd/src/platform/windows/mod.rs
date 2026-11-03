//! Windows: named pipes, detached processes, process trees, the console.
//!
//! The pipe transport, reading another process's name and working directory,
//! and the console come from Keep's Windows port (`pipe`, `winproc`,
//! `console`, each with its origin at the top); the rest is std.

mod console;
mod pipe;
mod winproc;

use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::Mutex;

use anyhow::{bail, Result};

pub use pipe::{Listener, Stream};

const PIPE_PREFIX: &str = r"\\.\pipe\";
/// The longest pipe name Windows takes, prefix included.
const MAX_PIPE_NAME: usize = 256;

const DETACHED_PROCESS: u32 = 0x0000_0008;
const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// The pipe-name prefix of this user's sessions: `seahelmd-<SID>-`, or what
/// `$SEAHELMD_DIR` folds to, so two test runs given two directories still
/// meet only their own daemons. The SID rather than the user name, as Keep
/// does: it is what the pipe's DACL admits, and two accounts cannot share it.
fn namespace() -> String {
    let tag = match std::env::var_os("SEAHELMD_DIR") {
        Some(dir) => dir.to_string_lossy().into_owned(),
        None => pipe::current_user_sid_string()
            .or_else(|_| std::env::var("USERNAME"))
            .unwrap_or_else(|_| "default".into()),
    };
    let folded: String = tag.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' }).collect();
    format!("seahelmd-{folded}-")
}

/// The pipe a session listens on.
pub fn address(name: &str) -> Result<PathBuf> {
    super::check_name(name)?;
    let pipe = format!("{PIPE_PREFIX}{}{name}", namespace());
    if pipe.len() > MAX_PIPE_NAME {
        bail!("session name too long for a pipe name: {name}");
    }
    Ok(PathBuf::from(pipe))
}

/// Where logs go: there is no socket directory to put them beside.
fn log_dir() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    base.join("seahelm").join("seahelmd")
}

pub fn prepare() -> Result<()> {
    std::fs::create_dir_all(log_dir())?;
    Ok(())
}

/// A pipe goes when the last handle to it closes: nothing to clean up.
pub fn remove_stale(_address: &Path) {}

pub fn log_path(name: &str) -> PathBuf {
    log_dir().join(format!("{name}.log"))
}

/// Every session with a pipe, sorted. The pipe namespace lists like a
/// directory.
pub fn session_names() -> Vec<String> {
    let prefix = namespace();
    let Ok(entries) = std::fs::read_dir(PIPE_PREFIX) else { return Vec::new() };
    let mut names: Vec<String> = entries
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .filter_map(|n| n.strip_prefix(&prefix).map(str::to_string))
        .collect();
    names.sort();
    names
}

/// Start the daemon so that it outlives whoever started it: no console of
/// its own, its own process group, and out of the starter's job — a client
/// run inside a job (an IDE's terminal, a CI runner) would otherwise take
/// every session down when it closes. A job that forbids breaking away
/// refuses the first attempt; the daemon then starts inside it.
pub fn spawn_detached(cmd: &mut Command) -> io::Result<Child> {
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB);
    match cmd.spawn() {
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => {
            cmd.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
            cmd.spawn()
        }
        other => other,
    }
}

/// Whoever holds the terminal. Windows has no foreground process group; the
/// process tree answers instead: the program's newest child while it runs
/// one, the program itself while it waits (see `winproc::foreground`).
pub fn foreground_pid(_master: &dyn portable_pty::MasterPty, program: Option<u32>) -> Option<u32> {
    let program = program?;
    Some(winproc::foreground(program).unwrap_or(program))
}

/// Run `then` on a thread of its own once the program has exited (see
/// `Session::spawn`: a pseudoconsole has to be closed for its output to end).
pub fn on_exit(pid: u32, then: impl FnOnce() + Send + 'static) {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{OpenProcess, WaitForSingleObject, INFINITE, PROCESS_SYNCHRONIZE};
    let _ = std::thread::Builder::new().name("seahelmd-exit".into()).spawn(move || {
        let process = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, pid) };
        if !process.is_null() {
            unsafe {
                WaitForSingleObject(process, INFINITE);
                CloseHandle(process);
            }
        }
        then();
    });
}

/// End the program and its whole tree: what closing a terminal does on Unix,
/// and what portable-pty's kill (the program alone) does not.
pub fn kill_tree(pid: u32) {
    use std::os::windows::process::CommandExt;
    let _ = Command::new("taskkill")
        .args(["/PID", &pid.to_string(), "/T", "/F"])
        .creation_flags(CREATE_NO_WINDOW)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

/// A process's working directory, read from its PEB (`winproc`).
pub fn process_cwd(pid: u32) -> Option<String> {
    winproc::process_cwd(pid)
}

/// A process's name: the image, or what a launcher (`cmd /c`, `node`) ran.
pub fn process_name(pid: u32) -> Option<String> {
    winproc::process_name(pid)
}

/// The attach CLI's console in raw VT mode, put back when restored.
pub struct RawTty;

static SAVED: Mutex<Option<console::Modes>> = Mutex::new(None);

impl RawTty {
    pub fn enter() -> RawTty {
        if let Ok(mut saved) = SAVED.lock() {
            if saved.is_none() {
                *saved = Some(console::enter());
            }
        }
        RawTty
    }

    /// Put the console back (dropping the saved modes restores them), and
    /// turn off win32-input-mode, which ConPTY asks the attached console for
    /// through its output: the shell this returns to reads keys plainly.
    pub fn restore() {
        if let Ok(mut saved) = SAVED.lock() {
            if saved.take().is_some() {
                let mut out = console::Output::stdout();
                let _ = out.write_all(b"\x1b[?9001l");
            }
        }
    }
}

impl Drop for RawTty {
    fn drop(&mut self) {
        RawTty::restore();
    }
}

/// The attach CLI's window, in cells; 80x24 when it cannot be read.
pub fn tty_size() -> (u16, u16) {
    use windows_sys::Win32::System::Console::{GetConsoleScreenBufferInfo, GetStdHandle, CONSOLE_SCREEN_BUFFER_INFO, STD_OUTPUT_HANDLE};
    unsafe {
        let mut info: CONSOLE_SCREEN_BUFFER_INFO = std::mem::zeroed();
        if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &mut info) != 0 {
            let cols = (info.srWindow.Right - info.srWindow.Left + 1).max(1) as u16;
            let rows = (info.srWindow.Bottom - info.srWindow.Top + 1).max(1) as u16;
            return (cols, rows);
        }
    }
    (80, 24)
}

/// Standard input as the bytes a terminal writes: the std reader takes
/// Ctrl+Z at the start of a read for the end of input.
pub fn stdin_bytes() -> Box<dyn Read + Send> {
    Box::new(console::Input::stdin())
}

/// Standard output taking any bytes: the std console writer refuses bytes
/// that are not UTF-8, and a program printing a binary file would end the
/// attach.
pub fn stdout_bytes() -> Box<dyn Write + Send> {
    Box::new(console::Output::stdout())
}
