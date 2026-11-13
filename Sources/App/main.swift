import AppKit

// The app may be (re)launched from a shell that lives inside a seahelm pane
// (dev rebuilds, agents relaunching the app). That shell runs inside a seahelmd
// session, so SEAHELMD_SESSION / SEAHELM_* leak into our environment — and
// every Ghostty surface inherits it, so a pane's hooks would report under the
// relaunching pane's id.
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
// NO_COLOR / FORCE_COLOR are not session identity, but they leak by the same
// route and do more damage, because they outlive the launch that carried them:
// a pane's environment is fixed when its seahelmd session is created, and
// re-attaching never re-execs the agent. So one relaunch from a shell that
// happened to have them set (Cursor's tool shells inject both: NO_COLOR=1 and
// FORCE_COLOR=0) leaves those panes rendering monochrome forever, surviving
// every later app restart. A pane is always a real terminal, so the launching
// shell's opinion about color never applies to it.
//
// Scrub before anything can spawn a child.
let leakedEnv = [
    "SEAHELMD_SESSION", "SEAHELM_ENV", "SEAHELM_SOCKET_PATH", "SEAHELM_PANE_ID",
    "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
    "NO_COLOR", "FORCE_COLOR",
]
for leaked in leakedEnv {
    unsetenv(leaked)
}

UITestScratch.prepareIfAsked()

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
