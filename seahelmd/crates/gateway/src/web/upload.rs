//! Files a page attaches to the composer — a pasted screenshot, a picked
//! file. The page is on another device, so the bytes come over its socket
//! (`file.upload`, base64) and land on this machine, where the pane's agent
//! can open them; the page then puts the path in the message. They go where
//! the macOS app keeps dropped files: `$TMPDIR/seahelm-drops/<id>/<name>`.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// The most one file may be. The socket takes 16 MiB a message and base64
/// is 4/3 of the bytes.
pub const MAX_BYTES: usize = 10 << 20;
/// Drops older than this are swept on the next upload.
const KEEP: Duration = Duration::from_secs(7 * 24 * 3600);

pub fn root() -> PathBuf {
    std::env::temp_dir().join("seahelm-drops")
}

/// A file name that needs no quoting when typed into a prompt or a shell:
/// letters, digits, `.`, `-`, `_`, and nothing that leads with a dot.
pub fn safe_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or(name);
    let mut out: String = base.chars().map(|c| if c.is_alphanumeric() || matches!(c, '.' | '-' | '_') { c } else { '-' }).collect();
    while out.contains("--") {
        out = out.replace("--", "-");
    }
    let out = out.trim_matches(|c| c == '-' || c == '.').to_string();
    if out.is_empty() {
        "file".into()
    } else {
        out.chars().take(100).collect()
    }
}

/// Write `bytes` as `name` in a directory of its own under `root`; its path.
pub fn save(root: &Path, name: &str, bytes: &[u8]) -> std::io::Result<PathBuf> {
    sweep(root, SystemTime::now());
    let id = format!("{:x}{:08x}", SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0), rand::random::<u32>());
    let dir = root.join(id);
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(safe_name(name));
    std::fs::write(&path, bytes)?;
    Ok(path)
}

/// Remove drop directories last changed more than `KEEP` before `now`.
fn sweep(root: &Path, now: SystemTime) {
    let Ok(entries) = std::fs::read_dir(root) else { return };
    for e in entries.flatten() {
        let old = e.metadata().and_then(|m| m.modified()).is_ok_and(|t| now.duration_since(t).is_ok_and(|age| age > KEEP));
        if old && e.path().is_dir() {
            let _ = std::fs::remove_dir_all(e.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_need_no_quoting() {
        assert_eq!(safe_name("Screen Shot 2026-11-16 at 10.00.png"), "Screen-Shot-2026-11-16-at-10.00.png");
        assert_eq!(safe_name("../../etc/passwd"), "passwd");
        assert_eq!(safe_name("C:\\Users\\a\\report (1).pdf"), "report-1-.pdf");
        assert_eq!(safe_name(".bashrc"), "bashrc");
        assert_eq!(safe_name("$(rm -rf).txt"), "rm-rf-.txt");
        assert_eq!(safe_name("截图.png"), "截图.png");
        assert_eq!(safe_name(""), "file");
        assert_eq!(safe_name("..."), "file");
    }

    #[test]
    fn saves_each_file_in_a_directory_of_its_own() {
        let tmp = tempfile::tempdir().unwrap();
        let a = save(tmp.path(), "shot.png", b"one").unwrap();
        let b = save(tmp.path(), "shot.png", b"two").unwrap();
        assert_ne!(a, b);
        assert_eq!(std::fs::read(&a).unwrap(), b"one");
        assert_eq!(a.file_name().unwrap(), "shot.png");
        assert!(a.starts_with(tmp.path()));
    }

    #[test]
    fn old_drops_are_swept() {
        let tmp = tempfile::tempdir().unwrap();
        let a = save(tmp.path(), "a.txt", b"a").unwrap();
        sweep(tmp.path(), SystemTime::now() + KEEP + Duration::from_secs(60));
        assert!(!a.exists());
    }
}
