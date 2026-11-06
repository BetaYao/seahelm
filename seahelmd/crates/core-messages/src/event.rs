//! One timeline row (`MessageEvent.swift`), in the wire and file shape the
//! app uses, so a client reads the core's rows as it read the app's.

use serde_json::{json, Map, Value};

use seahelm_core_types::Timestamp;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    User,
    Assistant,
    Tool,
    Status,
    Decision,
    Notice,
    /// What the agent narrates while it works (Claude's visible thinking, a
    /// Codex reasoning summary), shown apart from what it says.
    Thinking,
    /// A line the core writes into a pane's timeline itself (First Mate's
    /// sweep reports), not typed into the pane, so it starts no turn.
    /// Clients draw it as one line of note; one that does not know the kind
    /// drops the row.
    Note,
    /// First Mate's daily brief, composed by the core (no turn): several
    /// lines, a title then one per section. Clients draw it as a block.
    Brief,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::User => "user",
            Kind::Assistant => "assistant",
            Kind::Tool => "tool",
            Kind::Status => "status",
            Kind::Decision => "decision",
            Kind::Notice => "notice",
            Kind::Thinking => "thinking",
            Kind::Note => "note",
            Kind::Brief => "brief",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "user" => Kind::User,
            "assistant" => Kind::Assistant,
            "tool" => Kind::Tool,
            "status" => Kind::Status,
            "decision" => Kind::Decision,
            "notice" => Kind::Notice,
            "thinking" => Kind::Thinking,
            "note" => Kind::Note,
            "brief" => Kind::Brief,
            _ => return None,
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Message {
    /// Global, carried on across restarts, stamped by the hub on append.
    pub seq: u64,
    /// The client's id for the pane (its alias), else its key.
    pub pane_id: String,
    /// The core's key: the seahelmd session name.
    pub pane_session_key: String,
    pub kind: Kind,
    pub ts: Timestamp,
    pub text: Option<String>,
    pub tool: Option<String>,
    pub detail: Option<String>,
    /// Choices attached to a decision row. Other row kinds leave this empty.
    pub options: Option<Vec<String>>,
    pub is_error: Option<bool>,
    pub status: Option<String>,
    pub old_status: Option<String>,
    pub count: u32,
}

impl Message {
    pub fn new(pane_id: &str, key: &str, kind: Kind, ts: Timestamp) -> Self {
        Message {
            seq: 0,
            pane_id: pane_id.into(),
            pane_session_key: key.into(),
            kind,
            ts,
            text: None,
            tool: None,
            detail: None,
            options: None,
            is_error: None,
            status: None,
            old_status: None,
            count: 1,
        }
    }

    pub fn with_text(mut self, text: impl Into<String>) -> Self {
        self.text = Some(text.into());
        self
    }

    pub fn with_options(mut self, options: Vec<String>) -> Self {
        self.options = Some(options);
        self
    }

    /// The pane this row belongs to across restarts.
    pub fn ring_key(&self) -> &str {
        if self.pane_session_key.is_empty() {
            &self.pane_id
        } else {
            &self.pane_session_key
        }
    }

    pub fn to_json(&self) -> Value {
        let mut d = Map::new();
        d.insert("seq".into(), json!(self.seq));
        d.insert("pane_id".into(), json!(self.pane_id));
        d.insert("pane_session_key".into(), json!(self.pane_session_key));
        d.insert("kind".into(), json!(self.kind.as_str()));
        d.insert("ts".into(), json!(self.ts));
        let mut opt = |k: &str, v: Option<Value>| {
            if let Some(v) = v {
                d.insert(k.into(), v);
            }
        };
        opt("text", self.text.as_ref().map(|v| json!(v)));
        opt("tool", self.tool.as_ref().map(|v| json!(v)));
        opt("detail", self.detail.as_ref().map(|v| json!(v)));
        opt("options", self.options.as_ref().map(|v| json!(v)));
        opt("is_error", self.is_error.map(|v| json!(v)));
        opt("status", self.status.as_ref().map(|v| json!(v)));
        opt("old_status", self.old_status.as_ref().map(|v| json!(v)));
        if self.count > 1 {
            d.insert("count".into(), json!(self.count));
        }
        Value::Object(d)
    }

    /// The inverse of `to_json`, for rows read back from disk.
    pub fn from_json(v: &Value) -> Option<Self> {
        let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
        Some(Message {
            seq: v.get("seq")?.as_u64()?,
            pane_id: s("pane_id")?,
            pane_session_key: s("pane_session_key").unwrap_or_default(),
            kind: Kind::parse(v.get("kind")?.as_str()?)?,
            ts: v.get("ts")?.as_f64()?,
            text: s("text"),
            tool: s("tool"),
            detail: s("detail"),
            options: v.get("options").and_then(Value::as_array).map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            }),
            is_error: v.get("is_error").and_then(Value::as_bool),
            status: s("status"),
            old_status: s("old_status"),
            count: v.get("count").and_then(Value::as_u64).unwrap_or(1) as u32,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_in_the_apps_shape() {
        let mut m = Message::new("p", "seahelm-x", Kind::Tool, 10.5);
        m.seq = 3;
        m.tool = Some("Bash".into());
        m.detail = Some("cargo test".into());
        m.count = 2;
        let v = m.to_json();
        assert_eq!(v, json!({"seq": 3, "pane_id": "p", "pane_session_key": "seahelm-x", "kind": "tool", "ts": 10.5, "tool": "Bash", "detail": "cargo test", "count": 2}));
        assert_eq!(Message::from_json(&v), Some(m));
        let decision = Message::new("p", "seahelm-x", Kind::Decision, 11.0)
            .with_text("Allow this action?")
            .with_options(vec!["1. Yes".into(), "2. No".into()]);
        let decision_json = decision.to_json();
        assert_eq!(decision_json["options"], json!(["1. Yes", "2. No"]));
        assert_eq!(Message::from_json(&decision_json), Some(decision));
        assert!(Message::from_json(&json!({"seq": 1})).is_none());
        let note = Message::new("seahelm-first-mate", "seahelm-first-mate", Kind::Note, 11.0).with_text("Deleted 2 worktrees by habit: a · b.");
        let v = note.to_json();
        assert_eq!(v["kind"], "note");
        assert_eq!(Message::from_json(&v), Some(note));
        let brief = Message::new("seahelm-first-mate", "seahelm-first-mate", Kind::Brief, 12.0).with_text("First Mate · daily brief\nDone: deleted 1 worktree by habit — a");
        let v = brief.to_json();
        assert_eq!(v["kind"], "brief");
        assert_eq!(Message::from_json(&v), Some(brief));
    }
}
