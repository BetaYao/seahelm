import Foundation

/// The two things that are genuinely mail's own, as opposed to the command
/// grammar it shares with the Helm line and iMessage: getting the new text out
/// of a reply, and stamping the command list onto everything we send.
enum MailBody {
    /// Strips the quoted history a mail client stacks below a reply.
    ///
    /// Without this the whole thread — every earlier message, every signature —
    /// is what reaches the pane, and no command past the first mail could parse,
    /// because the quote of the previous reply sits directly beneath it.
    static func newContent(of body: String) -> String {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A quoted block never un-quotes itself, so the first marker ends
            // the new content for good.
            if trimmed.hasPrefix(">") { break }
            if trimmed.hasPrefix("________") { break }          // Outlook divider
            if trimmed == "--" || trimmed == "-- " { break }    // signature, incl. ours
            if trimmed.hasPrefix("From: ") || trimmed.hasPrefix("发件人:") { break }
            // The attribution line, keyed on how it *ends* rather than how it
            // starts. Gmail's English form opens with "On", but the Chinese one
            // opens with the sender's own name — "亮亮 <a@b.com> 于 … 写道：" —
            // so a prefix test misses it and the whole quote lands in the pane.
            if isAttribution(trimmed) { break }
            // That line also wraps at arbitrary widths, which can push the
            // trailing "wrote:" onto the next line by itself.
            if trimmed.hasPrefix("On ") || trimmed.hasPrefix("在 ") || trimmed.contains("@") {
                let next = offset + 1 < lines.count
                    ? lines[offset + 1].trimmingCharacters(in: .whitespaces) : ""
                if isAttribution(next) || next == "wrote:" || next == "写道：" { break }
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "…wrote:" / "…写道：" — the line a mail client puts above the quote. Both
    /// forms name the sender, so the only stable marker is the ending.
    private static func isAttribution(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        return line.hasSuffix("写道：") || line.hasSuffix("写道:")
            || (line.hasSuffix("wrote:") && line.count > "wrote:".count)
    }
}

/// The command list every outbound mail carries.
///
/// Mail is the one surface with no autocomplete and no keyboard help overlay, so
/// the cheatsheet rides along instead. It sits below the RFC 3676 `-- ` marker,
/// which is exactly what `MailBody.newContent` cuts at — so quoting it back in a
/// reply costs nothing.
enum MailSignature {
    /// One source of truth: the plain-text signature and the HTML one are both
    /// rendered from this, so they cannot list different commands.
    static let entries: [(command: String, detail: String)] = [
        ("/pane", "every pane, numbered"),
        ("/pane <n>", "that pane's latest — and this thread starts talking to it"),
        ("/order <n> <task>", "send one pane a task without switching to it"),
        ("/worktree", "every worktree, numbered"),
        ("/worktree <desc>", "start a new worktree and staff it"),
        ("/broadcast <task>", "send every pane the same task"),
        ("/status", "the whole fleet at a glance"),
        ("/return", "clean up finished worktrees"),
        ("/help", "this list"),
    ]

    static let closing = "Anything that isn't a command goes straight to this thread's pane."

    static var commands: String {
        let width = entries.map(\.command.count).max() ?? 0
        let rows = entries.map { "\($0.command.padding(toLength: max(width, $0.command.count), withPad: " ", startingAt: 0))  \($0.detail)" }
        return (["Reply with any of these:", ""] + rows + ["", closing]).joined(separator: "\n")
    }

    static func appended(to body: String) -> String {
        "\(body)\n\n-- \n\(commands)"
    }
}
