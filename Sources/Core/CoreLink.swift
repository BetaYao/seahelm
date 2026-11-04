import Foundation

/// The app's connection to seahelm-core, the service every seahelm client
/// shares (docs/target-architecture.html). The app makes sure the core runs,
/// shows it the fleet, and takes from it what the core owns: the command
/// language (`command.run`), pane handles, and sessions it starts.
///
/// - **Running**: `seahelm-core ensure` at launch, the binary shipped in
///   Contents/Resources/bin beside seahelmd.
/// - **The fleet**: every 2 s, the panes as `pane.list` answers them
///   (`pane.sync`) and every worktree (`worktrees.set`), so the core watches
///   exactly what the app shows.
/// - **Handles**: the core's `#n` win (`PaneHandleRegistry.adopt`), so a
///   chat and the desktop name a pane the same way.
/// - **Sessions the core started** (`/new` from a chat): a worktree the app
///   opens for the first time takes the core's session for its first pane
///   instead of starting an empty one beside it.
final class CoreLink {
    static let shared = CoreLink()

    /// What `pane.list` would answer, and every worktree path. Set by the owner.
    var panes: () -> [[String: Any]] = { [] }
    var worktrees: () -> [String] = { [] }

    /// Whether the core answered the last sync. Main thread.
    private(set) var reachable = false
    /// Worktree path → a live session the core has there that no app pane
    /// uses. Main thread.
    private var adoptable: [String: String] = [:]
    private var timer: Timer?
    private var syncing = false

    /// Contents/Resources/bin/seahelm-core, else `$SEAHELM_CORE_BIN`.
    static var binary: String? {
        if let url = Bundle.main.url(forResource: "seahelm-core", withExtension: nil, subdirectory: "bin"),
           FileManager.default.isExecutableFile(atPath: url.path) { return url.path }
        if let env = ProcessInfo.processInfo.environment["SEAHELM_CORE_BIN"], !env.isEmpty { return env }
        return ProcessRunner.commandPath("seahelm-core")
    }

    func start() {
        guard timer == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let binary = Self.binary else {
                NSLog("[CoreLink] no seahelm-core binary; commands run in the app")
                return
            }
            let result = ProcessRunner.capture(executable: URL(fileURLWithPath: binary), arguments: ["ensure"], timeout: 10)
            if !result.succeeded { NSLog("[CoreLink] seahelm-core ensure failed") }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sync() }
    }

    /// The core's session for a worktree the app is about to give its first
    /// pane, taken once.
    func takeAdoptableSession(forWorktree path: String) -> String? {
        adoptable.removeValue(forKey: path)
    }

    private func sync() {
        guard !syncing else { return }
        syncing = true
        let panes = self.panes()
        let worktrees = self.worktrees()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = CoreSocketClient.call("worktrees.set", ["paths": worktrees])
            let synced = CoreSocketClient.call("pane.sync", ["panes": panes])
            let listed = CoreSocketClient.call("pane.list")
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncing = false
                guard case .success = synced, case .success(let list) = listed else {
                    self.reachable = false
                    return
                }
                self.reachable = true
                let rows = list["panes"] as? [[String: Any]] ?? []
                let (handles, adoptable) = Self.read(rows, appSessions: Set(panes.compactMap { $0["pane_session_key"] as? String }))
                PaneHandleRegistry.shared.adopt(handles)
                self.adoptable = adoptable
            }
        }
    }

    /// From the core's `pane.list`: every pane's handle, and per worktree a
    /// session the app has no pane on.
    static func read(_ rows: [[String: Any]], appSessions: Set<String>) -> (handles: [String: Int], adoptable: [String: String]) {
        var handles: [String: Int] = [:]
        var adoptable: [String: String] = [:]
        for row in rows {
            guard let key = row["pane_session_key"] as? String, !key.isEmpty else { continue }
            if let handle = (row["handle"] as? NSNumber)?.intValue { handles[key] = handle }
            if !appSessions.contains(key), let path = row["worktree_path"] as? String, adoptable[path] == nil {
                adoptable[path] = key
            }
        }
        return (handles, adoptable)
    }
}
