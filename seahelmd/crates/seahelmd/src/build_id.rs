//! Which build a running service is, so a client that ships a different one
//! can replace it (`seahelm-core ensure`, `seahelm-gateway ensure`). An update
//! swaps the files under a running core and gateway; without this they kept
//! serving the old code until the machine restarted.
//!
//! The id is a hash of the executable's bytes, taken when the service
//! starts: any two builds that differ get different ids, with nothing to
//! stamp at build time. It must be taken at start — read later, a process
//! whose file was replaced under it would report the new file's id.

use std::io::Read;
use std::path::Path;
use std::sync::OnceLock;

static ID: OnceLock<String> = OnceLock::new();

/// This executable's id, read the first time it is asked for. A service
/// calls it as it starts; "" when the file cannot be read.
pub fn current() -> &'static str {
    ID.get_or_init(|| std::env::current_exe().ok().and_then(|p| of_file(&p)).unwrap_or_default())
}

/// The id of the executable at `path` (64-bit FNV-1a of its bytes, as hex).
pub fn of_file(path: &Path) -> Option<String> {
    let mut f = std::fs::File::open(path).ok()?;
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut buf = vec![0u8; 1 << 16];
    loop {
        let n = f.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        for b in &buf[..n] {
            hash ^= u64::from(*b);
            hash = hash.wrapping_mul(0x0100_0000_01b3);
        }
    }
    Some(format!("{hash:016x}"))
}

/// Whether a running service that answered `reported` (its ping's `build`,
/// absent from services older than this) should give way to this build.
/// An unreadable own id never replaces anything.
pub fn should_replace(reported: Option<&str>, mine: &str) -> bool {
    !mine.is_empty() && reported != Some(mine)
}

/// What a running service said about itself when pinged.
pub struct Running {
    /// Its build id; None from a service older than build ids.
    pub build: Option<String>,
    /// Its pid, as it reported it or as the socket's peer.
    pub pid: Option<u32>,
}

/// Make room for this build: when the service answering is another build,
/// end it and wait until it is gone. `ping` asks the service (None: nothing
/// answers). Returns true when the service answering is this build and
/// nothing needs starting; false when one should be started.
pub fn make_room(name: &str, ping: impl Fn() -> Option<Running>) -> bool {
    let Some(running) = ping() else { return false };
    let mine = current();
    if !should_replace(running.build.as_deref(), mine) {
        return true;
    }
    let Some(pid) = running.pid else {
        eprintln!("{name}: a different build is running and its pid is unknown; leaving it");
        return true;
    };
    eprintln!("{name}: replacing build {} (pid {pid}) with {mine}", running.build.as_deref().unwrap_or("unknown"));
    crate::platform::terminate(pid, false);
    let gone = |secs: u64| {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(secs);
        while std::time::Instant::now() < deadline {
            if !crate::platform::alive(pid) {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        false
    };
    if !gone(5) {
        crate::platform::terminate(pid, true);
        gone(2);
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_follow_the_bytes() {
        let dir = std::env::temp_dir().join(format!("build-id-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (a, b) = (dir.join("a"), dir.join("b"));
        std::fs::write(&a, b"one build").unwrap();
        std::fs::write(&b, b"one build").unwrap();
        assert_eq!(of_file(&a), of_file(&b));
        std::fs::write(&b, b"another build").unwrap();
        assert_ne!(of_file(&a), of_file(&b));
        assert_eq!(of_file(&dir.join("missing")), None);
        assert_eq!(of_file(&a).unwrap().len(), 16);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn replaces_a_different_or_older_service_only() {
        assert!(!should_replace(Some("abc"), "abc"));
        assert!(should_replace(Some("abc"), "def"));
        assert!(should_replace(None, "def"), "a service from before build ids");
        assert!(!should_replace(None, ""), "an unreadable own id replaces nothing");
    }
}
