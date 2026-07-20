import AppKit

/// Confirmation gate for quitting the app.
///
/// Two paths reach termination and both must be guarded: clicking the red close
/// button (`windowShouldClose`) and Cmd+Q / the menu item
/// (`applicationShouldTerminate`). Because
/// `applicationShouldTerminateAfterLastWindowClosed` is `true`, closing the window
/// *also* runs the terminate path, so a naive implementation asks twice — hence
/// `isConfirmed`, which latches the answer for the rest of the process's life.
enum QuitConfirmation {
    /// Latched once the user has approved a quit, so the second hook on the same
    /// close doesn't put up a second dialog.
    static var isConfirmed = false

    /// Set by flows that terminate deliberately and must not be interrupted —
    /// currently the updater relaunching into a new version.
    static var isBypassed = false

    /// Returns whether the quit may proceed, prompting if it should.
    /// Must be called on the main thread; runs a modal alert.
    static func shouldQuit(for window: NSWindow?) -> Bool {
        if isBypassed || isConfirmed { return true }
        // Read from disk rather than a cached copy: Config is a value type and
        // several coordinators hold their own, so an in-memory one may be stale.
        guard Config.load().confirmBeforeQuit else { return true }

        let alert = NSAlert()
        alert.messageText = "Quit Seahelm?"
        alert.informativeText = "Terminal sessions keep running in the background and are restored on next launch."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        // Deliberately modal rather than a sheet: a sheet returns asynchronously,
        // which cannot answer the synchronous Bool that both AppKit hooks demand.
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        guard confirmed else { return false }

        if alert.suppressionButton?.state == .on {
            // saveNow, not save: the debounced writer would lose the race with
            // termination and the preference would silently not stick.
            var config = Config.load()
            config.confirmBeforeQuit = false
            config.saveNow()
        }

        isConfirmed = true
        return true
    }
}
