import Foundation

/// Turning a submitted prompt into what a person should be shown — or deciding
/// that nobody said anything worth showing.
///
/// Not every turn Claude Code opens is a person speaking. When a background task
/// finishes, the harness injects the result into the conversation as a user turn
/// and fires `UserPromptSubmit` for it, so seahelm sees a prompt reading
/// `<task-notification>…</task-notification>`. On a live fleet that was a
/// quarter of the timeline's user side: 14 of 57 messages in one pane's ring,
/// each one machine plumbing rendered as though the user had typed it.
///
/// The payload gives us nothing to filter on. Claude Code's transcript marks
/// these records `promptSource: "system"` with `origin.kind = "task-notification"`,
/// but the hook payload carries only `cwd`, `hook_event_name`, `prompt`,
/// `prompt_id`, `permission_mode`, `scratchpad_dir`, `session_id` and
/// `transcript_path` — no discriminator at all. So the shape of the text is the
/// only signal there is, which is why this reads as conservatively as it does.
///
/// The event itself is never dropped on this account: a background task
/// completing really does start a turn, so `.userPrompt` still has to drive
/// `hookStatus = .running`. Only the *display* of it is suppressed.
enum UserPromptText {

    /// Blocks the harness writes into a turn on its own account. Only
    /// `task-notification` has been observed reaching this seam; `system-reminder`
    /// is here because it is unambiguously machine plumbing and costs nothing to
    /// name, not because it has been seen.
    private static let machineBlocks = ["task-notification", "system-reminder"]

    /// What a human should be shown for `raw`, or nil when the turn was not a
    /// person speaking.
    ///
    /// A prompt counts as machine plumbing only when it is *entirely* one such
    /// block. Someone quoting a notification around their own words — which is
    /// exactly how this bug got reported — is a person speaking, and their
    /// message is left whole rather than having the quote cut out of it.
    static func humanText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !isWhollyMachineBlock(trimmed) else { return nil }
        let unwrapped = unwrapPastedContent(trimmed)
        return unwrapped.isEmpty ? nil : unwrapped
    }

    /// Whether `trimmed` is one machine block and nothing else.
    static func isWhollyMachineBlock(_ trimmed: String) -> Bool {
        machineBlocks.contains { tag in
            trimmed.hasPrefix("<\(tag)>") && trimmed.hasSuffix("</\(tag)>")
        }
    }

    /// Take Claude Code's paste wrapper off a prompt.
    ///
    /// Anything long enough arriving as a bracketed paste — which is how every
    /// message seahelm delivers to a pane arrives, and how a person's own ⌘V
    /// arrives — is recorded by Claude Code wrapped in
    /// `<pasted_content id="240b">…</pasted_content id="240b">`. The marker is
    /// for the agent, telling it which part of the turn was pasted rather than
    /// typed. Every reader on this side is a human looking at a title, a
    /// timeline row or a phone notification, and to them it is noise around
    /// their own words.
    ///
    /// Only the wrapper goes; what was pasted is the message. The closing tag
    /// repeats the attribute (`</pasted_content id="240b">`), which no parser
    /// would accept, so this matches the shape Claude Code actually writes
    /// rather than well-formed markup.
    static func unwrapPastedContent(_ text: String) -> String {
        guard text.contains("<pasted_content") else { return text }
        let stripped = text.replacingOccurrences(
            of: "</?pasted_content[^>]*>",
            with: "",
            options: .regularExpression)
        // The tags sat on lines of their own; removing them leaves the blank
        // lines that held them apart.
        return stripped
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
