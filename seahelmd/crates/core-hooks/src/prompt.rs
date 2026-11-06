//! Turning a submitted prompt into what a person should be shown — or
//! deciding nobody said anything worth showing (`UserPromptText.swift`).
//!
//! Not every turn Claude Code opens is a person speaking. When a background
//! task finishes, the harness injects the result as a user turn and fires
//! `UserPromptSubmit` for it, so seahelm sees a prompt reading
//! `<task-notification>…</task-notification>`. The payload carries nothing
//! to filter on, so the shape of the text is the only signal, which is why
//! this reads as conservatively as it does. The event itself still counts:
//! a background task completing really does start a turn. Only the
//! *display* of it is suppressed.

use std::sync::OnceLock;

use regex::Regex;

/// Blocks the harness writes into a turn on its own account.
const MACHINE_BLOCKS: [&str; 2] = ["task-notification", "system-reminder"];

/// What a human should be shown for `raw`, or None when the turn was not a
/// person speaking. A prompt is machine plumbing only when it is *entirely*
/// one such block: someone quoting a notification around their own words is
/// a person speaking, and their message is left whole.
pub fn human_text(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || is_wholly_machine_block(trimmed) {
        return None;
    }
    let unwrapped = strip_seahelm_context(&unwrap_pasted_content(trimmed));
    (!unwrapped.is_empty()).then_some(unwrapped)
}

/// The user's words without the context seahelm appended for the agent.
/// The core delivers the user's message to First Mate as
/// `<their words>\n\n[seahelm projects] <json>`: the block is for the
/// agent, not something the user said, and shown in the timeline it made
/// the web's echo of the sent message never match (two bubbles for one).
/// Only a block that follows the user's own words is cut; a prompt that is
/// all seahelm (`[seahelm event] …`) is left whole.
pub fn strip_seahelm_context(text: &str) -> String {
    match text.find("\n\n[seahelm ") {
        Some(at) if !text[..at].trim().is_empty() => text[..at].trim_end().to_string(),
        _ => text.to_string(),
    }
}

/// Whether `trimmed` is one machine block and nothing else.
pub fn is_wholly_machine_block(trimmed: &str) -> bool {
    MACHINE_BLOCKS
        .iter()
        .any(|tag| trimmed.starts_with(&format!("<{tag}>")) && trimmed.ends_with(&format!("</{tag}>")))
}

/// Take Claude Code's paste wrapper off a prompt.
///
/// Anything long arriving as a bracketed paste — every message seahelm
/// delivers to a pane, and a person's own ⌘V — is recorded wrapped in
/// `<pasted_content id="240b">…</pasted_content id="240b">`. The marker is
/// for the agent; to a human reading a title or a notification it is noise.
/// The closing tag repeats the attribute, which no markup parser would
/// accept, so this matches the shape Claude Code writes rather than XML.
pub fn unwrap_pasted_content(text: &str) -> String {
    static TAG: OnceLock<Regex> = OnceLock::new();
    static GAPS: OnceLock<Regex> = OnceLock::new();
    if !text.contains("<pasted_content") {
        return text.to_string();
    }
    let tag = TAG.get_or_init(|| Regex::new(r"</?pasted_content[^>]*>").unwrap());
    let gaps = GAPS.get_or_init(|| Regex::new(r"\n{3,}").unwrap());
    let stripped = tag.replace_all(text, "");
    // The tags sat on lines of their own; removing them leaves the blank
    // lines that held them apart.
    gaps.replace_all(&stripped, "\n\n").trim().to_string()
}

#[cfg(test)]
mod seahelm_context_tests {
    use super::*;
    #[test]
    fn the_users_words_without_seahelms_context() {
        assert_eq!(human_text("记住，PR 用英文\n\n[seahelm projects] [{\"repo\":\"/r\"}]").as_deref(), Some("记住，PR 用英文"));
        assert_eq!(human_text("[seahelm event] research.done\nJob: x").as_deref(), Some("[seahelm event] research.done\nJob: x"));
        assert_eq!(human_text("plain").as_deref(), Some("plain"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOTIFICATION: &str = "<task-notification>\n<task-id>bjnvnz7a2</task-id>\n<tool-use-id>toolu_014spY43jpr26tyRKTAvdShw</tool-use-id>\n<status>completed</status>\n<summary>Background command \"Wait for the new CI run\" completed (exit code 0)</summary>\n</task-notification>";

    // UserPromptTextTests

    #[test]
    fn test_task_notification_is_not_a_person_speaking() {
        assert_eq!(human_text(NOTIFICATION), None);
    }

    #[test]
    fn test_surrounding_whitespace_does_not_save_it() {
        assert_eq!(human_text(&format!("\n\n{NOTIFICATION}\n  ")), None);
    }

    #[test]
    fn test_system_reminder_is_also_machine_plumbing() {
        assert_eq!(human_text("<system-reminder>be brief</system-reminder>"), None);
    }

    #[test]
    fn test_empty_prompt_is_nothing() {
        assert_eq!(human_text("   \n "), None);
    }

    #[test]
    fn test_plain_prompt_survives_untouched() {
        assert_eq!(human_text("fix the flaky test").as_deref(), Some("fix the flaky test"));
    }

    #[test]
    fn test_quoting_a_notification_is_still_a_person_speaking() {
        let quoted = format!("seahelm-web shows this on the user side: {NOTIFICATION}, which is clearly not a human.");
        assert_eq!(human_text(&quoted), Some(quoted));
    }

    #[test]
    fn test_notification_followed_by_words_is_kept() {
        let text = format!("{NOTIFICATION}\n\nwhy did that fail?");
        assert_eq!(human_text(&text), Some(text));
    }

    #[test]
    fn test_paste_wrapper_comes_off() {
        let raw = "<pasted_content id=\"1404\">\nmerge #1561 first\n</pasted_content id=\"1404\">";
        assert_eq!(human_text(raw).as_deref(), Some("merge #1561 first"));
    }

    // WebhookStatusProviderTests: Claude Code's paste wrapper

    #[test]
    fn test_paste_wrapper_is_taken_off_around_typed_text() {
        let raw = "\n\n<pasted_content id=\"240b\">\nsample.mov\nsample.jpg\n</pasted_content id=\"240b\">\n\n\ndownload 目录，今天采集的样本";
        assert_eq!(unwrap_pasted_content(raw), "sample.mov\nsample.jpg\n\ndownload 目录，今天采集的样本");
    }

    #[test]
    fn test_whole_message_paste() {
        let raw = "<pasted_content id=\"5192\">\n可以，daemon 落库的时候把 URL 带上\n</pasted_content id=\"5192\">";
        assert_eq!(unwrap_pasted_content(raw), "可以，daemon 落库的时候把 URL 带上");
    }

    #[test]
    fn test_wrapper_without_an_id() {
        assert_eq!(unwrap_pasted_content("<pasted_content>\nhi\n</pasted_content>"), "hi");
    }

    #[test]
    fn test_several_pastes_in_one_turn() {
        let raw = "<pasted_content id=\"a\">\none\n</pasted_content id=\"a\">\nand\n<pasted_content id=\"b\">\ntwo\n</pasted_content id=\"b\">";
        assert_eq!(unwrap_pasted_content(raw), "one\n\nand\n\ntwo");
    }

    #[test]
    fn test_ordinary_prompt_is_untouched() {
        assert_eq!(unwrap_pasted_content("fix the flaky test"), "fix the flaky test");
        assert_eq!(unwrap_pasted_content("first\n\nsecond"), "first\n\nsecond");
    }
}
