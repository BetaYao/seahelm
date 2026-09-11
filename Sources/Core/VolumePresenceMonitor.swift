import AppKit
import Foundation

/// Watches workspace volumes for abrupt disconnects and remounts.
///
/// USB / Thunderbolt volumes often vanish without a clean unmount: the path
/// stays in the namespace but every `stat()` blocks forever. That is what
/// beachballed Seahelm after an external disk dropped — path compares and
/// dashboard sort keys hit the dead mount on the main thread, while timers kept
/// spawning `git` / `zmx` against it.
///
/// This monitor fences those volume roots (see `VolumeFence`), stops refresh
/// work against them, force-kills wedged zmx sessions, and unfences on remount
/// so panes can recover.
final class VolumePresenceMonitor {
    static let shared = VolumePresenceMonitor()

    /// Invoked on the main queue when a previously-fenced volume becomes
    /// reachable again (remount). Stations / discovery can re-probe.
    var onVolumeRecovered: ((String) -> Void)?

    private var workspacePaths: [String] = []
    private var probeTimer: Timer?
    private let probeInterval: TimeInterval = 5
    private let probeTimeout: TimeInterval = 0.5
    private var observing = false

    private init() {}

    /// Start watching the given workspace paths (repo roots and worktrees).
    /// Safe to call repeatedly — replaces the watched set.
    func start(workspacePaths: [String]) {
        self.workspacePaths = workspacePaths
        startObservingNotificationsIfNeeded()
        scheduleProbeTimer()
        probeNow()
    }

    func stop() {
        probeTimer?.invalidate()
        probeTimer = nil
        if observing {
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            observing = false
        }
    }

    private func startObservingNotificationsIfNeeded() {
        guard !observing else { return }
        observing = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(volumeWillUnmount(_:)),
            name: NSWorkspace.willUnmountNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(volumeDidUnmount(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(volumeDidMount(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
    }

    private func scheduleProbeTimer() {
        probeTimer?.invalidate()
        probeTimer = Timer.scheduledTimer(withTimeInterval: probeInterval, repeats: true) { [weak self] _ in
            self?.probeNow()
        }
    }

    @objc private func volumeWillUnmount(_ note: Notification) {
        fenceIfWorkspaceVolume(from: note)
    }

    @objc private func volumeDidUnmount(_ note: Notification) {
        fenceIfWorkspaceVolume(from: note)
    }

    @objc private func volumeDidMount(_ note: Notification) {
        guard let root = volumeRoot(from: note) else { return }
        // Remount: verify with a real probe before unfencing — a mount
        // notification can arrive before the filesystem is actually responsive.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let known = FileSystemProbe.existsIfKnown(root, timeout: self?.probeTimeout ?? 0.5)
            DispatchQueue.main.async {
                guard let self else { return }
                if known == true {
                    self.recover(root)
                } else {
                    VolumeFence.fence(root)
                }
            }
        }
    }

    private func fenceIfWorkspaceVolume(from note: Notification) {
        guard let root = volumeRoot(from: note), hostsWorkspace(root) else { return }
        applyFence(root)
    }

    private func volumeRoot(from note: Notification) -> String? {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return nil }
        return VolumeFence.volumeRoot(for: url.path) ?? url.path
    }

    private func hostsWorkspace(_ root: String) -> Bool {
        workspacePaths.contains { path in
            VolumeFence.volumeRoot(for: path) == root || path == root || path.hasPrefix(root + "/")
        }
    }

    /// Unique `/Volumes/…` roots covered by the current workspace set.
    private var watchedRoots: [String] {
        var roots = Set<String>()
        for path in workspacePaths {
            if let root = VolumeFence.volumeRoot(for: path) {
                roots.insert(root)
            }
        }
        return Array(roots)
    }

    private func probeNow() {
        let roots = watchedRoots
        guard !roots.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var newlyDead: [String] = []
            var newlyAlive: [String] = []
            for root in roots {
                let known = FileSystemProbe.existsIfKnown(root, timeout: self.probeTimeout)
                let wasFenced = VolumeFence.isFenced(root)
                switch known {
                case .none, .some(false):
                    if !wasFenced { newlyDead.append(root) }
                    VolumeFence.fence(root)
                case .some(true):
                    if wasFenced { newlyAlive.append(root) }
                    VolumeFence.unfence(root)
                }
            }
            DispatchQueue.main.async {
                for root in newlyDead {
                    self.applyFence(root)
                }
                for root in newlyAlive {
                    self.recover(root)
                }
            }
        }
    }

    private func applyFence(_ root: String) {
        VolumeFence.fence(root)
        NSLog("[VolumePresence] Fencing unreachable volume %@", root)
        DispatchQueue.global(qos: .utility).async {
            let cleaned = SessionManager.cleanupWedgedVolumeSessions()
            if !cleaned.isEmpty {
                NSLog("[VolumePresence] Cleaned %d wedged zmx session(s) on %@", cleaned.count, root)
            }
        }
    }

    private func recover(_ root: String) {
        VolumeFence.unfence(root)
        NSLog("[VolumePresence] Volume %@ reachable again", root)
        onVolumeRecovered?(root)
    }
}
