//! Port of Tests/StatusDetectorActivityTests.swift.

use seahelm_core_scan::detect::extract_activity_events;

const NOW: f64 = 1_700_000_000.0;

#[test]
fn extract_claude_code_tool_lines() {
    let text = "⏺ Read(src/main.swift)\n⏺ Edit(src/auth/login.swift)\n⏺ Bash(swift test --filter Auth)";
    let events = extract_activity_events(text, NOW);
    assert_eq!(events.len(), 3);
    assert_eq!(events[0].tool, "Bash");
    assert_eq!(events[0].detail, "swift test --filter Auth");
    assert_eq!(events[1].tool, "Edit");
    assert_eq!(events[2].tool, "Read");
    assert_eq!(events[0].timestamp, NOW);
}

#[test]
fn extract_with_error_marker() {
    let events = extract_activity_events("⏺ Read(config.json)\n✗ Bash(swift build) — error", NOW);
    assert_eq!(events.len(), 2);
    assert!(events[0].is_error);
    assert!(!events[1].is_error);
}

#[test]
fn extract_empty_text_returns_empty() {
    assert!(extract_activity_events("", NOW).is_empty());
}

#[test]
fn extract_no_tool_lines_returns_empty() {
    assert!(extract_activity_events("$ echo hello\nhello\n$ ", NOW).is_empty());
}

#[test]
fn extract_triangle_marker_lines() {
    let events = extract_activity_events("▸ Read   src/main.swift\n▸ Grep   \"pattern\"", NOW);
    assert_eq!(events.len(), 2);
}

#[test]
fn max_events_from_text() {
    let text: String = (0..30).map(|i| format!("⏺ Read(file{i}.swift)\n")).collect();
    assert!(extract_activity_events(&text, NOW).len() <= 20);
}
