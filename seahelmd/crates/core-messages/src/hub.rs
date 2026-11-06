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
            let is_activity = m.kind.is_activity();
            let count = ring.iter().filter(|row| row.kind.is_activity() == is_activity).count();
            let keep = self.per_pane;
            if count > keep {
                let extra = count - keep;
                let mut removed = 0;
                ring.retain(|row| {
                    if removed < extra && row.kind.is_activity() == is_activity {
                        removed += 1;
                        false
                    } else {
                        true
                    }
                });
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
            let conversation: Vec<&Message> = ring.iter().filter(|m| !m.kind.is_activity()).collect();
            let activity: Vec<&Message> = ring.iter().filter(|m| m.kind.is_activity()).collect();
            let newer_conversation = conversation.iter().filter(|m| m.seq > after).count();
            let newer_activity = activity.iter().filter(|m| m.seq > after).count();
            if (conversation.len() >= self.per_pane && newer_conversation == conversation.len())
                || (activity.len() >= self.per_pane && newer_activity == activity.len())
            {
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

/// The disk side keeps conversation rows and tool/status rows in separate
/// JSONL buckets per ring. Card rows share the conversation budget, while
/// staying in their existing file for compatible readers.
pub struct Store {
    dir: PathBuf,
    keep: usize,
    lines: HashMap<(String, bool), usize>,
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

    fn card_file(&self, key: &str) -> PathBuf {
        let safe: String = key.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' }).collect();
        self.dir.join(format!("{safe}.cards.jsonl"))
    }

    fn activity_file(&self, key: &str) -> PathBuf {
        let safe: String = key.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' }).collect();
        self.dir.join(format!("{safe}.activity.jsonl"))
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
        let mut all: HashMap<String, Vec<Message>> = HashMap::new();
        let mut misplaced = std::collections::HashSet::new();
        let Ok(entries) = std::fs::read_dir(&self.dir) else { return HashMap::new() };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default();
            let is_card_file = name.ends_with(".cards.jsonl");
            let is_activity_file = name.ends_with(".activity.jsonl");
            for line in Self::read_lines(&path) {
                let Some(message) = Self::decode(&line) else { continue };
                let key = message.ring_key().to_string();
                let expected_card_file = message.kind == Kind::Card;
                let expected_activity_file = message.kind.is_activity();
                if is_card_file != expected_card_file || is_activity_file != expected_activity_file {
                    misplaced.insert(key.clone());
                }
                all.entry(key).or_default().push(message);
            }
        }
        let mut rings = HashMap::new();
        for (key, mut rows) in all {
            rows.sort_by_key(|m| m.seq);
            rows.dedup_by_key(|m| m.seq);
            let mut conversation: Vec<Message> = rows.iter().filter(|m| !m.kind.is_activity()).cloned().collect();
            let mut activity: Vec<Message> = rows.into_iter().filter(|m| m.kind.is_activity()).collect();
            if conversation.len() > self.keep || activity.len() > self.keep {
                misplaced.insert(key.clone());
                conversation.drain(..conversation.len().saturating_sub(self.keep));
                activity.drain(..activity.len().saturating_sub(self.keep));
            }
            self.lines.insert((key.clone(), false), conversation.len());
            self.lines.insert((key.clone(), true), activity.len());
            if misplaced.contains(&key) {
                self.persist_bucket(&key, false, &conversation);
                self.persist_bucket(&key, true, &activity);
            }

            let mut memory: Vec<Message> = conversation[conversation.len().saturating_sub(count)..].to_vec();
            memory.extend(activity[activity.len().saturating_sub(count)..].iter().cloned());
            memory.sort_by_key(|m| m.seq);
            if !memory.is_empty() {
                rings.insert(key, memory);
            }
        }
        rings
    }

    fn save(&mut self, m: &Message) {
        let key = m.ring_key().to_string();
        let is_activity = m.kind.is_activity();
        let path = if is_activity { self.activity_file(&key) } else if m.kind == Kind::Card { self.card_file(&key) } else { self.file(&key) };
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
            let _ = writeln!(f, "{}", m.to_json());
        }
        let n = self.lines.entry((key.clone(), is_activity)).or_insert(0);
        *n += 1;
        let keep = self.keep;
        let threshold = keep + keep / 2;
        if *n > threshold {
            let mut rows = self.read_bucket(&key, is_activity);
            rows.sort_by_key(|row| row.seq);
            rows.dedup_by_key(|row| row.seq);
            let excess = rows.len().saturating_sub(keep);
            rows.drain(..excess);
            self.persist_bucket(&key, is_activity, &rows);
            self.lines.insert((key, is_activity), rows.len());
        }
    }

    fn read_bucket(&self, key: &str, is_activity: bool) -> Vec<Message> {
        let paths = if is_activity { vec![self.activity_file(key)] } else { vec![self.file(key), self.card_file(key)] };
        let mut rows: Vec<Message> = paths
            .iter()
            .flat_map(|path| Self::read_lines(path))
            .filter_map(|line| Self::decode(&line))
            .filter(|row| row.ring_key() == key && row.kind.is_activity() == is_activity)
            .collect();
        rows.sort_by_key(|row| row.seq);
        rows.dedup_by_key(|row| row.seq);
        rows
    }

    fn persist_bucket(&self, key: &str, is_activity: bool, rows: &[Message]) {
        if is_activity {
            Self::replace_file(&self.activity_file(key), rows);
        } else {
            let conversation: Vec<Message> = rows.iter().filter(|row| row.kind != Kind::Card).cloned().collect();
            let cards: Vec<Message> = rows.iter().filter(|row| row.kind == Kind::Card).cloned().collect();
            Self::replace_file(&self.file(key), &conversation);
            Self::replace_file(&self.card_file(key), &cards);
        }
    }

    fn replace_file(path: &Path, rows: &[Message]) {
        if rows.is_empty() {
            let _ = std::fs::remove_file(path);
            return;
        }
        let tmp = path.with_extension("tmp");
        let body = rows.iter().map(|row| format!("{}\n", row.to_json())).collect::<String>();
        if std::fs::write(&tmp, body).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }

    fn history(&self, key: &str, before: u64, limit: usize) -> (Vec<Message>, bool) {
        let mut older: Vec<Message> = [self.file(key), self.card_file(key), self.activity_file(key)]
            .iter()
            .flat_map(|path| Self::read_lines(path))
            .filter_map(|line| Self::decode(&line))
            .filter(|m| m.ring_key() == key && m.seq < before)
            .collect();
        older.sort_by_key(|m| m.seq);
        older.dedup_by_key(|m| m.seq);
        let more = older.len() > limit;
        (older[older.len().saturating_sub(limit)..].to_vec(), more)
    }

    fn remove(&mut self, key: &str) {
        self.lines.remove(&(key.to_string(), false));
        self.lines.remove(&(key.to_string(), true));
        let _ = std::fs::remove_file(self.file(key));
        let _ = std::fs::remove_file(self.card_file(key));
        let _ = std::fs::remove_file(self.activity_file(key));
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
        assert_eq!(older.len(), 5);
        assert!(!more);
    }

    #[test]
    fn tool_flood_preserves_conversation_and_disk_margins() {
        let dir = tempfile::tempdir().unwrap();
        let mut hub = Hub::new(Some(Store::open(dir.path(), 12)), 5);
        for i in 0..60 {
            hub.append(vec![ev(&format!("conversation-{i}"), "a", "k", i as f64)]);
            hub.append(vec![Message::new("a", "k", Kind::Tool, i as f64).with_text(format!("tool-{i}"))]);
        }
        for i in 0..2 {
            hub.append(vec![Message::new("a", "k", Kind::Card, 61.0).with_text(format!("card-{i}"))]);
        }
        for snapshot in [hub.snapshot(Some("k")), Hub::new(Some(Store::open(dir.path(), 12)), 5).snapshot(Some("k"))] {
            assert_eq!(snapshot.iter().filter(|m| !m.kind.is_activity()).count(), 5);
            assert_eq!(snapshot.iter().filter(|m| m.kind.is_activity()).count(), 5);
            assert_eq!(snapshot.iter().filter(|m| m.kind == Kind::Card).count(), 2);
            assert!(snapshot.windows(2).all(|pair| pair[0].seq < pair[1].seq));
            assert_eq!(snapshot.iter().find(|m| m.kind == Kind::User).unwrap().text.as_deref(), Some("conversation-57"));
        }
        let mut restarted = Hub::new(Some(Store::open(dir.path(), 12)), 5);
        let (history, more) = restarted.history("k", u64::MAX, 100);
        assert_eq!(history.len(), 24);
        assert!(!more);
        assert!(history.windows(2).all(|pair| pair[0].seq < pair[1].seq));
    }

    #[test]
    fn legacy_mixed_file_keeps_all_conversation_kinds_through_a_tool_flood() {
        let dir = tempfile::tempdir().unwrap();
        let kinds = [Kind::User, Kind::Assistant, Kind::Thinking, Kind::Decision, Kind::Notice, Kind::Note, Kind::Brief, Kind::Card];
        let mut rows = Vec::new();
        for (i, kind) in kinds.into_iter().enumerate() {
            let mut row = Message::new("a", "k", kind, i as f64).with_text(format!("conversation-{i}"));
            row.seq = i as u64 + 1;
            rows.push(row);
        }
        for i in 0..133 {
            let mut row = Message::new("a", "k", if i % 2 == 0 { Kind::Tool } else { Kind::Status }, 10.0);
            row.seq = i + 9;
            rows.push(row);
        }
        std::fs::write(dir.path().join("k.jsonl"), rows.iter().map(|row| format!("{}\n", row.to_json())).collect::<String>()).unwrap();
        let mut hub = Hub::new(Some(Store::open(dir.path(), 2000)), 80);
        let snapshot = hub.snapshot(Some("a"));
        assert_eq!(snapshot.iter().filter(|row| !row.kind.is_activity()).count(), 8);
        assert_eq!(snapshot.iter().filter(|row| row.kind.is_activity()).count(), 80);
        assert!(snapshot.windows(2).all(|pair| pair[0].seq < pair[1].seq));
        assert_eq!(hub.history("k", u64::MAX, 200).0.len(), 141);
        assert!(dir.path().join("k.activity.jsonl").is_file());
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
