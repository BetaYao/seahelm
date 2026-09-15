import Foundation

/// Shell-escaping helpers for building command strings that are interpreted by
/// a POSIX shell (e.g. agent launch commands sent to zmx sessions).
enum ShellEscape {
    /// Wrap a value in single quotes, safely escaping embedded single quotes.
    /// Everything else (including $, ", spaces) becomes literal.
    static func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Backslash-escape shell metacharacters, the way native Ghostty types a
    /// dropped file's path (`Ghostty.Shell.escape`), so it reads like a path the
    /// user typed. A value holding a control character is single-quoted instead:
    /// a backslash before a newline is a line continuation, not a literal.
    static func backslash(_ value: String) -> String {
        if value.unicodeScalars.contains(where: { $0 != "\t" && CharacterSet.controlCharacters.contains($0) }) {
            return singleQuote(value)
        }
        var result = value
        for char in backslashEscaped {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    /// Backslash first, so the escapes added after it aren't doubled.
    private static let backslashEscaped = "\\ ()[]{}<>\"'`!#$&;|*?\t"
}
