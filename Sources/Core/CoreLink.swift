import Foundation

/// The app's connection to seahelm-core, the service every seahelm client
/// shares (docs/target-architecture.html). The app makes sure the core runs,
/// shows it the fleet, and takes from it what the core owns: the command
/// language (`command.run`), pane handles, and sessions it starts.
///
/// - **Running**: `seahelm-core ensure` at launch, the binary shipped in
///   Contents/Resources/bin beside seahelmd, and again whenever the core has
///   stopped answering for a while (at most every `ensureInterval`): `ensure`
///   starts one only if nothing answers, so it never replaces a live core.
///   While it is silent the island says so (`IslandWarning.core`).
/// - **The fleet**: every 2 s, the panes as `pane.list` answers them
///   (`pane.sync`) and every worktree (`worktrees.set`), so the core watches
///   exactly what the app shows; and every split tree (`layouts.set`), which
///   the core only keeps, so the web (through seahelm-gateway) can lay a
///   worktree's panes out as the window does (`layout.get`).
/// - **Handles**: the core numbers every pane (`#n`, in `pane.list`) and the
///   app shows its numbers (`handles`), so a chat and the desktop name a
///   pane the same way. A pane the core has not listed yet has none.
/// - **Sessions the core started** (`/new` from a chat): a worktree the app
///   opens for the first time takes the core's session for its first pane
///   instead of starting an empty one beside it.
final class CoreLink {
    static let shared = CoreLink()

    /// What `pane.list` would answer, and every worktree path. Set by the owner.
    var panes: () -> [[String: Any]] = { [] }
    var worktrees: () -> [String] = { [] }
    /// Every live split tree by worktree path (`TerminalCoordinator.liveLayouts`).
    var layouts: () -> [String: [String: Any]] = { [:] }

    /// Whether the core answered the last sync. Main thread.
    private(set) var reachable = false
    /// Since when the core has not answered (from `start` until the first
    /// sync it answers); nil while it does. Main thread.
    private(set) var unreachableSince: Date?
    /// The core's `#n` for each pane, by seahelmd session name, from its last
    /// `pane.list`. Main thread.
    private(set) var handles: [String: Int] = [:]
    private var lastEnsure: Date?
    static let ensureInterval: TimeInterval = 15
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
        unreachableSince = Date()
        ensure()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sync() }
    }

    /// Start the core if nothing answers on its socket (`seahelm-core ensure`).
    private func ensure() {
        lastEnsure = Date()
        DispatchQueue.global(qos: .utility).async {
            guard let binary = Self.binary else {
                NSLog("[CoreLink] no seahelm-core binary")
                return
            }
            let result = ProcessRunner.capture(executable: URL(fileURLWithPath: binary), arguments: ["ensure"], timeout: 10)
            if !result.succeeded { NSLog("[CoreLink] seahelm-core ensure failed") }
        }
    }

    /// Whether a silent core is worth an `ensure` now: silent for a few syncs,
    /// and not tried within `ensureInterval`.
    static func shouldEnsure(unreachableSince: Date?, lastEnsure: Date?, now: Date) -> Bool {
        guard let since = unreachableSince, now.timeIntervalSince(since) >= 4 else { return false }
        guard let last = lastEnsure else { return true }
        return now.timeIntervalSince(last) >= ensureInterval
    }

    /// The core's `#n` for the pane on this seahelmd session, if it has one.
    func handle(forSession key: String?) -> Int? {
        guard let key, !key.isEmpty else { return nil }
        return handles[key]
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
        let layouts = self.layouts()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = CoreSocketClient.call("worktrees.set", ["paths": worktrees])
            _ = CoreSocketClient.call("layouts.set", ["client": "macos", "layouts": layouts])
            let synced = CoreSocketClient.call("pane.sync", ["panes": panes])
            let listed = CoreSocketClient.call("pane.list")
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncing = false
                guard case .success = synced, case .success(let list) = listed else {
                    self.reachable = false
                    if self.unreachableSince == nil { self.unreachableSince = Date() }
                    if Self.shouldEnsure(unreachableSince: self.unreachableSince, lastEnsure: self.lastEnsure, now: Date()) {
                        self.ensure()
                    }
                    return
                }
                self.reachable = true
                self.unreachableSince = nil
                let rows = list["panes"] as? [[String: Any]] ?? []
                let (handles, adoptable) = Self.read(rows, appSessions: Set(panes.compactMap { $0["pane_session_key"] as? String }))
                self.handles = handles
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
