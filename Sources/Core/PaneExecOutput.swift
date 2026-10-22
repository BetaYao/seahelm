import Foundation

/// The text a `pane.exec` command left on screen: the scrollback between the
/// line it was echoed on and the prompt that came back. It is what the
/// terminal shows — stdout and stderr interleaved, as rendered — not a
/// separate capture of the process's streams.
enum PaneExecOutput {
    /// `history` is the session's scrollback tail; `command` what was run;
    /// `promptLines` how many lines the shell's prompt takes (the widget reports
    /// it). `truncated` when the echoed command is no longer in `history`, so
    /// the start of the output is missing.
    static func extract(history: String, command: String, promptLines: Int) -> (text: String, truncated: Bool) {
        var lines = history.components(separatedBy: "\n")
        dropTrailingBlank(&lines)
        // The prompt that came back after the command.
        lines.removeLast(min(max(promptLines, 1), lines.count))
        dropTrailingBlank(&lines)

        guard let echoEnd = echoEnd(of: command, in: lines) else {
            return (lines.joined(separator: "\n"), true)
        }
        return (lines[(echoEnd + 1)...].joined(separator: "\n"), false)
    }

    /// The last line of the command's echo. The echo spans several lines when
    /// the command has newlines or is wider than the terminal — soft-wrapped
    /// mid-word, sometimes at a space the scrollback then trims — so lines are
    /// joined and compared with whitespace removed. Searched from the end, and
    /// the command must reach into the line found, so the most recent echo wins.
    private static func echoEnd(of command: String, in lines: [String]) -> Int? {
        let needle = squeezed(command)
        guard !needle.isEmpty else { return nil }
        let squeezedLines = lines.map(squeezed)
        for end in stride(from: squeezedLines.count - 1, through: 0, by: -1) {
            var joined = squeezedLines[end]
            var start = end
            while joined.count < needle.count + squeezedLines[end].count, start > 0 {
                start -= 1
                joined = squeezedLines[start] + joined
            }
            guard joined.contains(needle) else { continue }
            let beforeEnd = squeezedLines[start..<end].joined()
            if !beforeEnd.contains(needle) { return end }
        }
        return nil
    }

    private static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    private static func dropTrailingBlank(_ lines: inout [String]) {
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
    }
}
