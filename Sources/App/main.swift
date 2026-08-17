import AppKit

// The app may be (re)launched from a shell that lives inside a seahelm pane
// (dev rebuilds, agents relaunching the app). That shell runs inside a zmx
// session, so ZMX_SESSION / SEAHELM_* leak into our environment — and every
// Ghostty surface inherits it. `zmx attach <name>` silently prefers
// $ZMX_SESSION over its argument, so a leaked value makes every pane attach
// to the wrong (often dead) session: layout restores, content doesn't.
//
// The same shell is usually an agent's, which leaks that agent's session
// identity the same way — and an agent inheriting it disables its own
// transcript saving ("Transcript saving is off — inherited
// CLAUDE_CODE_CHILD_SESSION"), so the pane's conversation is silently lost on
// exit and cannot be resumed. The messaging socket/token are worse than stale:
// they point a fresh agent at the relaunching agent's channel. CLAUDE_CODE_EXECPATH
// is left alone — it names a binary, not a session, and a pane may legitimately
// want the same one.
//
// Scrub before anything can spawn a child.
let leakedSessionEnv = [
    "ZMX_SESSION", "SEAHELM_ENV", "SEAHELM_SOCKET_PATH", "SEAHELM_PANE_ID",
    "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
]
for leaked in leakedSessionEnv {
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
