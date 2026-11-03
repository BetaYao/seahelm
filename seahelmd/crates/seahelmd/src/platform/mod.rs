//! Everything seahelmd does differently on Unix and on Windows, behind one
//! face, so the daemon, the client and the session never ask which they run
//! on.
//!
//! | | Unix | Windows |
//! |---|---|---|
//! | where a session listens | a socket in `/tmp/seahelmd-<uid>/` | a named pipe `\\.\pipe\seahelmd-<user>-<name>` |
//! | which sessions exist | the socket files there | the pipes with that prefix |
//! | daemon outlives its starter | `setsid` | detached, own process group, out of any job |
//! | a session's end takes its children | `killpg` | the process tree |
//! | a process's cwd / name | `proc_pidinfo` (macOS), `/proc` (Linux) | the PEB / the image name |
//! | the attach CLI's terminal | termios raw mode | console modes |
//!
//! The Windows side is the port in progress (docs: the Windows port
//! assessment); where it is not done yet it compiles and says so at run time.

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub use unix::*;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use windows::*;

/// A session name a daemon can listen under on every platform: no path
/// separators, nothing hidden, not empty.
pub fn check_name(name: &str) -> anyhow::Result<()> {
    if name.is_empty() || name.contains(['/', '\\']) || name.starts_with('.') {
        anyhow::bail!("bad session name {name:?}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_that_cannot_be_an_address_are_refused() {
        assert!(check_name("seahelm-repo-main").is_ok());
        for bad in ["", "a/b", "a\\b", ".hidden"] {
            assert!(check_name(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn an_address_names_the_session() {
        let a = address("seahelm-x").unwrap();
        assert!(a.to_string_lossy().ends_with("seahelm-x"), "{}", a.display());
    }
}
