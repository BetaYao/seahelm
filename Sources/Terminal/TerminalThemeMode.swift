import Foundation

/// Which palette a pane's terminal renders with — deliberately **not** the
/// app's live light/dark appearance.
///
/// A pane hosts long-running TUIs, and a TUI reads the terminal's colors once.
/// Codex asks over `OSC 10;?` / `OSC 11;?` at startup and caches the answer for
/// the life of the process — it does not enable DEC mode 2031, so Ghostty's
/// color-scheme-change report (`Surface.colorSchemeCallback`) never reaches it.
/// Flip the palette under a running one and it keeps painting from the stale
/// reading, because it only ever sets a *background* and leaves the text at
/// SGR 39 (the terminal's real default foreground). A stale Latte reading fills
/// the user-message pill with `blend(black, #eff1f5, 0.04)` = `#e5e7eb` while
/// the text stays Mocha's `#cdd6f4`: near-white on near-white, unreadable, for
/// the rest of that session. Its own re-styled chrome meanwhile picks up the new
/// reading, which is how a single frame ends up carrying both palettes.
///
/// So a run's palette is fixed for the whole run. `app` reads the appearance
/// once at launch and holds it; `dark`/`light` ignore the appearance entirely.
/// Toggling the app theme restyles Seahelm's own UI — panes keep their palette
/// until the next launch, which is the only honest contract we can offer a
/// process that latched the answer before we could tell it otherwise.
enum TerminalThemeMode: String, CaseIterable {
    /// Match the app appearance as it stood at launch, then hold it.
    case app
    /// Always Catppuccin Mocha, whatever the app appearance is.
    case dark
    /// Always Catppuccin Latte, whatever the app appearance is.
    case light

    /// Config is hand-editable, so an unknown value reads as `app` rather than
    /// failing the whole decode.
    static func parse(_ raw: String) -> TerminalThemeMode {
        TerminalThemeMode(rawValue: raw.lowercased()) ?? .app
    }

    /// Pure resolution. `appAppearanceIsDark` is consulted by `app` alone.
    func isDark(appAppearanceIsDark: Bool) -> Bool {
        switch self {
        case .app: return appAppearanceIsDark
        case .dark: return true
        case .light: return false
        }
    }
}
