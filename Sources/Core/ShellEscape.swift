import Foundation

/// Shell-escaping helpers for building command strings that are interpreted by
/// a POSIX shell (e.g. agent launch commands sent to tmux/zmx sessions).
enum ShellEscape {
    /// Wrap a value in single quotes, safely escaping embedded single quotes.
    /// Everything else (including $, ", spaces) becomes literal.
    static func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
