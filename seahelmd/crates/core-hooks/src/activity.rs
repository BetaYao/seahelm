//! One tool call as an activity-log line (`ActivityEventExtractor.swift`):
//! which tool, a short detail fit for a status line, and whether it failed.

use seahelm_core_types::{ActivityEvent, Timestamp};
use serde_json::Value;

use crate::event::{WebhookEvent, WebhookEventType};
use crate::Map;

/// The activity a tool event describes, stamped `now`.
pub fn extract(ev: &WebhookEvent, now: Timestamp) -> ActivityEvent {
    let tool = ev.data_str("tool_name").unwrap_or("Unknown").to_string();
    let empty = Map::new();
    let input = ev.data.get("tool_input").and_then(Value::as_object).unwrap_or(&empty);
    let detail = detail(&tool, input);
    let is_error = is_error(ev, &tool, ev.data_str("tool_result"));
    ActivityEvent { tool, detail, is_error, timestamp: now }
}

/// "Edit Core/x.swift", "Failed Bash ls": the line a status message shows.
pub fn summary(tool: &str, input: &Map, is_error: bool) -> String {
    let detail = detail(tool, input);
    let base = if detail == tool { tool.to_string() } else { format!("{tool} {detail}") };
    if is_error {
        format!("Failed {base}")
    } else {
        base
    }
}

/// The last two components of a path: enough to recognise the file.
pub fn short_path(path: &str) -> String {
    let parts: Vec<&str> = path.split(['/', '\\']).filter(|p| !p.is_empty()).collect();
    let start = parts.len().saturating_sub(2);
    parts[start..].join("/")
}

fn detail(tool: &str, input: &Map) -> String {
    let get = |key: &str| input.get(key).and_then(Value::as_str);
    let found = match tool {
        "Read" | "Write" | "Edit" | "MultiEdit" => get("file_path").map(short_path),
        "Bash" => get("command").map(|c| truncate(c, 60)),
        "Grep" => get("pattern").map(|p| format!("\"{p}\"")),
        "Glob" => get("pattern").map(str::to_string),
        "Agent" => get("prompt").map(|p| truncate(p, 40)),
        "Task" => get("description").or_else(|| get("prompt")).map(|d| truncate(d, 40)),
        "WebSearch" => get("query").map(|q| format!("\"{}\"", truncate(q, 40))),
        "WebFetch" => get("url").map(|u| truncate(u, 60)),
        _ => None,
    };
    found.unwrap_or_else(|| tool.to_string())
}

fn is_error(ev: &WebhookEvent, tool: &str, result: Option<&str>) -> bool {
    if ev.event == WebhookEventType::ToolUseFailed {
        return true;
    }
    if tool != "Bash" {
        return false;
    }
    let Some(result) = result else { return false };
    // "Exit code: N", case-insensitively, N ≠ 0.
    let lower = result.to_ascii_lowercase();
    let Some(at) = lower.find("exit code: ") else { return false };
    let digits: String = lower[at + "exit code: ".len()..].chars().take_while(char::is_ascii_digit).collect();
    digits.parse::<u64>().is_ok_and(|code| code != 0)
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        format!("{}...", s.chars().take(max).collect::<String>())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ev(event: WebhookEventType, data: Value) -> WebhookEvent {
        WebhookEvent::new("claude-code", "s1", event, "/tmp", data.as_object().unwrap().clone())
    }

    // ActivityEventPipelineTests (extractor half)

    #[test]
    fn test_extractor_produces_valid_events() {
        let a = extract(
            &ev(
                WebhookEventType::ToolUseEnd,
                json!({"tool_name": "Read", "tool_input": {"file_path": "/Users/dev/project/Sources/Core/AgentRegistry.swift"}}),
            ),
            1.0,
        );
        assert_eq!(a.tool, "Read");
        assert_eq!(a.detail, "Core/AgentRegistry.swift");
        assert!(!a.is_error);
    }

    #[test]
    fn test_extractor_handles_bash_error() {
        let a = extract(
            &ev(
                WebhookEventType::ToolUseEnd,
                json!({"tool_name": "Bash", "tool_input": {"command": "swift test"},
                       "tool_result": "Test Suite 'All tests' failed.\nExit code: 1"}),
            ),
            1.0,
        );
        assert_eq!(a.tool, "Bash");
        assert!(a.is_error);
    }

    #[test]
    fn summaries_read_like_the_swift() {
        let input = json!({"command": "ls"});
        assert_eq!(summary("Bash", input.as_object().unwrap(), true), "Failed Bash ls");
        assert_eq!(summary("Frob", &Map::new(), false), "Frob");
    }
}
