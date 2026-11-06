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
