import AppKit

// The app may be (re)launched from a shell that lives inside a seahelm pane
// (dev rebuilds, agents relaunching the app). That shell runs inside a zmx
// session, so ZMX_SESSION / SEAHELM_* leak into our environment — and every
// Ghostty surface inherits it. `zmx attach <name>` silently prefers
// $ZMX_SESSION over its argument, so a leaked value makes every pane attach
// to the wrong (often dead) session: layout restores, content doesn't.
// Scrub before anything can spawn a child.
for leaked in ["ZMX_SESSION", "SEAHELM_ENV", "SEAHELM_SOCKET_PATH", "SEAHELM_PANE_ID"] {
    unsetenv(leaked)
}

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
