//! Port of Tests/MessageConfigManifestTests.swift. `testMessageEventDictShape`
//! is about the message stream's event shape, not manifests, and is not
//! ported here.

use seahelm_core_scan::manifest::{AgentManifest, MessageConfig};
use seahelm_core_types::AgentType;

#[test]
fn manifest_decodes_optional_message_block() {
    let m = AgentManifest::from_json(
        r#"{
          "id": "cursor",
          "message": {
            "assistant_from": "stop_last_assistant_message",
            "user_fields": ["prompt", "message"],
            "tool_aliases": {"run_terminal_cmd": "Shell"},
            "coalesce_tools": true,
            "screen_fallback": false
          }
        }"#,
    )
    .unwrap();
    assert_eq!(m.id, "cursor");
    let msg = m.message.expect("message block");
    assert_eq!(msg.assistant_from, "stop_last_assistant_message");
    assert_eq!(msg.user_fields, ["prompt", "message"]);
    assert_eq!(msg.tool_aliases.get("run_terminal_cmd").map(String::as_str), Some("Shell"));
    assert!(msg.coalesce_tools);
    assert!(!msg.screen_fallback);
}

#[test]
fn manifest_without_message_uses_nil() {
    let m = AgentManifest::from_json(r#"{"id":"claude"}"#).unwrap();
    assert!(m.message.is_none());
}

#[test]
fn resolve_looks_up_manifest_id_not_raw_value() {
    let claude = AgentManifest::from_json(r#"{"id":"claude","message":{"coalesce_tools":false}}"#).unwrap();
    let mut asked = Vec::new();
    let config = MessageConfig::resolve(AgentType::ClaudeCode, |id| {
        asked.push(id.to_string());
        (id == "claude").then_some(&claude)
    });
    assert_eq!(asked, ["claude"]);
    assert!(!config.coalesce_tools);
}

#[test]
fn resolve_falls_back_to_default_without_message_block() {
    let config = MessageConfig::resolve(AgentType::Codex, |_| None);
    assert_eq!(config, MessageConfig::default());
}
