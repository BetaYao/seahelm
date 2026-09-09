import Foundation

/// A terminal capture, cleaned up enough to read as a conversation.
///
/// `zmx history` hands back the pane's *screen*, not its transcript: an agent
/// TUI paints a startup banner above the conversation and a composer, a
/// statusline and mode hints below it, and all of that comes back mixed in
/// with what was actually said. On the desktop the furniture is the point —
/// in a Telegram message or a mail it is noise, and for a pane that has only
/// just started (or been `/clear`ed) the capture is *nothing but* furniture.
///
/// The rules here are deliberately structural rather than a list of strings to
/// match, because every agent draws a different TUI and a list would only ever
/// describe the one we looked at last: the statusline is whatever command the
/// user configured, and the banner carries the agent's version and model of the
/// day. What the TUIs do have in common is that they draw with box and block
/// glyphs (Unicode U+2500–U+259F) and hang their furniture below the composer.
enum TerminalTranscript {

    /// The readable part of a capture, one line per surviving row. Empty when
    /// the capture held nothing but chrome — callers read that as "nothing to
    /// show" and leave the section out entirely.
    static func clean(_ text: String) -> String {
        var stripped = text
        // `\#u{…}` rather than `\u{…}`: a raw string leaves escapes uninterpreted,
        // so the plain form would look for a literal backslash-u.
        for pattern in [#"\#u{1B}\][^\#u{07}\#u{1B}]*(?:\#u{07}|\#u{1B}\\)"#,   // OSC …BEL/ST
                        #"\#u{1B}\[[0-9;?]*[ -/]*[@-~]"#,                        // CSI
                        #"\#u{1B}[@-Z\\-_]"#,                                    // lone escapes
                        #"[\#u{00}-\#u{08}\#u{0B}\#u{0C}\#u{0E}-\#u{1F}]"#] {    // stray control bytes
            stripped = stripped.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        var lines = stripped.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let footer = composerFrame(in: lines) { lines.removeSubrange(footer...) }
        return conversation(lines).joined(separator: "\n")
    }

    // MARK: - Where the conversation ends

    /// The bottom of the composer's frame: the first line of the agent's own
    /// furniture — statusline, meters, key hints, token counters. Everything
    /// from there down goes.
    ///
    /// Four things have to hold before a run of box glyphs is read as the
    /// composer rather than as something the agent printed. It has to be wide —
    /// an agent's own `───` separators are short. It has to have another
    /// decoration line just above it, because that is the rest of the frame: a
    /// lone rule is just as likely to be a markdown `---`, and cutting there
    /// would throw the answer away. It has to be near the bottom of the
    /// capture, since the furniture below the composer is only ever a few rows.
    /// And it must not close a box: a composer floor is a rule (Claude Code,
    /// pi) or a half-block (OpenCode), while a `╰───╯` is a box drawn *around*
    /// something — Codex's startup banner, Cursor Agent's trust dialog — with
    /// the conversation still to come below it. `isFloor` carries the last two:
    /// solid line, no closing corner.
    ///
    /// The composer's own text is deliberately left in: it is the operator's
    /// words, typed and not yet sent, which is worth knowing from a phone.
    private static func composerFrame(in lines: [String]) -> Int? {
        let lowest = max(0, lines.count - 1 - footerHeight)
        for index in stride(from: lines.count - 1, through: lowest, by: -1) {
            guard isFloor(lines[index]) else { continue }
            let above = stride(from: index - 1, through: max(0, index - frameLookback), by: -1)
            if above.contains(where: { isDecorationLine(lines[$0]) }) { return index }
        }
        return nil
    }

    /// Rows the furniture below the composer can occupy. Claude Code's is the
    /// tallest seen — statusline, meters, permission hint, IDE row — and its
    /// statusline wraps to a second row in a narrow pane. It stays tight on
    /// purpose: too tight only leaks a statusline, too loose loses an answer.
    private static let footerHeight = 5
    /// How far above a rule the rest of its frame can sit.
    private static let frameLookback = 4
    /// A line drawn solidly across the pane and closing nothing: the floor
    /// under a composer. A box's own blank interior row (`│` … `│`) is all
    /// decoration too and just as wide, which is why the run has to be solid.
    private static func isFloor(_ line: String) -> Bool {
        guard isDecorationLine(line), line.count >= frameWidth,
              let last = line.last, !closingCorners.contains(last) else { return false }
        return line.filter { !verticalFrames.contains($0) && $0 != " " }.count * 2 >= line.count
    }

    /// Narrower than this is a separator the agent printed, not a frame.
    private static let frameWidth = 20
    /// The bottom right of a closed box — the end of something, not the floor
    /// under the composer.
    private static let closingCorners = Set("╯┘╝┛╛╜")

    // MARK: - What is left

    private static func conversation(_ lines: [String]) -> [String] {
        var out: [String] = []
        var insideSuggestions = false
        for line in lines {
            // Rules, frames, logo rows, bare gutters: decoration and nothing else.
            if isDecorationLine(line) || isBannerRow(line) { continue }
            let text = unframed(line)
            if text.isEmpty { continue }
            if text.contains(suggestMarker) {
                insideSuggestions = true
                continue
            }
            // Seahelm's own control line wraps when it is wider than the pane,
            // and the wrapped remainder carries no marker to match on. Its
            // options are `|`-separated, so a continuation still looks like the
            // list; the line that follows the list never does.
            if insideSuggestions {
                if text.contains("|") { continue }
                insideSuggestions = false
            }
            if isChrome(text) { continue }
            out.append(text)
        }
        return out
    }

    /// Furniture an agent TUI repaints around the conversation — meters, the
    /// empty prompt caret, standing notices.
    private static func isChrome(_ line: String) -> Bool {
        // Meters and progress bars.
        if line.contains(where: { isBlock($0) }) { return true }
        if line == "❯" || line == "›" || line == ">" || line == "⏺" { return true }
        // The line that closes a turn: "✻ Churned for 44s", "✻ Worked for 1m 7s",
        // "✻ Sautéed for 2m 28s" — the verb is picked at random, so match the mark.
        if line.hasPrefix("✻") { return true }
        for marker in standingNotices where line.contains(marker) { return true }
        return false
    }

    /// Text inside a box, or behind the gutter an agent marks its own messages
    /// with, minus the drawing. Cursor Agent puts its whole UI inside a frame —
    /// a blocked pane's question included — so dropping framed lines outright
    /// would throw away the one thing worth reading.
    private static func unframed(_ line: String) -> String {
        guard let first = line.first, verticalFrames.contains(first) else { return line }
        var body = line.dropFirst()
        if let last = body.last, verticalFrames.contains(last) { body = body.dropLast() }
        return body.trimmingCharacters(in: .whitespaces)
    }

    /// A logo or banner row: two block glyphs before anything else, which is
    /// what carries Claude Code's version, model and cwd rows. Two, not one —
    /// a single `▌` is a gutter, and that line is the message.
    private static func isBannerRow(_ line: String) -> Bool {
        let opening = line.prefix(2)
        return opening.count == 2 && opening.allSatisfy { isBlock($0) }
    }

    /// Notices the TUI repaints for as long as the condition holds. Each is
    /// true and none of it is what was asked for: they are the same lines on
    /// every read until the day someone acts on them.
    private static let standingNotices = [
        "⏵⏵",                                   // permission-mode hint
        "⚠ Transcript saving",
        "new task? /clear",                     // the token-saving nudge
        "Update installed · Restart to update",
        "needs authentication · run /mcp",
    ]

    /// An instruction to the agent rather than anything it said.
    private static let suggestMarker = "::seahelm-suggest::"

    private static let verticalFrames = Set("│┃║╎╏┆┇┊┋▌▐")

    // MARK: - Glyphs

    /// Nothing but drawing: box rules and frames, logo rows, meter bars.
    private static func isDecorationLine(_ line: String) -> Bool {
        !line.isEmpty && line.allSatisfy { isDecoration($0) || $0 == " " }
    }

    /// Box Drawing plus Block Elements. Taking the two Unicode blocks whole is
    /// the point: every TUI reaches for a different corner of them, and the
    /// half-dozen glyphs any one of them uses is not a list worth maintaining.
    private static func isDecoration(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return (0x2500...0x259F).contains(scalar.value)
    }

    /// Block Elements alone — the shaded bars a meter is drawn from, and the
    /// quadrants a logo is drawn from.
    private static func isBlock(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return (0x2580...0x259F).contains(scalar.value)
    }
}
