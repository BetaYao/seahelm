import AppKit

/// Settings window presentation for the main window.
final class DialogPresenter {
    /// Settings is a window, not a sheet — it applies live and has no Save, so
    /// it isn't a transaction the way a sheet is.
    func makeSettings(config: Config, settingsDelegate: SettingsDelegate) -> SettingsWindowController {
        SettingsWindowController(config: config, settingsDelegate: settingsDelegate)
    }
}
