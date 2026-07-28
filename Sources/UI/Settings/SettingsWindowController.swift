import AppKit

/// Settings as a real window, not a sheet.
///
/// The sheet had to carry Save/Cancel because a sheet is a transaction. A window
/// isn't: the page applies as you change it and persists immediately, so the
/// only affordance left is the close button — which is why this window keeps its
/// traffic lights and drops the button bar.
///
/// The titlebar is transparent and the content runs full height, so the lights
/// float over the sidebar the way they do in the apps this borrows from.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settingsViewController: SettingsViewController

    init(config: Config, settingsDelegate: SettingsDelegate?) {
        settingsViewController = SettingsViewController(config: config)
        settingsViewController.settingsDelegate = settingsDelegate

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = SettingsPalette.windowBg
        window.contentViewController = settingsViewController
        window.setContentSize(NSSize(width: 820, height: 600))
        window.minSize = NSSize(width: 720, height: 460)

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func show() {
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A field still being edited has not fired its action yet, and closing the
    /// window would drop it. Commit first.
    func windowWillClose(_ notification: Notification) {
        settingsViewController.commitPendingEdits()
    }
}
