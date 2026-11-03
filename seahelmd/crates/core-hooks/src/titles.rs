//! What an agent's own session is called, read from the files the agent
//! keeps (`SessionTitleLookup.swift`, `CodexSessionPromptLookup.swift`,
//! `CursorSessionTitleLookup.swift`).
//!
//! - **Claude** writes `~/.claude/projects/<encoded cwd>/<session>.jsonl`;
//!   the title is its last `custom-title` (a user rename), else `ai-title`,
//!   else (older versions) `summary` record.
//! - **Codex** has no title; the last `user_message` in its session log is
//!   the prompt the provider falls back to.
//! - **Cursor** keeps `~/.cursor/chats/<md5(cwd)>/<chat>/`, with the title in
//!   `meta.json` (the IDE) or in `store.db` (the `cursor-agent` CLI).
//!
//! Every lookup takes the home (or the root it derives) as an argument and
//! reads synchronously. The Swift answered from a process-wide cache and
//! rescanned in the background because it ran on the main thread; here the
//! caller owns the thread, and [`TitleCache`] owns the memo.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use md5::{Digest, Md5};
use seahelm_core_types::Timestamp;
use serde_json::Value;

/// The Claude title of one session, or None when its transcript has none
/// yet (or the agent keeps no transcript here at all).
pub fn claude(home: &Path, cwd: &str, session_id: &str) -> Option<String> {
    claude_in(&claude_projects_root(home), cwd, session_id)
}

/// The title of whichever Claude session in `cwd` was written last.
pub fn claude_latest(home: &Path, cwd: &str) -> Option<String> {
    claude_latest_in(&claude_projects_root(home), cwd)
}

pub fn claude_projects_root(home: &Path) -> PathBuf {
    home.join(".claude").join("projects")
}

/// [`claude`] against an explicit projects root.
pub fn claude_in(projects_root: &Path, cwd: &str, session_id: &str) -> Option<String> {
    read_last_title(&claude_transcript(projects_root, cwd, session_id)?)
}

/// [`claude_latest`] against an explicit projects root: the newest
/// transcript that has a title.
pub fn claude_latest_in(projects_root: &Path, cwd: &str) -> Option<String> {
    if cwd.is_empty() {
        return None;
    }
    let dir = projects_root.join(encoded_project_component(cwd));
    let mut sessions: Vec<(SystemTime, PathBuf)> = std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| !is_hidden(p) && p.extension().is_some_and(|x| x == "jsonl"))
        .map(|p| (modified(&p).unwrap_or(SystemTime::UNIX_EPOCH), p))
        .collect();
    sessions.sort_by_key(|s| std::cmp::Reverse(s.0));
    sessions.iter().find_map(|(_, p)| read_last_title(p))
}

/// The transcript of one session, when it exists. The id reaches us from a
/// hook payload, so a crafted one must not walk out of the projects dir.
fn claude_transcript(projects_root: &Path, cwd: &str, session_id: &str) -> Option<PathBuf> {
    if cwd.is_empty() || session_id.is_empty() || session_id.contains(['/', '\\']) || session_id.starts_with('.') {
        return None;
    }
    let path = projects_root.join(encoded_project_component(cwd)).join(format!("{session_id}.jsonl"));
    path.is_file().then_some(path)
}

/// How Claude Code names a project directory: the absolute path with `/`
/// and `.` replaced by `-` (and on Windows `\` and `:` too).
pub fn encoded_project_component(path: &str) -> String {
    path.chars()
        .map(|c| match c {
            '/' | '.' => '-',
            '\\' | ':' if cfg!(windows) => '-',
            c => c,
        })
        .collect()
}

/// The record types that carry a title, in order of preference, with the
/// key holding it. Searching the raw bytes for each marker and parsing only
/// the lines that carry one is what keeps a tens-of-megabytes transcript
/// cheap to scan.
const TITLE_RECORDS: [(&str, &str); 3] = [("custom-title", "customTitle"), ("ai-title", "aiTitle"), ("summary", "summary")];

/// The preferred title in a transcript: the last `custom-title`, else the
/// last `ai-title`, else the last `summary`.
pub fn read_last_title(path: &Path) -> Option<String> {
    let data = std::fs::read(path).ok()?;
    TITLE_RECORDS.iter().find_map(|(kind, key)| last_record(&data, kind, key))
}

fn last_record(data: &[u8], kind: &str, key: &str) -> Option<String> {
    let marker = format!("\"type\":\"{kind}\"");
    let finder = regex::bytes::Regex::new(&regex::escape(&marker)).ok()?;
    let mut last = None;
    for hit in finder.find_iter(data) {
        let start = data[..hit.start()].iter().rposition(|b| *b == b'\n').map_or(0, |i| i + 1);
        let end = data[hit.start()..].iter().position(|b| *b == b'\n').map_or(data.len(), |i| hit.start() + i);
        // The marker can also sit inside a message body that quotes it; only
        // a line whose own `type` is the record counts.
        let Ok(Value::Object(obj)) = serde_json::from_slice::<Value>(&data[start..end]) else { continue };
        if obj.get("type").and_then(Value::as_str) != Some(kind) {
            continue;
        }
        if let Some(title) = obj.get(key).and_then(Value::as_str).filter(|t| !t.is_empty()) {
            last = Some(title.to_string());
        }
    }
    last
}

/// A memo of Claude titles for callers that ask often (every repaint).
///
/// An entry is reused while the transcript's size and mtime are what was
/// scanned, and — because a live transcript changes every few seconds,
/// which would defeat that stamp — for `rescan_interval` seconds after a
/// scan even when it has moved on. A title changes far more slowly than
/// the transcript it comes from.
#[derive(Debug)]
pub struct TitleCache {
    pub rescan_interval: f64,
    entries: HashMap<PathBuf, CacheEntry>,
}

#[derive(Debug)]
struct CacheEntry {
    stamp: Option<(u64, SystemTime)>,
    scanned_at: Timestamp,
    title: Option<String>,
}

impl Default for TitleCache {
    fn default() -> Self {
        TitleCache { rescan_interval: 30.0, entries: HashMap::new() }
    }
}

impl TitleCache {
    pub fn new() -> Self {
        Self::default()
    }

    /// [`claude_in`], answered from the memo when it still stands.
    pub fn claude_in(&mut self, projects_root: &Path, cwd: &str, session_id: &str, now: Timestamp) -> Option<String> {
        let path = claude_transcript(projects_root, cwd, session_id)?;
        let stamp = std::fs::metadata(&path).ok().and_then(|m| Some((m.len(), m.modified().ok()?)));
        if let Some(hit) = self.entries.get(&path) {
            if (stamp.is_some() && hit.stamp == stamp) || now - hit.scanned_at < self.rescan_interval {
                return hit.title.clone();
            }
        }
        let title = read_last_title(&path);
        // Stamped with what the file looked like *before* the read, so
        // anything appended meanwhile is caught by the next rescan.
        self.entries.insert(path, CacheEntry { stamp, scanned_at: now, title: title.clone() });
        title
    }

    /// [`claude`], answered from the memo when it still stands.
    pub fn claude(&mut self, home: &Path, cwd: &str, session_id: &str, now: Timestamp) -> Option<String> {
        self.claude_in(&claude_projects_root(home), cwd, session_id, now)
    }
}

/// The last prompt the user gave a Codex session, from its log under
/// `~/.codex/sessions`.
pub fn codex_prompt(home: &Path, session_id: &str) -> Option<String> {
    codex_prompt_in(&home.join(".codex").join("sessions"), session_id)
}

/// [`codex_prompt`] against an explicit sessions root.
pub fn codex_prompt_in(sessions_root: &Path, session_id: &str) -> Option<String> {
    if session_id.is_empty() {
        return None;
    }
    let file = find_jsonl(sessions_root, session_id)?;
    let contents = std::fs::read_to_string(file).ok()?;
    contents
        .lines()
        .rev()
        .find_map(|line| {
            let obj: Value = serde_json::from_str(line).ok()?;
            if obj.get("type")?.as_str()? != "event_msg" {
                return None;
            }
            let payload = obj.get("payload")?;
            if payload.get("type")?.as_str()? != "user_message" {
                return None;
            }
            payload.get("message")?.as_str().filter(|m| !m.is_empty()).map(str::to_string)
        })
}

/// The first `.jsonl` under `root` whose name contains `needle`, walking
/// depth-first in name order and skipping hidden entries.
fn find_jsonl(root: &Path, needle: &str) -> Option<PathBuf> {
    let mut entries: Vec<PathBuf> = std::fs::read_dir(root).ok()?.flatten().map(|e| e.path()).filter(|p| !is_hidden(p)).collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            if let Some(found) = find_jsonl(&path, needle) {
                return Some(found);
            }
        } else if path.extension().is_some_and(|x| x == "jsonl")
            && path.file_name().is_some_and(|n| n.to_string_lossy().contains(needle))
        {
            return Some(path);
        }
    }
    None
}

/// The title of one Cursor chat.
pub fn cursor(home: &Path, cwd: &str, chat_id: &str) -> Option<String> {
    cursor_in(&cursor_chats_root(home), cwd, chat_id)
}

/// The title of the most recently updated titled Cursor chat in `cwd`.
pub fn cursor_latest(home: &Path, cwd: &str) -> Option<String> {
    cursor_latest_in(&cursor_chats_root(home), cwd)
}

pub fn cursor_chats_root(home: &Path) -> PathBuf {
    home.join(".cursor").join("chats")
}

/// [`cursor`] against an explicit chats root. The chat directory is the
/// CLI's own `session_id`, so two Cursor panes in one worktree cannot swap
/// titles.
pub fn cursor_in(chats_root: &Path, cwd: &str, chat_id: &str) -> Option<String> {
    if cwd.is_empty() || chat_id.is_empty() || chat_id.contains(['/', '\\']) || chat_id.starts_with('.') {
        return None;
    }
    let chat_dir = chats_root.join(md5_hex(cwd)).join(chat_id);
    chat_title(&chat_dir, read_meta(&chat_dir.join("meta.json")).as_ref())
}

/// [`cursor_latest`] against an explicit chats root.
pub fn cursor_latest_in(chats_root: &Path, cwd: &str) -> Option<String> {
    if cwd.is_empty() {
        return None;
    }
    let bucket = chats_root.join(md5_hex(cwd));
    let mut best: Option<(SystemTime, String)> = None;
    for entry in std::fs::read_dir(bucket).ok()?.flatten() {
        let chat_dir = entry.path();
        if is_hidden(&chat_dir) || !chat_dir.is_dir() {
            continue;
        }
        let meta_path = chat_dir.join("meta.json");
        let meta = read_meta(&meta_path);
        // The bucket is already md5(cwd); an exact cwd, when recorded, must agree.
        if meta.as_ref().is_some_and(|m| !m.cwd.is_empty() && m.cwd != cwd) {
            continue;
        }
        let Some(title) = chat_title(&chat_dir, meta.as_ref()) else { continue };
        let date = meta
            .as_ref()
            .and_then(|m| m.updated_at)
            .or_else(|| modified(&meta_path))
            .or_else(|| modified(&chat_dir.join("store.db")))
            .unwrap_or(SystemTime::UNIX_EPOCH);
        if best.as_ref().is_none_or(|(d, _)| date > *d) {
            best = Some((date, title));
        }
    }
    best.map(|(_, t)| t)
}

/// md5 of the cwd, lowercase hex: Cursor's chat bucket name.
pub fn md5_hex(s: &str) -> String {
    Md5::digest(s.as_bytes()).iter().map(|b| format!("{b:02x}")).collect()
}

/// Names Cursor gives a chat before it has a real one. Showing these would
/// be worse than the branch fallback: every fresh pane would read "New Agent".
pub fn is_placeholder_title(title: &str) -> bool {
    matches!(title.trim().to_lowercase().as_str(), "" | "new agent" | "new chat" | "untitled")
}

/// The chat name in a `store.db` `meta['0']` value: hex-encoded JSON, or
/// plain JSON should a future Cursor drop the hex wrapper.
pub fn name_from_store_value(value: &str) -> Option<String> {
    [hex_decode(value), Some(value.as_bytes().to_vec())].into_iter().flatten().find_map(|bytes| {
        let obj: Value = serde_json::from_slice(&bytes).ok()?;
        obj.get("name")?.as_str().map(str::to_string)
    })
}

struct Meta {
    title: Option<String>,
    cwd: String,
    updated_at: Option<SystemTime>,
}

fn read_meta(path: &Path) -> Option<Meta> {
    let obj: Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    let obj = obj.as_object()?;
    let updated_at = obj
        .get("updatedAtMs")
        .and_then(Value::as_f64)
        .map(|ms| SystemTime::UNIX_EPOCH + std::time::Duration::from_secs_f64((ms / 1000.0).max(0.0)));
    Some(Meta {
        title: obj.get("title").and_then(Value::as_str).map(str::to_string),
        cwd: obj.get("cwd").and_then(Value::as_str).unwrap_or("").to_string(),
        updated_at,
    })
}

/// `meta.json`'s title if the IDE wrote one, else the CLI's `store.db` name.
fn chat_title(chat_dir: &Path, meta: Option<&Meta>) -> Option<String> {
    usable(meta.and_then(|m| m.title.as_deref())).or_else(|| usable(store_name(&chat_dir.join("store.db")).as_deref()))
}

fn usable(raw: Option<&str>) -> Option<String> {
    let title = raw?.trim();
    (!title.is_empty() && !is_placeholder_title(title)).then(|| title.to_string())
}

/// `meta['0'].name` from a chat's `store.db`. The CLI may hold the database
/// open, so this must never block on it: read-only, a 50 ms busy timeout,
/// and every failure is simply None.
fn store_name(path: &Path) -> Option<String> {
    if !path.is_file() {
        return None;
    }
    let conn = rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    conn.busy_timeout(std::time::Duration::from_millis(50)).ok()?;
    let value: String = conn.query_row("SELECT value FROM meta WHERE key = '0' LIMIT 1", [], |row| row.get(0)).ok()?;
    name_from_store_value(&value)
}

fn hex_decode(hex: &str) -> Option<Vec<u8>> {
    let bytes = hex.as_bytes();
    if bytes.is_empty() || !bytes.len().is_multiple_of(2) {
        return None;
    }
    let nibble = |b: u8| (b as char).to_digit(16).map(|d| d as u8);
    bytes.chunks(2).map(|pair| Some(nibble(pair[0])? << 4 | nibble(pair[1])?)).collect()
}

fn is_hidden(p: &Path) -> bool {
    p.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.'))
}

fn modified(p: &Path) -> Option<SystemTime> {
    std::fs::metadata(p).ok()?.modified().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    // SessionTitleLookupTests

    struct Root(tempfile::TempDir);

    impl Root {
        fn new() -> Self {
            Root(tempfile::tempdir().unwrap())
        }
        fn path(&self) -> &Path {
            self.0.path()
        }
        fn project_dir(&self, wt: &str) -> PathBuf {
            let dir = self.path().join(encoded_project_component(wt));
            std::fs::create_dir_all(&dir).unwrap();
            dir
        }
    }

    fn set_mtime(path: &Path, offset: i64) {
        let t = SystemTime::now() + Duration::from_secs(offset as u64);
        std::fs::File::options().write(true).open(path).unwrap().set_modified(t).unwrap();
    }

    #[test]
    fn test_live_transcript_is_not_rescanned_within_the_interval() {
        let root = Root::new();
        let wt = "/Users/me/repo-worktrees/live-x";
        let url = root.project_dir(wt).join("sess-live.jsonl");
        let mut cache = TitleCache::new();
        cache.rescan_interval = 30.0;
        std::fs::write(&url, r#"{"type":"summary","summary":"Before"}"#).unwrap();
        assert_eq!(cache.claude_in(root.path(), wt, "sess-live", 100.0).as_deref(), Some("Before"));

        std::fs::write(&url, r#"{"type":"summary","summary":"After"}"#).unwrap();
        set_mtime(&url, 5);
        assert_eq!(
            cache.claude_in(root.path(), wt, "sess-live", 101.0).as_deref(),
            Some("Before"),
            "a change inside the interval is not re-read"
        );
        cache.rescan_interval = 0.0;
        assert_eq!(
            cache.claude_in(root.path(), wt, "sess-live", 102.0).as_deref(),
            Some("After"),
            "once the interval has passed the change is picked up"
        );
    }

    #[test]
    fn test_rereads_after_transcript_changes() {
        let root = Root::new();
        let wt = "/Users/me/repo-worktrees/cache-x";
        let url = root.project_dir(wt).join("sess-1.jsonl");
        let mut cache = TitleCache::new();
        cache.rescan_interval = 0.0;
        std::fs::write(&url, r#"{"type":"summary","summary":"Before"}"#).unwrap();
        assert_eq!(cache.claude_in(root.path(), wt, "sess-1", 1.0).as_deref(), Some("Before"));
        assert_eq!(cache.claude_in(root.path(), wt, "sess-1", 1.0).as_deref(), Some("Before"));
        std::fs::write(&url, "{\"type\":\"summary\",\"summary\":\"Before\"}\n{\"type\":\"summary\",\"summary\":\"After\"}").unwrap();
        set_mtime(&url, 5);
        assert_eq!(cache.claude_in(root.path(), wt, "sess-1", 1.0).as_deref(), Some("After"));
    }

    #[test]
    fn test_returns_last_summary() {
        let root = Root::new();
        let wt = "/Users/me/repo-worktrees/feature-x";
        let lines = [
            r#"{"type":"summary","summary":"First title"}"#,
            r#"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            r#"{"type":"summary","summary":"Refactor the parser"}"#,
        ]
        .join("\n");
        std::fs::write(root.project_dir(wt).join("s1.jsonl"), lines).unwrap();
        assert_eq!(claude_latest_in(root.path(), wt).as_deref(), Some("Refactor the parser"));
    }

    #[test]
    fn test_title_by_session_id_picks_that_session_not_the_newest_one() {
        let root = Root::new();
        let wt = "/Users/me/repo-worktrees/two-agents";
        let dir = root.project_dir(wt);
        std::fs::write(dir.join("older.jsonl"), r#"{"type":"ai-title","aiTitle":"Older agent"}"#).unwrap();
        std::fs::write(dir.join("newer.jsonl"), r#"{"type":"ai-title","aiTitle":"Newer agent"}"#).unwrap();
        assert_eq!(claude_in(root.path(), wt, "older").as_deref(), Some("Older agent"));
        assert_eq!(claude_in(root.path(), wt, "newer").as_deref(), Some("Newer agent"));
    }

    #[test]
    fn test_title_by_session_id_misses_gracefully() {
        let root = Root::new();
        let wt = "/Users/me/repo-worktrees/none";
        root.project_dir(wt);
        assert_eq!(claude_in(root.path(), wt, "ghost"), None);
        assert_eq!(claude_in(root.path(), wt, "../../escape"), None);
    }

    #[test]
    fn test_returns_ai_title_from_modern_session_format() {
        let root = Root::new();
        let wt = "/Users/me/repo-worktrees/feature-ai";
        let lines = [
            r#"{"type":"mode","mode":"normal","sessionId":"abc"}"#,
            r#"{"type":"ai-title","aiTitle":"测试 all-in-one 本地部署","sessionId":"abc"}"#,
            r#"{"type":"user","message":{"role":"user","content":"hi"}}"#,
        ]
        .join("\n");
        std::fs::write(root.project_dir(wt).join("s1.jsonl"), lines).unwrap();
        assert_eq!(claude_latest_in(root.path(), wt).as_deref(), Some("测试 all-in-one 本地部署"));
    }

    #[test]
    fn test_custom_title_wins_over_ai_title() {
        let root = Root::new();
        let wt = "/Users/me/repo-worktrees/feature-custom";
        let lines = [r#"{"type":"ai-title","aiTitle":"AI title"}"#, r#"{"type":"custom-title","customTitle":"My name"}"#].join("\n");
        std::fs::write(root.project_dir(wt).join("s1.jsonl"), lines).unwrap();
        assert_eq!(claude_latest_in(root.path(), wt).as_deref(), Some("My name"));
    }

    #[test]
    fn test_returns_nil_when_no_summary() {
        let root = Root::new();
        let wt = "/Users/me/repo-worktrees/feature-y";
        std::fs::write(root.project_dir(wt).join("s1.jsonl"), r#"{"type":"user","message":{"role":"user","content":"hi"}}"#).unwrap();
        assert_eq!(claude_latest_in(root.path(), wt), None);
    }

    #[test]
    fn test_returns_nil_when_dir_missing() {
        let root = Root::new();
        assert_eq!(claude_latest_in(root.path(), "/nope/missing"), None);
    }

    #[test]
    fn test_encoding_replaces_slashes_and_dots() {
        assert_eq!(encoded_project_component("/Users/me/repo.app/feature"), "-Users-me-repo-app-feature");
    }

    #[test]
    fn a_quoted_marker_inside_a_message_does_not_count() {
        let root = Root::new();
        let wt = "/w";
        let lines = [
            r#"{"type":"summary","summary":"Real"}"#,
            r#"{"type":"user","message":"see \"type\":\"summary\" here","summary":"Fake"}"#,
        ]
        .join("\n");
        std::fs::write(root.project_dir(wt).join("s.jsonl"), lines).unwrap();
        assert_eq!(claude_in(root.path(), wt, "s").as_deref(), Some("Real"));
    }

    // CodexSessionPromptLookup

    #[test]
    fn codex_prompt_is_the_last_user_message_of_the_session() {
        let root = tempfile::tempdir().unwrap();
        let day = root.path().join("2026/11/03");
        std::fs::create_dir_all(&day).unwrap();
        let lines = [
            r#"{"type":"event_msg","payload":{"type":"user_message","message":"first"}}"#,
            r#"{"type":"event_msg","payload":{"type":"agent_message","message":"reply"}}"#,
            r#"{"type":"event_msg","payload":{"type":"user_message","message":"second"}}"#,
        ]
        .join("\n");
        std::fs::write(day.join("rollout-2026-11-03-abc-123.jsonl"), lines).unwrap();
        assert_eq!(codex_prompt_in(root.path(), "abc-123").as_deref(), Some("second"));
        assert_eq!(codex_prompt_in(root.path(), "missing"), None);
        assert_eq!(codex_prompt_in(root.path(), ""), None);
    }

    // CursorSessionTitleLookupTests

    fn write_meta(bucket: &Path, chat: &str, title: Option<&str>, cwd: &str, updated_ms: i64) {
        let dir = bucket.join(chat);
        std::fs::create_dir_all(&dir).unwrap();
        let mut obj = serde_json::json!({"schemaVersion": 1, "cwd": cwd, "updatedAtMs": updated_ms});
        if let Some(t) = title {
            obj["title"] = t.into();
        }
        std::fs::write(dir.join("meta.json"), obj.to_string()).unwrap();
    }

    /// Mirrors `cursor-agent`'s store: one `meta` row, key `'0'`, value =
    /// hex of the chat JSON.
    fn write_store(bucket: &Path, chat: &str, name: &str) {
        let dir = bucket.join(chat);
        std::fs::create_dir_all(&dir).unwrap();
        let json = serde_json::json!({"agentId": chat, "name": name}).to_string();
        let hex: String = json.bytes().map(|b| format!("{b:02x}")).collect();
        let conn = rusqlite::Connection::open(dir.join("store.db")).unwrap();
        conn.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)", []).unwrap();
        conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('0', ?1)", [hex]).unwrap();
    }

    const WT: &str = "/Users/me/proj";

    fn bucket(root: &Path) -> PathBuf {
        root.join(md5_hex(WT))
    }

    #[test]
    fn test_title_picks_newest_matching_chat() {
        let root = tempfile::tempdir().unwrap();
        write_meta(&bucket(root.path()), "old", Some("Older"), WT, 1_000);
        write_meta(&bucket(root.path()), "new", Some("Newer Title"), WT, 2_000);
        assert_eq!(cursor_latest_in(root.path(), WT).as_deref(), Some("Newer Title"));
    }

    #[test]
    fn test_title_by_session_id() {
        let root = tempfile::tempdir().unwrap();
        write_meta(&bucket(root.path()), "abc-123", Some("Exact Chat"), WT, 1);
        assert_eq!(cursor_in(root.path(), WT, "abc-123").as_deref(), Some("Exact Chat"));
        assert_eq!(cursor_in(root.path(), WT, "missing"), None);
    }

    #[test]
    fn test_md5_matches_known_cursor_bucket() {
        assert_eq!(md5_hex("/Users/liziliu/Documents/banana-git/saas-mono"), "bbcf5935e8845c2e4cef8ceea135e8af");
    }

    #[test]
    fn test_title_from_store_db_when_meta_has_no_title() {
        let root = tempfile::tempdir().unwrap();
        write_meta(&bucket(root.path()), "cli-chat", None, WT, 5);
        write_store(&bucket(root.path()), "cli-chat", "Fix the flaky test");
        assert_eq!(cursor_in(root.path(), WT, "cli-chat").as_deref(), Some("Fix the flaky test"));
        assert_eq!(cursor_latest_in(root.path(), WT).as_deref(), Some("Fix the flaky test"));
    }

    #[test]
    fn test_store_db_rename_is_picked_up() {
        let root = tempfile::tempdir().unwrap();
        write_meta(&bucket(root.path()), "cli-chat", None, WT, 5);
        write_store(&bucket(root.path()), "cli-chat", "First Name");
        assert_eq!(cursor_in(root.path(), WT, "cli-chat").as_deref(), Some("First Name"));
        write_store(&bucket(root.path()), "cli-chat", "Renamed Mid Session");
        assert_eq!(cursor_in(root.path(), WT, "cli-chat").as_deref(), Some("Renamed Mid Session"));
    }

    #[test]
    fn test_placeholder_store_name_falls_through() {
        let root = tempfile::tempdir().unwrap();
        write_meta(&bucket(root.path()), "fresh", None, WT, 5);
        write_store(&bucket(root.path()), "fresh", "New Agent");
        assert_eq!(cursor_in(root.path(), WT, "fresh"), None);
        assert_eq!(cursor_latest_in(root.path(), WT), None);
    }

    #[test]
    fn test_sibling_cli_chats_do_not_cross_contaminate() {
        let root = tempfile::tempdir().unwrap();
        let b = bucket(root.path());
        write_meta(&b, "pane-a", None, WT, 10);
        write_store(&b, "pane-a", "Pane A Work");
        write_meta(&b, "pane-b", None, WT, 20);
        write_store(&b, "pane-b", "Pane B Work");
        assert_eq!(cursor_in(root.path(), WT, "pane-a").as_deref(), Some("Pane A Work"));
        assert_eq!(cursor_in(root.path(), WT, "pane-b").as_deref(), Some("Pane B Work"));
    }

    #[test]
    fn test_meta_json_title_wins_over_store_name() {
        let root = tempfile::tempdir().unwrap();
        write_meta(&bucket(root.path()), "both", Some("IDE Title"), WT, 5);
        write_store(&bucket(root.path()), "both", "Store Name");
        assert_eq!(cursor_in(root.path(), WT, "both").as_deref(), Some("IDE Title"));
    }

    #[test]
    fn test_store_value_accepts_hex_and_plain_json() {
        let json = r#"{"agentId":"x","name":"Hexed"}"#;
        let hex: String = json.bytes().map(|b| format!("{b:02x}")).collect();
        assert_eq!(name_from_store_value(&hex).as_deref(), Some("Hexed"));
        assert_eq!(name_from_store_value(r#"{"name":"Plain"}"#).as_deref(), Some("Plain"));
        assert_eq!(name_from_store_value("not json"), None);
    }
}
