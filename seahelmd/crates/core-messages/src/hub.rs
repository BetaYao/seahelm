//! Every pane's timeline (`MessageStreamHub.swift` / `MessageStreamStore`):
//! a short ring per pane in memory, the longer history on disk, one JSONL
//! file per pane, paged in on request. Sequence numbers are global and carry
//! on across restarts, so "after seq N" means the same thing tomorrow.

use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde_json::Value;

use seahelm_core_hooks::prompt::human_text;
use seahelm_core_registry::Outcome;
use seahelm_core_scan::manifest::MessageConfig;
use seahelm_core_types::Timestamp;

use crate::event::{Kind, Message};
use crate::project::{project, Coalesce};

/// What a client holding everything up to some seq is missing.
#[derive(Clone, Debug, PartialEq)]
pub struct Replay {
    pub messages: Vec<Message>,
    /// Rings that may have evicted part of the gap (full, and nothing in
    /// them at or before the seq): the client takes them whole.
    pub truncated: Vec<String>,
}

pub struct Hub {
    rings: HashMap<String, Vec<Message>>,
    coalesce: HashMap<String, Coalesce>,
    next_seq: u64,
    per_pane: usize,
    store: Option<Store>,
}

impl Hub {
    /// `store` None keeps everything in memory (tests).
    pub fn new(store: Option<Store>, per_pane: usize) -> Self {
        let mut hub = Hub { rings: HashMap::new(), coalesce: HashMap::new(), next_seq: 0, per_pane, store };
        if let Some(store) = &mut hub.store {
            hub.rings = store.load_tails(per_pane);
            hub.next_seq = hub.rings.values().filter_map(|r| r.last().map(|m| m.seq)).max().unwrap_or(0);
        }
        hub
    }

    pub fn seq(&self) -> u64 {
        self.next_seq
    }

    /// Project an outcome and append its rows; the rows appended.
    pub fn ingest(&mut self, o: &Outcome, pane_id: &str, config: &MessageConfig, now: Timestamp) -> Vec<Message> {
        let key = o.info.id.clone();
        let coal = self.coalesce.get(&key).cloned().unwrap_or_default();
        let (rows, next) = project(o, pane_id, config, &coal, now);
        self.coalesce.insert(key, next);
        self.append(rows)
    }

    /// Stamp and keep `rows`; the ones kept.
    pub fn append(&mut self, rows: Vec<Message>) -> Vec<Message> {
        let mut kept = Vec::with_capacity(rows.len());
        for mut m in rows {
            let key = m.ring_key().to_string();
            let ring = self.rings.entry(key).or_default();
            // A turn's final message comes twice, from the transcript and from
            // the Stop hook, in either order.
            if m.kind == Kind::Assistant && ring.iter().filter(|r| r.kind == Kind::Assistant).rev().take(3).any(|r| r.text == m.text) {
                continue;
            }
            self.next_seq += 1;
            m.seq = self.next_seq;
            ring.push(m.clone());
            if ring.len() > self.per_pane {
                let extra = ring.len() - self.per_pane;
                ring.drain(..extra);
            }
            if let Some(store) = &mut self.store {
                store.save(&m);
            }
            kept.push(m);
        }
        kept
    }

    /// One pane's ring (by key or client id); every ring, in order, for None.
    pub fn snapshot(&self, pane: Option<&str>) -> Vec<Message> {
        match pane {
            Some(p) => self.rings.get(&self.key_for(p)).cloned().unwrap_or_default(),
            None => {
                let mut all: Vec<Message> = self.rings.values().flatten().cloned().collect();
                all.sort_by_key(|m| m.seq);
                all
            }
        }
    }

    /// When the pane's timeline last moved, for reading a transcript back no
    /// further than that.
    pub fn last_ts(&self, pane: &str) -> Option<Timestamp> {
        self.rings.get(&self.key_for(pane)).and_then(|r| r.last()).map(|m| m.ts)
    }

    /// Up to `limit` rows of one pane older than `before`, oldest first, and
    /// whether anything older remains.
    pub fn history(&mut self, pane: &str, before: u64, limit: usize) -> (Vec<Message>, bool) {
        let key = self.key_for(pane);
        if let Some(store) = &self.store {
            return store.history(&key, before, limit);
        }
        let older: Vec<Message> = self.rings.get(&key).into_iter().flatten().filter(|m| m.seq < before).cloned().collect();
        let more = older.len() > limit;
        (older[older.len().saturating_sub(limit)..].to_vec(), more)
    }

    /// None when `after` is ahead of the hub (its history was reset): the
    /// client takes everything.
    pub fn replay(&self, after: u64) -> Option<Replay> {
        if after > self.next_seq {
            return None;
        }
        let mut messages = Vec::new();
        let mut truncated = Vec::new();
        for (key, ring) in &self.rings {
            let newer: Vec<Message> = ring.iter().filter(|m| m.seq > after).cloned().collect();
            if ring.len() >= self.per_pane && newer.len() == ring.len() {
                truncated.push(key.clone());
            }
            messages.extend(newer);
        }
        messages.sort_by_key(|m| m.seq);
        truncated.sort();
        Some(Replay { messages, truncated })
    }

    pub fn events_after(&self, seq: u64) -> Vec<Message> {
        let mut out: Vec<Message> = self.rings.values().flatten().filter(|m| m.seq > seq).cloned().collect();
        out.sort_by_key(|m| m.seq);
        out
    }

    /// The pane is gone for good (closed): its history goes, on disk too.
    pub fn clear(&mut self, pane: &str) {
        let keys: Vec<String> = self.rings.iter().filter(|(k, r)| *k == pane || r.iter().any(|m| m.pane_id == pane)).map(|(k, _)| k.clone()).collect();
        for k in keys {
            self.rings.remove(&k);
            self.coalesce.remove(&k);
            if let Some(store) = &mut self.store {
                store.remove(&k);
            }
        }
        self.coalesce.remove(pane);
    }

    /// A client id resolves to its ring through the rows it stamped.
    fn key_for(&self, pane: &str) -> String {
        if self.rings.contains_key(pane) {
            return pane.to_string();
        }
        self.rings.iter().find(|(_, r)| r.iter().any(|m| m.pane_id == pane)).map(|(k, _)| k.clone()).unwrap_or_else(|| pane.to_string())
    }
}

/// The disk side: one JSONL file per ring, oldest line first. A file grows
/// past `keep` by half before being cut back, so a busy pane is not a
/// rewrite per tool call.
pub struct Store {
    dir: PathBuf,
    keep: usize,
    lines: HashMap<String, usize>,
}

impl Store {
    pub fn open(dir: &Path, keep: usize) -> Self {
        let _ = std::fs::create_dir_all(dir);
        Store { dir: dir.to_path_buf(), keep, lines: HashMap::new() }
    }

    fn file(&self, key: &str) -> PathBuf {
        let safe: String = key.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' }).collect();
        self.dir.join(format!("{safe}.jsonl"))
    }

    fn read_lines(path: &Path) -> Vec<String> {
        std::fs::read_to_string(path).map(|t| t.lines().filter(|l| !l.is_empty()).map(str::to_string).collect()).unwrap_or_default()
    }

    /// Unreadable lines are skipped; a stored prompt goes through the same
    /// rule a new one does (a row written before it existed is healed).
    fn decode(line: &str) -> Option<Message> {
        let v: Value = serde_json::from_str(line).ok()?;
        let mut m = Message::from_json(&v)?;
        if m.kind == Kind::User {
            m.text = Some(human_text(m.text.as_deref().unwrap_or_default())?);
        }
        Some(m)
    }

    fn load_tails(&mut self, count: usize) -> HashMap<String, Vec<Message>> {
        let mut rings = HashMap::new();
        let Ok(entries) = std::fs::read_dir(&self.dir) else { return rings };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let lines = Self::read_lines(&path);
            let tail: Vec<Message> = lines[lines.len().saturating_sub(count)..].iter().filter_map(|l| Self::decode(l)).collect();
            let Some(key) = tail.last().map(|m| m.ring_key().to_string()) else { continue };
            self.lines.insert(key.clone(), lines.len());
            rings.insert(key, tail);
        }
        rings
    }

    fn save(&mut self, m: &Message) {
        let key = m.ring_key().to_string();
        let path = self.file(&key);
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
            let _ = writeln!(f, "{}", m.to_json());
        }
        let n = self.lines.entry(key.clone()).or_insert(0);
        *n += 1;
        if *n > self.keep + self.keep / 2 {
            let lines = Self::read_lines(&path);
            let kept = &lines[lines.len().saturating_sub(self.keep)..];
            let tmp = path.with_extension("jsonl.tmp");
            if std::fs::write(&tmp, kept.iter().map(|l| format!("{l}\n")).collect::<String>()).is_ok() {
                let _ = std::fs::rename(&tmp, &path);
            }
            self.lines.insert(key, kept.len());
        }
    }

    fn history(&self, key: &str, before: u64, limit: usize) -> (Vec<Message>, bool) {
        let mut older = Vec::new();
        for line in Self::read_lines(&self.file(key)).iter().rev() {
            let Some(m) = Self::decode(line).filter(|m| m.seq < before) else { continue };
            if older.len() == limit {
                older.reverse();
                return (older, true);
            }
            older.push(m);
        }
        older.reverse();
        (older, false)
    }

    fn remove(&mut self, key: &str) {
        self.lines.remove(key);
        let _ = std::fs::remove_file(self.file(key));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(text: &str, pane: &str, key: &str, ts: f64) -> Message {
        Message::new(pane, key, Kind::User, ts).with_text(text)
    }

    fn e(text: &str) -> Message {
        ev(text, "a", "k", 0.0)
    }

    fn texts(m: &[Message]) -> Vec<Option<String>> {
        m.iter().map(|x| x.text.clone()).collect()
    }

    fn t(s: &[&str]) -> Vec<Option<String>> {
        s.iter().map(|x| Some(x.to_string())).collect()
    }

    #[test]
    fn append_snapshot_and_clear() {
        let mut hub = Hub::new(None, 80);
        hub.append(vec![e("hi")]);
        assert_eq!(hub.snapshot(Some("a")).len(), 1);
        assert_eq!(hub.snapshot(Some("k"))[0].seq, 1);
        hub.clear("a");
        assert!(hub.snapshot(Some("a")).is_empty());
    }

    #[test]
    fn delta_replay_carries_only_newer_events() {
        let mut hub = Hub::new(None, 80);
        hub.append(vec![e("1"), e("2"), ev("x", "b", "k2", 0.0)]);
        let d = hub.replay(2).unwrap();
        assert_eq!(texts(&d.messages), t(&["x"]));
        assert!(d.truncated.is_empty());
        assert!(hub.replay(50).is_none());
    }

    #[test]
    fn delta_replay_flags_a_ring_that_may_have_lost_part_of_the_gap() {
        let mut hub = Hub::new(None, 3);
        hub.append(vec![e("1"), e("2")]);
        hub.append((3..=7).map(|i| e(&i.to_string())).collect());
        hub.append(vec![ev("b", "b", "k2", 0.0)]);
        let d = hub.replay(2).unwrap();
        assert_eq!(d.truncated, vec!["k".to_string()]);
        assert_eq!(texts(&d.messages), t(&["5", "6", "7", "b"]));
        assert_eq!(texts(&hub.events_after(7)), t(&["b"]));
    }

    #[test]
    fn history_survives_relaunch() {
        let dir = tempfile::tempdir().unwrap();
        let mut first = Hub::new(Some(Store::open(dir.path(), 2000)), 80);
        first.append(vec![ev("one", "a", "k", 100.0), ev("two", "a", "k", 101.0)]);
        first.append(vec![ev("other", "b", "k2", 102.0)]);
        let mut tool = Message::new("a", "k", Kind::Tool, 103.0);
        tool.tool = Some("Read".into());
        tool.is_error = Some(false);
        first.append(vec![tool]);
        let mut again = Hub::new(Some(Store::open(dir.path(), 2000)), 80);
        let ring = again.snapshot(Some("k"));
        assert_eq!(ring.iter().map(|m| m.kind).collect::<Vec<_>>(), [Kind::User, Kind::User, Kind::Tool]);
        assert_eq!(ring[2].tool.as_deref(), Some("Read"));
        assert_eq!(again.snapshot(None).iter().map(|m| m.seq).collect::<Vec<_>>(), [1, 2, 3, 4]);
        assert_eq!(again.append(vec![ev("three", "a", "k", 104.0)])[0].seq, 5);
    }

    #[test]
    fn history_pages_older_than_memory() {
        let dir = tempfile::tempdir().unwrap();
        let mut hub = Hub::new(Some(Store::open(dir.path(), 2000)), 5);
        for i in 1..=12 {
            hub.append(vec![ev(&format!("m{i}"), "a", "k", i as f64)]);
        }
        hub.append(vec![ev("elsewhere", "b", "k2", 13.0)]);
        assert_eq!(texts(&hub.snapshot(Some("k"))), t(&["m8", "m9", "m10", "m11", "m12"]));
        let (page, more) = hub.history("k", 8, 4);
        assert_eq!(texts(&page), t(&["m4", "m5", "m6", "m7"]));
        assert!(more);
        let (last, more) = hub.history("a", 4, 4);
        assert_eq!(texts(&last), t(&["m1", "m2", "m3"]));
        assert!(!more);
    }

    #[test]
    fn history_without_store_comes_from_memory() {
        let mut hub = Hub::new(None, 5);
        for i in 1..=5 {
            hub.append(vec![e(&format!("m{i}"))]);
        }
        let (page, more) = hub.history("k", 4, 2);
        assert_eq!(texts(&page), t(&["m2", "m3"]));
        assert!(more);
    }

    #[test]
    fn closed_pane_history_is_deleted() {
        let dir = tempfile::tempdir().unwrap();
        let mut hub = Hub::new(Some(Store::open(dir.path(), 2000)), 80);
        hub.append(vec![e("gone")]);
        hub.clear("a");
        assert!(Hub::new(Some(Store::open(dir.path(), 2000)), 80).snapshot(None).is_empty());
    }

    #[test]
    fn file_stays_bounded_and_reloads_newest() {
        let dir = tempfile::tempdir().unwrap();
        let mut hub = Hub::new(Some(Store::open(dir.path(), 10)), 5);
        for i in 0..40 {
            hub.append(vec![ev(&format!("m{i}"), "a", "k", 100.0 + i as f64)]);
        }
        let lines = std::fs::read_to_string(dir.path().join("k.jsonl")).unwrap().lines().count();
        assert!((10..=15).contains(&lines), "{lines}");
        let mut again = Hub::new(Some(Store::open(dir.path(), 10)), 5);
        assert_eq!(texts(&again.snapshot(Some("k"))), t(&["m35", "m36", "m37", "m38", "m39"]));
        let (older, more) = again.history("k", 36, 100);
        assert_eq!(older.last().and_then(|m| m.text.clone()).as_deref(), Some("m34"));
        assert_eq!(older.len(), lines - 5);
        assert!(!more);
    }

    #[test]
    fn unreadable_line_is_skipped_and_stored_prompts_are_healed() {
        let dir = tempfile::tempdir().unwrap();
        let mut hub = Hub::new(Some(Store::open(dir.path(), 2000)), 80);
        hub.append(vec![e("kept")]);
        let path = dir.path().join("k.jsonl");
        let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        writeln!(f, "{{not json").unwrap();
        writeln!(f, "{}", serde_json::json!({"seq": 2, "pane_id": "a", "pane_session_key": "k", "kind": "user", "ts": 1.0, "text": "<task-notification>x</task-notification>"})).unwrap();
        assert_eq!(texts(&Hub::new(Some(Store::open(dir.path(), 2000)), 80).snapshot(Some("k"))), t(&["kept"]));
    }

    #[test]
    fn final_message_arriving_twice_is_shown_once() {
        let mut hub = Hub::new(None, 80);
        let prose = |s: &str| Message::new("a", "k", Kind::Assistant, 0.0).with_text(s);
        hub.append(vec![prose("looking"), prose("done")]);
        hub.append(vec![prose("done")]);
        assert_eq!(texts(&hub.snapshot(Some("k"))), t(&["looking", "done"]));
        hub.append(vec![e("next turn"), prose("done")]);
        assert_eq!(hub.snapshot(Some("k")).iter().filter(|m| m.kind == Kind::Assistant).count(), 2);
    }
}
