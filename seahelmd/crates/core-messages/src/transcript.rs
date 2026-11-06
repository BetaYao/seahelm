//! An agent's prose, read from its own transcript as the file grows
//! (`AgentTranscriptTail.swift`). Hooks carry tool calls and the turn's
//! final message, but not what the agent writes between tool calls — the
//! part that says what it is doing and why. Claude Code and Codex append
//! every message to a JSONL transcript whose path comes with each hook.
//! Cursor Agent keeps ordered JSON messages behind a protobuf root in its
//! SQLite chat store; tool hooks trigger read-only reads of that store.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};

use serde_json::Value;

use seahelm_core_hooks::suggest::strip_sentinel;
use seahelm_core_hooks::cursor_store::{self, Message as CursorMessage};
use seahelm_core_types::Timestamp;

#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    /// Visible thinking or a reasoning summary, rather than what it says.
    pub thinking: bool,
    pub text: String,
    pub timestamp: Option<Timestamp>,
}

pub struct Tail {
    /// How much of a transcript seen for the first time is read: a long
    /// session is not replayed, only its recent end newer than `since`.
    first_read: u64,
    offsets: HashMap<String, u64>,
}

/// Cursor's ordered, SQLite-backed chat store has a stable message id rather
/// than a JSONL byte offset. Keep one checkpoint per chat while the core runs.
#[derive(Default)]
pub struct CursorTail {
    seen: HashMap<String, String>,
}

impl CursorTail {
    /// New visible assistant prose in this Cursor chat, in chat-store order.
    /// On a first read, start after the latest user message so a resumed chat
    /// does not replay its earlier turns. A SessionStart takes a baseline at
    /// the current end when the store already contains history.
    pub fn new_prose(&mut self, chats_root: &std::path::Path, cwd: &str, chat_id: &str, session_start: bool) -> Vec<Entry> {
        let Some(messages) = cursor_store::read_messages(chats_root, cwd, chat_id) else { return Vec::new() };
        self.advance(&format!("{cwd}\0{chat_id}"), &messages, session_start)
    }

    fn advance(&mut self, key: &str, messages: &[CursorMessage], session_start: bool) -> Vec<Entry> {
        let start = if let Some(last_id) = self.seen.get(key) {
            messages.iter().rposition(|message| &message.id == last_id).map(|i| i + 1).unwrap_or_else(|| {
                messages.iter().rposition(|message| message.role == "user").map(|i| i + 1).unwrap_or(messages.len())
            })
        } else if session_start {
            messages.len()
        } else {
            messages.iter().rposition(|message| message.role == "user").map(|i| i + 1).unwrap_or(messages.len())
        };
        if let Some(last) = messages.last() {
            self.seen.insert(key.to_string(), last.id.clone());
        }
        messages[start..].iter().filter_map(cursor_message_prose).collect()
    }
}

impl Default for Tail {
    fn default() -> Self {
        Self::new(256_000)
    }
}

impl Tail {
    pub fn new(first_read: u64) -> Self {
        Tail { first_read, offsets: HashMap::new() }
    }

    /// Prose appended to `path` since the last call for it, in file order.
    /// The first call for a path, or one after the file was replaced by a
    /// shorter one, returns only entries stamped after `since`.
    pub fn new_prose(&mut self, path: &str, since: Timestamp) -> Vec<Entry> {
        let Ok(mut f) = std::fs::File::open(path) else { return Vec::new() };
        let Ok(size) = f.seek(SeekFrom::End(0)) else { return Vec::new() };
        let known = self.offsets.get(path).copied().filter(|o| *o <= size);
        let start = known.unwrap_or(size.saturating_sub(self.first_read));
        if start >= size {
            self.offsets.insert(path.into(), size);
            return Vec::new();
        }
        let mut data = Vec::with_capacity((size - start) as usize);
        if f.seek(SeekFrom::Start(start)).is_err() || f.take(size - start).read_to_end(&mut data).is_err() {
            return Vec::new();
        }
        let Some(last_newline) = data.iter().rposition(|&b| b == b'\n') else {
            // Nothing complete yet: a line still being written is read next time.
            self.offsets.insert(path.into(), start);
            return Vec::new();
        };
        self.offsets.insert(path.into(), start + last_newline as u64 + 1);
        let mut body = &data[..last_newline];
        if known.is_none() && start > 0 {
            // The window began mid-line.
            match body.iter().position(|&b| b == b'\n') {
                Some(cut) => body = &body[cut + 1..],
                None => return Vec::new(),
            }
        }
        body.split(|&b| b == b'\n')
            .filter_map(prose)
            .filter(|e| known.is_some() || e.timestamp.is_some_and(|t| t > since))
            .collect()
    }
}

fn cursor_message_prose(message: &CursorMessage) -> Option<Entry> {
    if message.role != "assistant" {
        return None;
    }
    let text = match &message.content {
        Value::String(text) => text.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter(|part| part.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|part| part.get("text").and_then(Value::as_str))
            .map(str::to_string)
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    };
    let text = strip_sentinel(&text);
    let text = text.trim();
    (!text.is_empty()).then(|| Entry { thinking: false, text: text.to_string(), timestamp: None })
}

/// The prose in one transcript line, if any.
///
/// Claude Code: `{"type":"assistant","message":{"content":[{"type":"text"|"thinking",…}]}}`;
/// Codex: `{"type":"response_item","payload":{"type":"message","role":"assistant",
/// "content":[{"type":"output_text",…}]}}` or `{"payload":{"type":"reasoning","summary":[…]}}`.
/// A subagent's lines (`isSidechain`) are its own conversation.
pub fn prose(line: &[u8]) -> Option<Entry> {
    let v: Value = serde_json::from_slice(line).ok()?;
    let texts = |arr: Option<&Value>, ty: &str, key: &str| -> Vec<String> {
        arr.and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|b| ty.is_empty() || b.get("type").and_then(Value::as_str) == Some(ty))
            .filter_map(|b| b.get(key).and_then(Value::as_str).map(str::to_string))
            .collect()
    };
    let (said, thought) = match v.get("type").and_then(Value::as_str) {
        Some("assistant") if v.get("isSidechain").and_then(Value::as_bool) != Some(true) => {
            let content = v.pointer("/message/content");
            (texts(content, "text", "text"), texts(content, "thinking", "thinking"))
        }
        Some("response_item") => {
            let p = v.get("payload")?;
            match p.get("type").and_then(Value::as_str) {
                Some("message") if p.get("role").and_then(Value::as_str) == Some("assistant") => {
                    (texts(p.get("content"), "output_text", "text"), Vec::new())
                }
                Some("reasoning") => (Vec::new(), texts(p.get("summary"), "", "text")),
                _ => return None,
            }
        }
        _ => return None,
    };
    let timestamp = v.get("timestamp").and_then(Value::as_str).and_then(parse_iso8601);
    // The same cleaning the Stop hook's final message gets, so the two compare equal.
    let text = strip_sentinel(&said.join("\n"));
    if !text.is_empty() {
        return Some(Entry { thinking: false, text, timestamp });
    }
    let thinking = thought.join("\n").trim().to_string();
    (!thinking.is_empty()).then_some(Entry { thinking: true, text: thinking, timestamp })
}

/// `2026-11-03T09:30:00.123Z` or with a `±hh:mm` offset → Unix seconds.
pub fn parse_iso8601(s: &str) -> Option<Timestamp> {
    let (date, rest) = s.split_once('T')?;
    let mut d = date.split('-');
    let (y, mo, da): (i64, i64, i64) = (d.next()?.parse().ok()?, d.next()?.parse().ok()?, d.next()?.parse().ok()?);
    let (time, offset) = if let Some(t) = rest.strip_suffix('Z') {
        (t, 0)
    } else {
        let i = rest.rfind(['+', '-'])?;
        let (t, z) = rest.split_at(i);
        let sign = if z.starts_with('-') { -1 } else { 1 };
        let (h, m) = z[1..].split_once(':')?;
        (t, sign * (h.parse::<i64>().ok()? * 3600 + m.parse::<i64>().ok()? * 60))
    };
    let mut t = time.split(':');
    let (h, mi): (i64, i64) = (t.next()?.parse().ok()?, t.next()?.parse().ok()?);
    let sec: f64 = t.next()?.parse().ok()?;
    // Days from civil (Howard Hinnant).
    let (yy, mm) = if mo <= 2 { (y - 1, mo + 9) } else { (y, mo - 3) };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let doy = (153 * mm + 2) / 5 + da - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some((days * 86_400 + h * 3600 + mi * 60 - offset) as f64 + sec)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Write;

    struct File(tempfile::NamedTempFile);

    impl File {
        fn new() -> Self {
            File(tempfile::NamedTempFile::new().unwrap())
        }
        fn path(&self) -> String {
            self.0.path().to_string_lossy().into()
        }
        fn write(&mut self, s: &str) {
            self.0.as_file_mut().write_all(s.as_bytes()).unwrap();
        }
    }

    fn stamp(secs: i64) -> String {
        // 1970-01-01T00:16:40.000Z style, enough for the tests.
        format!("1970-01-01T{:02}:{:02}:{:02}.000Z", secs / 3600, secs / 60 % 60, secs % 60)
    }

    fn claude(blocks: Value, at: i64, sidechain: bool) -> String {
        json!({"type": "assistant", "isSidechain": sidechain, "timestamp": stamp(at), "message": {"role": "assistant", "content": blocks}}).to_string()
    }

    fn say(text: &str, at: i64) -> String {
        claude(json!([{"type": "text", "text": text}]), at, false)
    }

    fn texts(e: &[Entry]) -> Vec<&str> {
        e.iter().map(|x| x.text.as_str()).collect()
    }

    fn cursor_message(fixture: &str) -> CursorMessage {
        let value: Value = serde_json::from_str(fixture).unwrap();
        CursorMessage {
            id: value["id"].as_str().unwrap().to_string(),
            role: value["role"].as_str().unwrap().to_string(),
            content: value["content"].clone(),
        }
    }

    #[test]
    fn reads_claude_prose_between_tool_calls_in_order() {
        let mut f = File::new();
        let lines = [
            json!({"type": "user", "timestamp": stamp(999), "message": {"role": "user", "content": "fix it"}}).to_string(),
            claude(json!([{"type": "thinking", "thinking": "", "signature": "redacted"}]), 1000, false),
            say("先看一下是怎么消失的。", 1000),
            claude(json!([{"type": "tool_use", "name": "Bash", "input": {}}]), 1000, false),
            say("找到了根源。", 1001),
        ];
        f.write(&(lines.join("\n") + "\n"));
        assert_eq!(texts(&Tail::default().new_prose(&f.path(), 0.0)), ["先看一下是怎么消失的。", "找到了根源。"]);
    }

    #[test]
    fn only_what_was_appended_since_the_last_read() {
        let mut f = File::new();
        let mut tail = Tail::default();
        f.write(&(say("one", 1000) + "\n"));
        assert_eq!(texts(&tail.new_prose(&f.path(), 0.0)), ["one"]);
        assert!(tail.new_prose(&f.path(), 0.0).is_empty());
        f.write(&(say("two", 1001) + "\n"));
        assert_eq!(texts(&tail.new_prose(&f.path(), 0.0)), ["two"]);
    }

    #[test]
    fn a_line_still_being_written_waits_for_its_newline() {
        let mut f = File::new();
        let mut tail = Tail::default();
        let line = say("partial", 1000);
        f.write(&line[..20]);
        assert!(tail.new_prose(&f.path(), 0.0).is_empty());
        f.write(&(line[20..].to_string() + "\n"));
        assert_eq!(texts(&tail.new_prose(&f.path(), 0.0)), ["partial"]);
    }

    #[test]
    fn first_read_skips_what_the_timeline_already_has() {
        let mut f = File::new();
        f.write(&format!("{}\n{}\n", say("old", 1000), say("new", 2000)));
        assert_eq!(texts(&Tail::default().new_prose(&f.path(), 1500.0)), ["new"]);
    }

    #[test]
    fn first_read_of_a_long_transcript_starts_near_its_end() {
        let mut f = File::new();
        let filler = say(&"x".repeat(500), 1000);
        f.write(&(vec![filler; 20].join("\n") + "\n"));
        f.write(&(say("latest", 1001) + "\n"));
        let got = Tail::new(1200).new_prose(&f.path(), 0.0);
        assert_eq!(got.last().map(|e| e.text.as_str()), Some("latest"));
        assert!(got.len() < 5);
    }

    #[test]
    fn subagent_prose_is_not_the_panes_and_the_sentinel_is_stripped() {
        let mut f = File::new();
        f.write(&(claude(json!([{"type": "text", "text": "subagent chatter"}]), 1000, true) + "\n"));
        f.write(&(say("Done.\n\n::seahelm-suggest:: push | open PR", 1001) + "\n"));
        assert_eq!(texts(&Tail::default().new_prose(&f.path(), 0.0)), ["Done."]);
    }

    #[test]
    fn reads_codex_messages_and_reasoning() {
        let mut f = File::new();
        let lines = [
            json!({"type": "response_item", "timestamp": stamp(1000), "payload": {"type": "reasoning", "summary": [{"type": "summary_text", "text": "Checking the merge"}]}}).to_string(),
            json!({"type": "response_item", "timestamp": stamp(1001), "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "已合并 PR"}]}}).to_string(),
            json!({"type": "response_item", "timestamp": stamp(1002), "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "merge it"}]}}).to_string(),
        ];
        f.write(&(lines.join("\n") + "\n"));
        let got = Tail::default().new_prose(&f.path(), 0.0);
        assert_eq!(texts(&got), ["Checking the merge", "已合并 PR"]);
        assert_eq!(got.iter().map(|e| e.thinking).collect::<Vec<_>>(), [true, false]);
    }

    #[test]
    fn reads_cursor_assistant_text_but_not_reasoning_or_tool_calls() {
        let assistant = cursor_message(include_str!("../tests/fixtures/cursor-assistant-message.json"));
        assert_eq!(cursor_message_prose(&assistant).unwrap().text, "I'll inspect the timeline.");
        assert!(cursor_message_prose(&cursor_message(include_str!("../tests/fixtures/cursor-tool-message.json"))).is_none());
    }

    #[test]
    fn cursor_tail_reads_new_assistant_messages_in_store_order() {
        let user = cursor_message(include_str!("../tests/fixtures/cursor-user-message.json"));
        let first = cursor_message(include_str!("../tests/fixtures/cursor-assistant-message.json"));
        let tool = cursor_message(include_str!("../tests/fixtures/cursor-tool-message.json"));
        let second = CursorMessage {
            id: "msg-assistant-2".into(),
            role: "assistant".into(),
            content: json!([{"type": "text", "text": "Now I can explain the fix."}]),
        };
        let rows = [user.clone(), first.clone(), tool.clone(), second.clone()];
        let mut tail = CursorTail::default();
        assert_eq!(texts(&tail.advance("chat", &rows[..3], false)), ["I'll inspect the timeline."]);
        assert_eq!(texts(&tail.advance("chat", &rows, false)), ["Now I can explain the fix."]);
        assert!(tail.advance("chat", &rows, false).is_empty());
    }

    #[test]
    fn cursor_session_start_baselines_existing_history() {
        let user = cursor_message(include_str!("../tests/fixtures/cursor-user-message.json"));
        let first = cursor_message(include_str!("../tests/fixtures/cursor-assistant-message.json"));
        let rows = [user, first];
        let mut tail = CursorTail::default();
        assert!(tail.advance("chat", &rows, true).is_empty());
        let next = CursorMessage {
            id: "msg-assistant-next".into(),
            role: "assistant".into(),
            content: json!([{"type": "text", "text": "A new turn."}]),
        };
        assert_eq!(texts(&tail.advance("chat", &[rows[0].clone(), rows[1].clone(), next], false)), ["A new turn."]);
    }

    #[test]
    fn a_replaced_shorter_file_is_read_from_its_start() {
        let mut f = File::new();
        let mut tail = Tail::default();
        f.write(&(vec![say("a long first session", 1000); 5].join("\n") + "\n"));
        tail.new_prose(&f.path(), 0.0);
        std::fs::write(f.path(), say("fresh", 3000) + "\n").unwrap();
        assert_eq!(texts(&tail.new_prose(&f.path(), 2000.0)), ["fresh"]);
    }

    #[test]
    fn visible_thinking_is_kept_apart_from_what_is_said() {
        let mut f = File::new();
        let lines = [
            claude(json!([{"type": "thinking", "thinking": "", "signature": "redacted"}]), 1000, false),
            claude(json!([{"type": "thinking", "thinking": "链路验证通了，接下来查时间戳格式。\n\n"}]), 1001, false),
            say("顺序对了。", 1002),
        ];
        f.write(&(lines.join("\n") + "\n"));
        let got = Tail::default().new_prose(&f.path(), 0.0);
        assert_eq!(got.iter().map(|e| e.thinking).collect::<Vec<_>>(), [true, false]);
        assert_eq!(texts(&got), ["链路验证通了，接下来查时间戳格式。", "顺序对了。"]);
    }

    #[test]
    fn iso8601() {
        assert_eq!(parse_iso8601("2026-11-03T09:30:00Z"), Some(1_793_698_200.0));
        assert_eq!(parse_iso8601("2026-11-03T17:30:00.500+08:00"), Some(1_793_698_200.5));
        assert_eq!(parse_iso8601("nope"), None);
    }
}
