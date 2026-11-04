//! Who each chat talks to, kept in `state.chat_sessions["telegram:<chat>"]`
//! in the app's `CommandSession` shape (`key`, `boundPaneKey`, `boundPaneId`,
//! `boundWorktreePath`, `commander`, `closed`), so sessions imported from the
//! app keep working. One field is new: `firstMate`, set by `/go mate` (the
//! app kept a First Mate chat as unbound; a chat that chose First Mate now
//! stays with it even while it is off).

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ChatSession {
    pub key: String,
    /// The bound pane's session key (the core's handle key).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bound_pane_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bound_pane_id: Option<String>,
    /// A worktree bound before it had a pane: its first pane takes it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bound_worktree_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commander: Option<String>,
    #[serde(default)]
    pub closed: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub first_mate: bool,
}

pub fn key(chat_id: &str) -> String {
    format!("telegram:{chat_id}")
}

/// The chat id of a `telegram:<chat>` key.
pub fn chat_of(key: &str) -> Option<&str> {
    key.strip_prefix("telegram:").filter(|c| !c.is_empty() && !c.contains('#'))
}

impl ChatSession {
    pub fn new(key: String) -> ChatSession {
        ChatSession { key, ..ChatSession::default() }
    }

    pub fn load(sessions: &Map<String, Value>, key: &str) -> ChatSession {
        sessions.get(key).and_then(|v| serde_json::from_value::<ChatSession>(v.clone()).ok()).unwrap_or_else(|| ChatSession::new(key.to_string()))
    }

    pub fn store(&self, sessions: &mut Map<String, Value>) {
        sessions.insert(self.key.clone(), serde_json::to_value(self).unwrap_or_default());
    }

    /// The pane this chat is bound to, while open.
    pub fn bound_pane(&self) -> Option<&str> {
        (!self.closed).then_some(self.bound_pane_key.as_deref()).flatten()
    }

    /// Who the chat talks to, in `command.run`'s `context.binding` shape;
    /// None when nobody.
    pub fn binding(&self) -> Option<Value> {
        if self.closed {
            return None;
        }
        if self.first_mate {
            return Some(json!({"first_mate": true}));
        }
        if let Some(k) = &self.bound_pane_key {
            return Some(json!({"pane": k, "worktree_path": self.bound_worktree_path.clone().unwrap_or_default()}));
        }
        self.bound_worktree_path.as_ref().map(|p| json!({"worktree_path": p}))
    }

    /// Apply what `command.run` says the chat talks to now. True when
    /// anything changed.
    pub fn rebind(&mut self, binding: &Value, commander: Option<&str>) -> bool {
        let before = self.clone();
        let path = binding.get("worktree_path").and_then(Value::as_str).unwrap_or_default();
        if binding.get("first_mate").and_then(Value::as_bool) == Some(true) {
            self.bound_pane_key = None;
            self.bound_pane_id = None;
            self.bound_worktree_path = None;
            self.first_mate = true;
            self.closed = false;
        } else if let Some(k) = binding.get("pane").and_then(Value::as_str) {
            self.bound_pane_key = Some(k.to_string());
            self.bound_pane_id = Some(k.to_string());
            self.bound_worktree_path = (!path.is_empty()).then(|| path.to_string());
            self.first_mate = false;
            self.closed = false;
        } else if !path.is_empty() {
            self.bound_pane_key = None;
            self.bound_pane_id = None;
            self.bound_worktree_path = Some(path.to_string());
            self.first_mate = false;
            self.closed = false;
        } else {
            return false;
        }
        if let Some(c) = commander {
            self.commander = Some(c.to_string());
        }
        *self != before
    }
}

/// Every open session in the store.
pub fn all(sessions: &Map<String, Value>) -> Vec<ChatSession> {
    sessions.iter().filter(|(k, _)| chat_of(k).is_some()).filter_map(|(_, v)| serde_json::from_value::<ChatSession>(v.clone()).ok()).collect()
}

/// Chats bound to this pane — what hears its notices and its progress.
pub fn chats_bound_to(sessions: &Map<String, Value>, pane_key: &str) -> Vec<String> {
    let mut out: Vec<String> = all(sessions).iter().filter(|s| s.bound_pane() == Some(pane_key)).filter_map(|s| chat_of(&s.key).map(str::to_string)).collect();
    out.sort();
    out
}

/// The chats that hear a pane's notice. Chats bound to the pane always do;
/// the fleet's listeners (the default chat, the last chat an order came
/// from) hear the whole fleet only while unbound — after `/go #n` a chat
/// hears #n alone, which is what binding is for. A chat bound to a pane that
/// has since gone is still bound: it hears nothing rather than the fleet.
pub fn chats_to_notify(sessions: &Map<String, Value>, pane_key: Option<&str>, fleet_listeners: &[String]) -> Vec<String> {
    let mut chats: Vec<String> = pane_key.map(|k| chats_bound_to(sessions, k)).unwrap_or_default();
    for chat in fleet_listeners {
        let s = ChatSession::load(sessions, &key(chat));
        if s.bound_pane_key.is_none() || s.closed {
            chats.push(chat.clone());
        }
    }
    chats.sort();
    chats.dedup();
    chats
}

/// Telegram chat ids: a user (and so a private chat) is positive, a group
/// negative.
pub fn is_private_chat(chat_id: &str) -> bool {
    chat_id.parse::<i64>().map(|i| i > 0).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_and_writes_the_apps_shape() {
        let mut m = Map::new();
        m.insert("telegram:5".into(), json!({"key": "telegram:5", "boundPaneKey": "s-1", "boundPaneId": "UUID", "boundWorktreePath": "/r/wt", "commander": "42"}));
        m.insert("telegram:6".into(), json!({"key": "telegram:6", "closed": true, "boundPaneKey": "s-1"}));
        m.insert("telegram:7#2".into(), json!({"key": "telegram:7#2", "boundPaneKey": "s-1"}));
        let s = ChatSession::load(&m, "telegram:5");
        assert_eq!(s.bound_pane(), Some("s-1"));
        assert!(!s.closed);
        assert_eq!(s.binding(), Some(json!({"pane": "s-1", "worktree_path": "/r/wt"})));
        assert_eq!(chats_bound_to(&m, "s-1"), vec!["5"]);
        s.store(&mut m);
        let v = &m["telegram:5"];
        assert_eq!(v["boundPaneKey"], "s-1");
        assert_eq!(v["closed"], false);
        assert!(v.get("firstMate").is_none());
        let fresh = ChatSession::load(&m, "telegram:9");
        assert_eq!(fresh.key, "telegram:9");
        assert_eq!(fresh.binding(), None);
    }

    #[test]
    fn rebinds_from_command_outcomes() {
        let mut s = ChatSession::new(key("5"));
        assert!(s.rebind(&json!({"pane": "s-2", "worktree_path": "/r/wt"}), Some("42")));
        assert_eq!(s.bound_pane_key.as_deref(), Some("s-2"));
        assert_eq!(s.commander.as_deref(), Some("42"));
        assert!(!s.rebind(&json!({"pane": "s-2", "worktree_path": "/r/wt"}), Some("42")));
        assert!(s.rebind(&json!({"first_mate": true}), None));
        assert_eq!(s.binding(), Some(json!({"first_mate": true})));
        assert_eq!(s.bound_pane(), None);
        assert!(s.rebind(&json!({"worktree_path": "/r/new"}), None));
        assert_eq!(s.binding(), Some(json!({"worktree_path": "/r/new"})));
        assert!(!s.rebind(&json!({}), None));
    }

    #[test]
    fn notices_follow_bindings() {
        let mut m = Map::new();
        ChatSession { key: key("5"), bound_pane_key: Some("s-1".into()), ..Default::default() }.store(&mut m);
        ChatSession { key: key("6"), bound_pane_key: Some("s-gone".into()), ..Default::default() }.store(&mut m);
        let fleet = vec!["6".to_string(), "7".to_string()];
        assert_eq!(chats_to_notify(&m, Some("s-1"), &fleet), vec!["5", "7"]);
        assert_eq!(chats_to_notify(&m, Some("s-2"), &fleet), vec!["7"]);
        assert!(is_private_chat("5"));
        assert!(!is_private_chat("-100123"));
    }
}
