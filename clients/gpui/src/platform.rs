//! What differs between macOS, Linux and Windows for this client: where the
//! sockets are, how to reach them, the home directory, and the keys a
//! terminal app keeps for itself. The transport is seahelmd's own (a Unix
//! socket, or a named pipe on Windows), so the client and the daemons agree
//! on it by construction.

use std::io;
use std::path::{Path, PathBuf};

pub use seahelmd::platform::Stream;

/// macOS draws the window's controls itself (the traffic lights) inside a
/// transparent titlebar; elsewhere the client draws them.
pub const MAC: bool = cfg!(target_os = "macos");

/// `$HOME`, else `%USERPROFILE%` (Windows sets no HOME).
pub fn home() -> PathBuf {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_default()
}

/// `~/.config/seahelm`, the same on every platform (seahelm-core's too).
pub fn config_dir() -> PathBuf {
    home().join(".config").join("seahelm")
}

#[cfg(windows)]
fn user() -> String {
    std::env::var("USERNAME").ok().filter(|u| !u.is_empty()).unwrap_or_else(|| "default".into())
}

/// seahelm-core's socket: `$SEAHELM_CORE_SOCKET`, else what `seahelm-core
/// serve` listens on (`seahelm-core`'s `rpc::core_socket`).
pub fn core_socket() -> PathBuf {
    if let Some(p) = std::env::var_os("SEAHELM_CORE_SOCKET") {
        return PathBuf::from(p);
    }
    #[cfg(windows)]
    return PathBuf::from(format!(r"\\.\pipe\seahelm-core-{}", user()));
    #[cfg(not(windows))]
    config_dir().join("core.sock")
}

/// A companion binary (`seahelmd`, `seahelm-core`): `$<env>`, else the one
/// beside this executable (how a packaged client ships them), else the
/// one cargo built in this checkout, else whatever PATH finds.
pub fn tool(name: &str, env: &str) -> PathBuf {
    if let Some(p) = std::env::var_os(env).filter(|p| !p.is_empty()) {
        return PathBuf::from(p);
    }
    let exe = format!("{name}{}", std::env::consts::EXE_SUFFIX);
    if let Some(beside) = std::env::current_exe().ok().and_then(|e| e.parent().map(|d| d.join(&exe))) {
        if beside.exists() {
            return beside;
        }
    }
    // This checkout's own seahelmd/target, not $CARGO_TARGET_DIR: a target
    // dir shared between checkouts holds whichever one built last.
    let target = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../seahelmd/target");
    for profile in ["release", "debug"] {
        let built = target.join(profile).join(&exe);
        if built.exists() {
            return built;
        }
    }
    PathBuf::from(exe)
}

pub fn connect(path: &Path) -> io::Result<Stream> {
    Stream::connect(path)
}

/// The app's shortcut modifier: cmd on macOS. Elsewhere ctrl belongs to the
/// terminal, so the app's shortcuts are ctrl+shift (copy, paste), as in
/// every Linux and Windows terminal.
pub fn is_app_shortcut(m: &gpui::Modifiers) -> bool {
    if MAC {
        m.platform
    } else {
        m.control && m.shift && !m.alt && !m.platform
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_shortcuts_leave_the_terminal_its_keys() {
        let ctrl = gpui::Modifiers { control: true, ..Default::default() };
        let ctrl_shift = gpui::Modifiers { control: true, shift: true, ..Default::default() };
        let cmd = gpui::Modifiers { platform: true, ..Default::default() };
        assert!(!is_app_shortcut(&ctrl), "ctrl is the terminal's");
        if MAC {
            assert!(is_app_shortcut(&cmd));
            assert!(!is_app_shortcut(&ctrl_shift));
        } else {
            assert!(is_app_shortcut(&ctrl_shift));
        }
    }
}
