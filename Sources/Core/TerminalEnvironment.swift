import Foundation

/// The `TERM`/`TERMINFO` pair libghostty injects into every PTY it spawns.
///
/// Panes opened through a Ghostty surface get this for free, which is why the
/// gap below only ever shows up in installed builds. The detached launch path
/// (`SessionManager.createDetachedSession`) spawns `zmx run` straight from the
/// app process, bypassing Ghostty entirely — so it inherits whatever launched
/// Seahelm. From a terminal that is a full environment; from Finder/launchd it
/// is `PATH`, `HOME`, `USER`, `SHELL` and little else, with **no `TERM` at
/// all**. Everything downstream that consults terminfo then fails: first the
/// screen clear (which used to abort the whole `&&` chain before the agent was
/// ever exec'd), then the agent's own TUI.
enum TerminalEnvironment {
    /// What Ghostty sets. Resolvable only against the bundled database below.
    static let ghosttyTerm = "xterm-ghostty"

    /// Always present in /usr/share/terminfo — the fallback for a bundle whose
    /// mirrored database is missing, where `xterm-ghostty` would not resolve.
    static let fallbackTerm = "xterm-256color"

    /// Directory holding the bundled terminfo database, if it shipped.
    /// `project.yml` mirrors ghostty's copy to `Contents/Resources/terminfo`
    /// precisely so `xterm-ghostty` resolves without Ghostty.app installed.
    static func bundledTerminfoPath() -> String? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("terminfo", isDirectory: true),
            FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.path
    }

    /// `KEY=value` assignments to hand to `/usr/bin/env` ahead of a command, so
    /// the whole PTY session — session shell, its rc files, and the agent —
    /// sees the same terminal the attach path would have given it. Pure: the
    /// caller supplies the database location.
    static func envAssignments(terminfoPath: String?) -> [String] {
        guard let terminfoPath else { return ["TERM=\(fallbackTerm)"] }
        return ["TERM=\(ghosttyTerm)", "TERMINFO=\(terminfoPath)"]
    }

    /// Clear the screen (and scrollback) without consulting terminfo.
    ///
    /// `clear` reads the terminfo database and exits non-zero when it cannot,
    /// which made it a single point of failure in the middle of an `&&` chain.
    /// The escapes are unconditional: erase display, erase scrollback, home.
    static let clearScreenCommand = #"printf '\033[2J\033[3J\033[H'"#
}
