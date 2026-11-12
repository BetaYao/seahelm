import Foundation

/// Everything the app under test touches, kept out of the user's live setup.
///
/// A UI test used to launch the app on the real `~/.config/seahelm/config.json`,
/// the live seahelm-core and the real seahelmd sessions: ⌘D in a test split a
/// pane in the user's own layout and saved it. Now each launch names a scratch
/// directory under /tmp (short: socket paths cap near 104 bytes) for its home
/// (`CFFIXED_USER_HOME` moves Foundation's home, `HOME` the children's), the
/// core's socket and the seahelmd socket dir. The runner is sandboxed and
/// cannot create it; the app does, under `-SeahelmUITesting`
/// (`UITestScratch`). `run_ui_tests.sh` clears it after the run, and each app
/// launch clears what older launches left (`UITestScratch.sweepStale`), so a
/// bare `xcodebuild test` or ⌘U leaves nothing running for long either.
struct ScratchHome {
    let root = "/tmp/shui-\(UUID().uuidString.prefix(8))"

    var environment: [String: String] {
        [
            "SEAHELM_UITEST_SCRATCH": root,
            "CFFIXED_USER_HOME": "\(root)/h",
            "HOME": "\(root)/h",
            "SEAHELM_CORE_SOCKET": "\(root)/c.sock",
            "SEAHELMD_DIR": "\(root)/d",
        ]
    }
}
