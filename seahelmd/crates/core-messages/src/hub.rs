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

const CARD_ROWS_PER_PANE: usize = 200;

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
            hub.rings = store.load_tails(per_pane, CARD_ROWS_PER_PANE);
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
            let is_card = m.kind == Kind::Card;
            let count = ring.iter().filter(|row| (row.kind == Kind::Card) == is_card).count();
            let keep = if is_card { CARD_ROWS_PER_PANE } else { self.per_pane };
            if count > keep {
                let extra = count - keep;
                let mut removed = 0;
                ring.retain(|row| {
                    if removed < extra && (row.kind == Kind::Card) == is_card {
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
            let conversation: Vec<&Message> = ring.iter().filter(|m| m.kind != Kind::Card).collect();
            let cards: Vec<&Message> = ring.iter().filter(|m| m.kind == Kind::Card).collect();
            let newer_conversation = conversation.iter().filter(|m| m.seq > after).count();
            let newer_cards = cards.iter().filter(|m| m.seq > after).count();
            if (conversation.len() >= self.per_pane && newer_conversation == conversation.len())
                || (cards.len() >= CARD_ROWS_PER_PANE && newer_cards == cards.len())
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

/// The disk side: conversation rows and card rows have separate JSONL files
/// per ring and independent retention, both oldest line first.
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

    fn load_tails(&mut self, count: usize, card_count: usize) -> HashMap<String, Vec<Message>> {
        let mut conversations: HashMap<String, Vec<Message>> = HashMap::new();
        let mut cards: HashMap<String, Vec<Message>> = HashMap::new();
        let mut legacy_card_keys = std::collections::HashSet::new();
        let Ok(entries) = std::fs::read_dir(&self.dir) else { return HashMap::new() };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let is_card_file = path.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.ends_with(".cards.jsonl"));
            for line in Self::read_lines(&path) {
                let Some(message) = Self::decode(&line) else { continue };
                let key = message.ring_key().to_string();
                let is_card = message.kind == Kind::Card;
                if is_card {
                    if !is_card_file {
                        legacy_card_keys.insert(key.clone());
                    }
                    cards.entry(key.clone()).or_default().push(message);
                } else if !is_card_file {
                    conversations.entry(key.clone()).or_default().push(message);
                }
                *self.lines.entry((key, is_card)).or_default() += 1;
            }
        }
        for rows in conversations.values_mut() {
            rows.sort_by_key(|m| m.seq);
            let excess = rows.len().saturating_sub(count);
            rows.drain(..excess);
        }
        for rows in cards.values_mut() {
            rows.sort_by_key(|m| m.seq);
            rows.dedup_by_key(|m| m.seq);
            let excess = rows.len().saturating_sub(card_count);
            rows.drain(..excess);
        }
        // Move card rows from pre-split files into their own file before a
        // later conversation trim can discard those legacy lines. Also heal
        // any card file left beyond its cap by an interrupted write.
        let mut rewrite_card_keys = legacy_card_keys;
        rewrite_card_keys.extend(cards.iter().filter_map(|(key, _)| {
            (self.lines.get(&(key.clone(), true)).copied().unwrap_or(0) > card_count).then(|| key.clone())
        }));
        for key in rewrite_card_keys {
            if let Some(rows) = cards.get(&key) {
                let body = rows.iter().map(|m| format!("{}\n", m.to_json())).collect::<String>();
                if std::fs::write(self.card_file(&key), body).is_ok() {
                    self.lines.insert((key, true), rows.len());
                }
            }
        }
        let mut rings = HashMap::new();
        for (key, mut rows) in conversations {
            rows.extend(cards.remove(&key).unwrap_or_default());
            rows.sort_by_key(|m| m.seq);
            rings.insert(key, rows);
        }
        for (key, mut rows) in cards {
            rows.sort_by_key(|m| m.seq);
            rings.insert(key, rows);
        }
        rings
    }

    fn save(&mut self, m: &Message) {
        let key = m.ring_key().to_string();
        let is_card = m.kind == Kind::Card;
        let path = if is_card { self.card_file(&key) } else { self.file(&key) };
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
            let _ = writeln!(f, "{}", m.to_json());
        }
        let n = self.lines.entry((key.clone(), is_card)).or_insert(0);
        *n += 1;
        let keep = if is_card { CARD_ROWS_PER_PANE } else { self.keep };
        let threshold = keep + keep / 2;
        if *n > threshold {
            let matching: Vec<String> = Self::read_lines(&path).into_iter().filter(|line| {
                Self::decode(line).is_some_and(|row| (row.kind == Kind::Card) == is_card)
            }).collect();
            let kept = &matching[matching.len().saturating_sub(keep)..];
            let tmp = path.with_extension("tmp");
            if std::fs::write(&tmp, kept.iter().map(|l| format!("{l}\n")).collect::<String>()).is_ok() {
                let _ = std::fs::rename(&tmp, &path);
            }
            self.lines.insert((key, is_card), kept.len());
        }
    }

    fn history(&self, key: &str, before: u64, limit: usize) -> (Vec<Message>, bool) {
        let conversation = Self::read_lines(&self.file(key));
        let cards = Self::read_lines(&self.card_file(key));
        let mut older: Vec<Message> = conversation.iter().chain(cards.iter())
            .filter_map(|line| Self::decode(line))
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
    fn card_rows_have_separate_retention_from_conversation_rows() {
        let dir = tempfile::tempdir().unwrap();
        let mut hub = Hub::new(Some(Store::open(dir.path(), 2000)), 80);
        for i in 0..305 {
            hub.append(vec![ev(&format!("conversation-{i}"), "a", "k", i as f64)]);
            let mut card = Message::new("seahelm-first-mate", "k", Kind::Card, i as f64 + 0.5).with_text(format!("card-{i}"));
            card.card_id = Some(format!("c-{i}"));
            card.state = Some("pending".into());
            hub.append(vec![card]);
        }
        let snapshot = hub.snapshot(Some("k"));
        assert_eq!(snapshot.iter().filter(|m| m.kind != Kind::Card).count(), 80);
        assert_eq!(snapshot.iter().filter(|m| m.kind == Kind::Card).count(), 200);
        assert!(snapshot.windows(2).all(|rows| rows[0].seq < rows[1].seq));
        assert_eq!(snapshot.iter().find(|m| m.kind != Kind::Card).unwrap().text.as_deref(), Some("conversation-225"));
        assert_eq!(snapshot.iter().find(|m| m.kind == Kind::Card).unwrap().text.as_deref(), Some("card-105"));
        let card_file_rows = std::fs::read_to_string(dir.path().join("k.cards.jsonl")).unwrap().lines().count();
        assert!((201..=300).contains(&card_file_rows), "{card_file_rows}");

        let mut after_restart = Hub::new(Some(Store::open(dir.path(), 2000)), 80);
        let snapshot = after_restart.snapshot(Some("k"));
        assert_eq!(snapshot.iter().filter(|m| m.kind != Kind::Card).count(), 80);
        assert_eq!(snapshot.iter().filter(|m| m.kind == Kind::Card).count(), 200);
        assert!(snapshot.windows(2).all(|rows| rows[0].seq < rows[1].seq));
        assert_eq!(snapshot.iter().find(|m| m.kind == Kind::Card).unwrap().text.as_deref(), Some("card-105"));
        let (history, more) = after_restart.history("k", u64::MAX, 600);
        assert_eq!(history.len(), 505);
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
