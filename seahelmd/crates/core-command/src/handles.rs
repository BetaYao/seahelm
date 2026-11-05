//! The stable `#n` every pane carries: minted
//! the first time a pane is seen and never reused, so `#7` means the same
//! pane in a listing and in a message typed a week later. Keyed by the
//! pane's seahelmd session name.
//!
//! The only numbering there is: the apps show these (`pane.list`'s
//! `handle`). The core keeps its own file and, the first time, took the
//! macOS app's old `pane-handles.json` as its starting point, so handles
//! people already used kept their meaning.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

pub struct Handles {
    path: PathBuf,
    next: u32,
    by_key: BTreeMap<String, u32>,
}

impl Handles {
    /// `path` is the core's file; `seed` the app's, read only when the
    /// core's does not exist yet.
    pub fn open(path: &Path, seed: Option<&Path>) -> Self {
        let read = |p: &Path| -> Option<(u32, BTreeMap<String, u32>)> {
            let v: Value = serde_json::from_str(&std::fs::read_to_string(p).ok()?).ok()?;
            let by_key: BTreeMap<String, u32> =
                v.get("handles")?.as_object()?.iter().filter_map(|(k, n)| Some((k.clone(), n.as_u64()? as u32))).collect();
            let next = v.get("next").and_then(Value::as_u64).unwrap_or(1) as u32;
            Some((next, by_key))
        };
        let (next, by_key) = read(path).or_else(|| seed.and_then(read)).unwrap_or((1, BTreeMap::new()));
        let next = next.max(by_key.values().max().map_or(1, |m| m + 1));
        Handles { path: path.to_path_buf(), next, by_key }
    }

    /// The pane's handle, minting one on first sight.
    pub fn handle(&mut self, key: &str) -> u32 {
        if let Some(h) = self.by_key.get(key) {
            return *h;
        }
        let h = self.next;
        self.next += 1;
        self.by_key.insert(key.to_string(), h);
        self.save();
        h
    }

    fn save(&self) {
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let tmp = self.path.with_extension("json.tmp");
        if std::fs::write(&tmp, json!({"next": self.next, "handles": self.by_key}).to_string()).is_ok() {
            let _ = std::fs::rename(&tmp, &self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minted_once_kept_across_restarts_and_seeded_from_the_app() {
        let d = tempfile::tempdir().unwrap();
        let app = d.path().join("pane-handles.json");
        std::fs::write(&app, r#"{"next": 8, "handles": {"seahelm-a": 7}}"#).unwrap();
        let core = d.path().join("core-pane-handles.json");
        let mut h = Handles::open(&core, Some(&app));
        assert_eq!(h.handle("seahelm-a"), 7);
        assert_eq!(h.handle("seahelm-b"), 8);
        assert_eq!(h.handle("seahelm-b"), 8);
        std::fs::write(&app, r#"{"next": 99, "handles": {}}"#).unwrap();
        let mut again = Handles::open(&core, Some(&app));
        assert_eq!(again.handle("seahelm-b"), 8);
        assert_eq!(again.handle("seahelm-c"), 9);
    }
}
