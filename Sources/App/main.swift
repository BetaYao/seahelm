import AppKit

let app = NSApplication.shared
NSWindow.allowsAutomaticWindowTabbing = false

// Force appearance BEFORE anything else — must happen before any views are created.
// This is the earliest possible point in the app lifecycle.
let themeMode = Config.load().themeMode
switch themeMode {
case "dark":
    app.appearance = NSAppearance(named: .darkAqua)
case "light":
    app.appearance = NSAppearance(named: .aqua)
case "system":
    app.appearance = nil  // follow system setting
default:
    app.appearance = NSAppearance(named: .darkAqua)
}
NSAppearance.current = app.effectiveAppearance

let delegate = AppDelegate()
app.delegate = delegate
app.run()
