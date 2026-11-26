//! Read the ordered messages Cursor keeps for one chat.
//!
//! Cursor Agent writes `~/.cursor/chats/<md5(cwd)>/<conversation-id>/store.db`.
//! `meta['0']` is hex-encoded JSON whose `latestRootBlobId` points at a
//! protobuf list of SHA-256 blob ids. The referenced JSON message blobs retain
//! the order Cursor used in the conversation, including assistant text and
//! tool calls. The database may be open in WAL mode while we read it, so every
//! operation uses a short, read-only SQLite snapshot and degrades to `None`.

use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, OpenFlags, TransactionBehavior};
use serde_json::Value;

use crate::titles::md5_hex;

const BUSY_TIMEOUT: Duration = Duration::from_millis(50);
const MAX_ROOT_BYTES: usize = 8 * 1024 * 1024;
const MAX_ROOT_REFERENCES: usize = 50_000;

#[derive(Clone, Debug, PartialEq)]
pub struct Message {
    /// Content-addressed blob hash; Cursor's JSON message id is not unique.
    pub id: String,
    pub role: String,
    pub content: Value,
}

/// The chat store for one Cursor `conversation_id`, when it is readable.
///
/// `chats_root` is normally `~/.cursor/chats`; taking it as an argument keeps
/// the reader testable and lets callers isolate alternate Cursor profiles.
pub fn read_messages(chats_root: &Path, cwd: &str, conversation_id: &str) -> Option<Vec<Message>> {
    read_incremental(chats_root, cwd, conversation_id, None).map(|batch| batch.messages)
}

#[derive(Clone, Debug, PartialEq)]
pub struct Checkpoint { pub position: usize, pub hash: String }
pub struct Batch { pub messages: Vec<Message>, pub checkpoint: Option<Checkpoint> }

pub fn read_incremental(chats_root: &Path, cwd: &str, conversation_id: &str, checkpoint: Option<&Checkpoint>) -> Option<Batch> {
    if cwd.is_empty() || !safe_component(conversation_id) {
        return None;
    }
    let path = chat_store_path(chats_root, cwd, conversation_id);
    if !path.is_file() {
        return None;
    }

    let mut db = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    db.busy_timeout(BUSY_TIMEOUT).ok()?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Deferred).ok()?;
    let metadata: String = tx.query_row("SELECT value FROM meta WHERE key = '0' LIMIT 1", [], |row| row.get(0)).ok()?;
    let metadata = decode_metadata(&metadata)?;
    let root_id = metadata.get("latestRootBlobId")?.as_str()?;
    if !is_hash(root_id) {
        return None;
    }
    let root: Vec<u8> = tx.query_row("SELECT data FROM blobs WHERE id = ?1 AND length(data) <= 8388608", [root_id], |row| row.get(0)).ok()?;
    let references = root_references(&root)?;

    let start = match checkpoint {
        Some(previous) if references.get(previous.position) == Some(&previous.hash) => previous.position + 1,
        // Compaction may move the checkpoint. A unique content hash still
        // identifies it; absent or ambiguous anchors baseline the new list.
        Some(previous) => {
            let matches: Vec<_> = references.iter().enumerate().filter(|(_, hash)| *hash == &previous.hash).map(|(index, _)| index).collect();
            if matches.len() == 1 { matches[0] + 1 } else { references.len() }
        },
        None => 0,
    };
    let next = references.last().map(|hash| Checkpoint { position: references.len() - 1, hash: hash.clone() });
    let mut statement = tx.prepare_cached("SELECT data FROM blobs WHERE id = ?1 AND length(data) <= 1048576").ok()?;
    let mut messages = Vec::new();
    for blob_id in references.into_iter().skip(start) {
        let Ok(bytes) = statement.query_row([&blob_id], |row| row.get::<_, Vec<u8>>(0)) else { continue };
        let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(&bytes) else { continue };
        let Some(role) = object.get("role").and_then(Value::as_str) else { continue };
        if !matches!(role, "user" | "assistant" | "tool" | "system") {
            continue;
        }
        let id = blob_id;
        let content = object.get("content").cloned().unwrap_or(Value::Null);
        messages.push(Message { id, role: role.to_string(), content });
    }
    Some(Batch { messages, checkpoint: next })
}

pub fn chat_store_path(chats_root: &Path, cwd: &str, conversation_id: &str) -> PathBuf {
    chats_root.join(md5_hex(cwd)).join(conversation_id).join("store.db")
}

/// Copy one Cursor chat so another directory can resume it, and return the
/// copy's id: Cursor Agent has no `--fork-session`, and `agent --resume <id>`
/// only finds a chat filed under the md5 of the directory it starts in (from
/// anywhere else it opens an empty chat under that id). So the store is copied
/// into `<md5(into_cwd)>/<new id>/`, its `agentId` rewritten, and `meta.json`
/// pointed at the new directory; the original chat is not touched.
///
/// `into_cwd` must be the directory as Cursor will see it (`getcwd`, symlinks
/// resolved). The snapshot is taken through SQLite (`VACUUM INTO`), so a store
/// Cursor still holds open in WAL mode copies whole. An error names what
/// failed: a fork that silently resumed an empty chat would be worse.
pub fn fork_chat(chats_root: &Path, conversation_id: &str, into_cwd: &str) -> Result<String, String> {
    if !safe_component(conversation_id) {
        return Err(format!("not a Cursor chat id: {conversation_id}"));
    }
    if into_cwd.is_empty() {
        return Err("no directory to fork the Cursor chat into".into());
    }
    let source = find_chat(chats_root, conversation_id)
        .ok_or_else(|| format!("Cursor chat {conversation_id} not found under {}", chats_root.display()))?;
    let bucket = chats_root.join(md5_hex(into_cwd));
    let (new_id, dir) = loop {
        let id = new_chat_id();
        let dir = bucket.join(&id);
        if !dir.exists() { break (id, dir); }
    };
    let staging = bucket.join(format!(".{new_id}.forking"));
    std::fs::create_dir_all(&staging).map_err(|e| format!("create {}: {e}", staging.display()))?;
    let result = copy_store(&source, &staging, conversation_id, &new_id, into_cwd)
        .and_then(|()| std::fs::rename(&staging, &dir).map_err(|e| format!("move the copy into place: {e}")));
    if result.is_err() {
        let _ = std::fs::remove_dir_all(&staging);
    }
    result.map(|()| new_id)
}

/// `<chats_root>/<any bucket>/<id>/store.db`, the most recently written when
/// several directories hold the id (a resume from elsewhere makes an empty one).
fn find_chat(chats_root: &Path, conversation_id: &str) -> Option<PathBuf> {
    std::fs::read_dir(chats_root).ok()?
        .filter_map(Result::ok)
        .map(|bucket| bucket.path().join(conversation_id))
        .filter(|dir| dir.join("store.db").is_file())
        .max_by_key(|dir| last_write(dir))
}

fn last_write(dir: &Path) -> std::time::SystemTime {
    ["store.db-wal", "store.db"].iter()
        .filter_map(|f| std::fs::metadata(dir.join(f)).and_then(|m| m.modified()).ok())
        .max()
        .unwrap_or(std::time::UNIX_EPOCH)
}

fn copy_store(source: &Path, staging: &Path, old_id: &str, new_id: &str, into_cwd: &str) -> Result<(), String> {
    let db = Connection::open_with_flags(source.join("store.db"), OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| format!("open the Cursor chat: {e}"))?;
    db.busy_timeout(Duration::from_secs(2)).map_err(|e| e.to_string())?;
    let target = staging.join("store.db");
    db.execute("VACUUM INTO ?1", [target.to_string_lossy()]).map_err(|e| format!("copy the Cursor chat: {e}"))?;
    drop(db);

    let copy = Connection::open(&target).map_err(|e| format!("open the copy: {e}"))?;
    let raw: String = copy.query_row("SELECT value FROM meta WHERE key = '0'", [], |row| row.get(0))
        .map_err(|e| format!("read the chat's metadata: {e}"))?;
    let mut meta = decode_metadata(&raw).ok_or("the chat's metadata is not in a form seahelm knows")?;
    if meta.get("agentId").and_then(Value::as_str) != Some(old_id) {
        return Err("the chat's metadata does not name the chat (Cursor's store format changed?)".into());
    }
    meta["agentId"] = Value::from(new_id);
    let json = meta.to_string();
    // Written back in the shape it was read in.
    let value = if serde_json::from_str::<Value>(&raw).is_ok() { json } else { json.bytes().map(|b| format!("{b:02x}")).collect() };
    copy.execute("UPDATE meta SET value = ?1 WHERE key = '0'", [value]).map_err(|e| format!("write the copy's metadata: {e}"))?;
    drop(copy);

    let mut sidecar = std::fs::read(source.join("meta.json")).ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| serde_json::json!({"schemaVersion": 1, "hasConversation": true}));
    sidecar["cwd"] = Value::from(into_cwd);
    std::fs::write(staging.join("meta.json"), sidecar.to_string()).map_err(|e| format!("write meta.json: {e}"))
}

/// A random UUID v4, as Cursor names its chats.
fn new_chat_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut bytes = [0u8; 16];
    for (i, chunk) in bytes.chunks_mut(8).enumerate() {
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_usize(i);
        h.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
        h.write_u32(std::process::id());
        chunk.copy_from_slice(&h.finish().to_le_bytes());
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32])
}

fn safe_component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn is_hash(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit())
}

fn decode_metadata(value: &str) -> Option<Value> {
    serde_json::from_str(value).ok().or_else(|| {
        let bytes = decode_hex(value)?;
        serde_json::from_slice(&bytes).ok()
    })
}

fn decode_hex(value: &str) -> Option<Vec<u8>> {
    if value.is_empty() || value.len() % 2 != 0 {
        return None;
    }
    value.as_bytes().chunks_exact(2).map(|pair| Some((nibble(pair[0])? << 4) | nibble(pair[1])?)).collect()
}

fn nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// Cursor's root protobuf stores the ordered message blob ids in repeated
/// field 1, each as a 32-byte length-delimited value.
fn root_references(root: &[u8]) -> Option<Vec<String>> {
    if root.is_empty() || root.len() > MAX_ROOT_BYTES {
        return None;
    }
    let mut index = 0;
    let mut references = Vec::new();
    while index < root.len() {
        let tag = read_varint(root, &mut index)?;
        let field = tag >> 3;
        let wire = tag & 7;
        match wire {
            0 => {
                read_varint(root, &mut index)?;
            }
            1 => index = index.checked_add(8).filter(|end| *end <= root.len())?,
            2 => {
                let length = usize::try_from(read_varint(root, &mut index)?).ok()?;
                let end = index.checked_add(length).filter(|end| *end <= root.len())?;
                if field == 1 && length == 32 {
                    if references.len() == MAX_ROOT_REFERENCES {
                        return None;
                    }
                    references.push(root[index..end].iter().map(|byte| format!("{byte:02x}")).collect());
                }
                index = end;
            }
            5 => index = index.checked_add(4).filter(|end| *end <= root.len())?,
            _ => return None,
        }
    }
    Some(references)
}

fn read_varint(bytes: &[u8], index: &mut usize) -> Option<u64> {
    let mut value = 0_u64;
    let mut shift = 0;
    loop {
        let byte = *bytes.get(*index)?;
        *index += 1;
        if shift == 63 && byte > 1 { return None; }
        value |= u64::from(byte & 0x7f).checked_shl(shift)?;
        if byte & 0x80 == 0 {
            return Some(value);
        }
        shift += 7;
        if shift >= 64 {
            return None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const CWD: &str = "/Users/test/worktree";
    const CHAT: &str = "8c61631b-0673-4ad6-a49b-0cfc83896aa9";
    const USER: &str = include_str!("../tests/fixtures/cursor-user-message.json");
    const ASSISTANT: &str = include_str!("../tests/fixtures/cursor-assistant-message.json");
    const TOOL: &str = include_str!("../tests/fixtures/cursor-tool-message.json");

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn append_reference(root: &mut Vec<u8>, id: &[u8; 32]) {
        root.extend_from_slice(&[0x0a, 0x20]);
        root.extend_from_slice(id);
    }

    fn setup_store(root: &Path) -> (Connection, Vec<u8>) {
        let path = chat_store_path(root, CWD, CHAT);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let db = Connection::open(path).unwrap();
        db.execute_batch("PRAGMA journal_mode = WAL; CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT); CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);").unwrap();

        let entries = [([1; 32], USER.as_bytes()), ([2; 32], ASSISTANT.as_bytes()), ([3; 32], TOOL.as_bytes())];
        let mut root_blob = Vec::new();
        for (id, data) in entries {
            db.execute("INSERT INTO blobs (id, data) VALUES (?1, ?2)", rusqlite::params![hex(&id), data]).unwrap();
            append_reference(&mut root_blob, &id);
        }
        let root_id = [4; 32];
        let metadata = json!({"agentId": CHAT, "latestRootBlobId": hex(&root_id)}).to_string();
        let encoded: String = metadata.bytes().map(|byte| format!("{byte:02x}")).collect();
        db.execute("INSERT INTO meta (key, value) VALUES ('0', ?1)", [&encoded]).unwrap();
        db.execute("INSERT INTO blobs (id, data) VALUES (?1, ?2)", rusqlite::params![hex(&root_id), root_blob]).unwrap();
        (db, root_blob)
    }

    #[test]
    fn a_forked_chat_is_a_copy_under_a_new_id_in_the_new_directory() {
        let root = tempfile::tempdir().unwrap();
        let (_writer, _) = setup_store(root.path());
        let src_dir = chat_store_path(root.path(), CWD, CHAT).parent().unwrap().to_path_buf();
        std::fs::write(src_dir.join("meta.json"), json!({"schemaVersion": 1, "title": "Fix it", "cwd": CWD}).to_string()).unwrap();
        let into = "/Users/test/worktree-b";

        let id = fork_chat(root.path(), CHAT, into).unwrap();
        assert_ne!(id, CHAT);
        assert!(safe_component(&id) && id.len() == 36 && id.as_bytes()[14] == b'4');
        // The copy reads as the same conversation, from its new home.
        let messages = read_messages(root.path(), into, &id).unwrap();
        assert_eq!(messages.iter().map(|m| m.role.as_str()).collect::<Vec<_>>(), ["user", "assistant", "tool"]);
        let db = Connection::open(chat_store_path(root.path(), into, &id)).unwrap();
        let raw: String = db.query_row("SELECT value FROM meta WHERE key = '0'", [], |r| r.get(0)).unwrap();
        assert_eq!(decode_metadata(&raw).unwrap()["agentId"], id.as_str());
        let sidecar: Value = serde_json::from_slice(&std::fs::read(chat_store_path(root.path(), into, &id).with_file_name("meta.json")).unwrap()).unwrap();
        assert_eq!((sidecar["cwd"].as_str(), sidecar["title"].as_str()), (Some(into), Some("Fix it")));
        // The original is untouched, and no staging directory is left behind.
        assert_eq!(read_messages(root.path(), CWD, CHAT).unwrap().len(), 3);
        let left: Vec<_> = std::fs::read_dir(root.path().join(md5_hex(into))).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(left, [std::ffi::OsString::from(&id)]);
    }

    #[test]
    fn forking_a_missing_or_unknown_chat_says_so() {
        let root = tempfile::tempdir().unwrap();
        assert!(fork_chat(root.path(), CHAT, "/x").unwrap_err().contains("not found"));
        assert!(fork_chat(root.path(), "../etc", "/x").unwrap_err().contains("not a Cursor chat id"));
        let (writer, _) = setup_store(root.path());
        writer.execute("UPDATE meta SET value = ?1 WHERE key = '0'", [json!({"agentId": "someone-else"}).to_string()]).unwrap();
        assert!(fork_chat(root.path(), CHAT, "/x").unwrap_err().contains("does not name the chat"));
        assert!(!root.path().join(md5_hex("/x")).read_dir().unwrap().any(|_| true));
    }

    #[test]
    fn reads_assistant_messages_in_root_order_from_a_live_wal_store_read_only() {
        let root = tempfile::tempdir().unwrap();
        let (_writer, _) = setup_store(root.path());
        let messages = read_messages(root.path(), CWD, CHAT).unwrap();
        assert_eq!(messages.iter().map(|message| message.role.as_str()).collect::<Vec<_>>(), ["user", "assistant", "tool"]);
        assert_eq!(messages[1].id, hex(&[2; 32]));
        assert_eq!(messages[1].content[1]["text"], "I'll inspect the timeline.");
        assert!(!safe_component("../outside"));
    }

    #[test]
    fn reads_new_commits_while_cursor_keeps_the_wal_writer_open() {
        let root = tempfile::tempdir().unwrap();
        let (writer, mut root_blob) = setup_store(root.path());
        assert_eq!(read_messages(root.path(), CWD, CHAT).unwrap().len(), 3);
        let next = json!({"id": "msg-next", "role": "assistant", "content": [{"type": "text", "text": "Found the cause."}]}).to_string();
        writer.execute("INSERT INTO blobs (id, data) VALUES (?1, ?2)", rusqlite::params![hex(&[5; 32]), next.as_bytes()]).unwrap();
        append_reference(&mut root_blob, &[5; 32]);
        writer.execute("UPDATE blobs SET data = ?1 WHERE id = ?2", rusqlite::params![root_blob, hex(&[4; 32])]).unwrap();
        let messages = read_messages(root.path(), CWD, CHAT).unwrap();
        assert_eq!(messages.len(), 4);
        assert_eq!(messages.last().unwrap().id, hex(&[5; 32]));
    }

    #[test]
    fn duplicate_cursor_ids_use_root_position_and_blob_hash() {
        let root = tempfile::tempdir().unwrap();
        let (writer, mut root_blob) = setup_store(root.path());
        let first = read_incremental(root.path(), CWD, CHAT, None).unwrap();
        assert_eq!(first.checkpoint.as_ref().unwrap().position, 2);
        assert!(read_incremental(root.path(), CWD, CHAT, first.checkpoint.as_ref()).unwrap().messages.is_empty());
        let next = json!({"id": "1", "role": "assistant", "content": "new prose"}).to_string();
        writer.execute("INSERT INTO blobs (id, data) VALUES (?1, ?2)", rusqlite::params![hex(&[5; 32]), next.as_bytes()]).unwrap();
        append_reference(&mut root_blob, &[5; 32]);
        writer.execute("UPDATE blobs SET data=?1 WHERE id=?2", rusqlite::params![root_blob, hex(&[4; 32])]).unwrap();
        let next = read_incremental(root.path(), CWD, CHAT, first.checkpoint.as_ref()).unwrap();
        assert_eq!(next.messages.len(), 1);
        assert_eq!(next.messages[0].content, "new prose");
        let rewritten = Checkpoint { position: 2, hash: hex(&[99; 32]) };
        assert!(read_incremental(root.path(), CWD, CHAT, Some(&rewritten)).unwrap().messages.is_empty());
    }

    #[test]
    fn twenty_assistant_messages_with_the_same_json_id_are_not_skipped() {
        let root = tempfile::tempdir().unwrap();
        let (writer, mut root_blob) = setup_store(root.path());
        let mut checkpoint = read_incremental(root.path(), CWD, CHAT, None).unwrap().checkpoint;
        for i in 10..30_u8 {
            let message = json!({"id": "1", "role": "assistant", "content": format!("prose-{i}")}).to_string();
            writer.execute("INSERT INTO blobs (id,data) VALUES (?1,?2)", rusqlite::params![hex(&[i; 32]), message.as_bytes()]).unwrap();
            append_reference(&mut root_blob, &[i; 32]);
            writer.execute("UPDATE blobs SET data=?1 WHERE id=?2", rusqlite::params![&root_blob, hex(&[4; 32])]).unwrap();
            let batch = read_incremental(root.path(), CWD, CHAT, checkpoint.as_ref()).unwrap();
            assert_eq!(batch.messages.len(), 1);
            assert_eq!(batch.messages[0].content, format!("prose-{i}"));
            checkpoint = batch.checkpoint;
        }
    }

    #[test]
    fn refuses_bad_chat_ids_and_unreadable_stores() {
        let root = tempfile::tempdir().unwrap();
        assert!(read_messages(root.path(), CWD, "../chat").is_none());
        assert!(read_messages(root.path(), CWD, CHAT).is_none());
    }

    #[test]
    fn rejects_malformed_root_protobuf() {
        assert!(root_references(&[0x0a, 0x20, 0x01]).is_none());
        assert!(root_references(&[0x0f]).is_none());
    }
}
