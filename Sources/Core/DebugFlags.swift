import Foundation

/// DEBUG-only launch switches, read once from the environment.
///
/// These exist to photograph states that are otherwise hard to reach in a live
/// app (a first launch, once you already have repos). They are compiled out of
/// release builds entirely.
enum DebugFlags {

    /// `SEAHELM_FORCE_EMPTY_STATE=1` — render the dashboard's first-run empty
    /// state regardless of the real repo/agent inventory.
    ///
    /// This also makes the instance stand down from the control socket
    /// (`ControlSocketServer.start()` unlinks the socket path before binding, so
    /// a second instance would silently steal the live app's socket and strand
    /// its panes) and from writing config. A screenshot instance is a spectator:
    /// it must not touch the state a real instance owns.
    static let forceEmptyState: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SEAHELM_FORCE_EMPTY_STATE"] == "1"
        #else
        return false
        #endif
    }()
}
