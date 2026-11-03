import Foundation

/// Which palette a pane's terminal renders with.
///
/// `app` (default) follows the app's light/dark appearance live: a theme toggle,
/// or macOS switching on its own under `theme_mode = system`, repaints every
/// pane (`GhosttyBridge.refreshColorScheme`). `dark`/`light` pin the palette
/// whatever the appearance is.
///
/// The known cost of following live: a TUI that reads the terminal's colours
/// once and caches them does not see the flip. Codex asks over `OSC 10;?` /
/// `OSC 11;?` at startup, caches the answer for the life of the process and does
/// not enable DEC mode 2031, so it keeps painting from the stale reading — it
/// only sets a *background* and leaves text at SGR 39, so a stale Latte reading
/// fills the user-message pill with `#e5e7eb` while the text stays Mocha's
/// `#cdd6f4`. Restarting the agent fixes it; pinning `dark`/`light` avoids it.
/// (From b28f441 until this change the palette was latched per run instead;
/// the window disagreeing with its own panes was judged the worse trade.)
enum TerminalThemeMode: String, CaseIterable {
    /// Follow the app appearance, live.
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
