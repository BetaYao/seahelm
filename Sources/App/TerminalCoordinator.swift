import AppKit

protocol TerminalCoordinatorDelegate: AnyObject {
    func terminalCoordinatorDidUpdateSurfaces(_ coordinator: TerminalCoordinator)
    func terminalCoordinator(_ coordinator: TerminalCoordinator, didDeleteWorktree info: WorktreeInfo)
}

class TerminalCoordinator {
    weak var delegate: TerminalCoordinatorDelegate?
    var config: Config
    let stationManager = StationManager()
    var controlSocketServer: ControlSocketServer?

    /// Closure to access the active SplitContainerView for split pane operations.
    /// Provided by MainWindowController via DashboardViewController.
    var activeSplitContainer: () -> SplitContainerView?

    init(config: Config, activeSplitContainer: @escaping () -> SplitContainerView?) {
        self.config = config
        self.activeSplitContainer = activeSplitContainer
    }

    // MARK: - Tree Resolution

    func resolveTree(for info: WorktreeInfo) -> SplitTree {
        let backend = config.backend
        if backend != "local",
           let savedLayout = config.splitLayouts[info.path],
           let restored = SplitTree.restore(from: savedLayout, worktreePath: info.path, backend: backend) {
            // Backfill agent resume refs so a session recreated on attach (e.g.
            // after reboot) relaunches the agent instead of a bare shell.
            for leaf in restored.allLeaves {
                if let ref = config.agentSessions[leaf.sessionName] {
                    StationRegistry.shared.station(forId: leaf.stationId)?.agentSessionRef = ref
                }
            }
            stationManager.registerTree(restored, forPath: info.path)
            return restored
        }
        return stationManager.tree(for: info, backend: backend)
    }

    func saveSplitLayout(_ tree: SplitTree) {
        config.splitLayouts[tree.worktreePath] = tree.toCodable()
        config.save()
    }

    // MARK: - Split Pane Operations

    func splitFocusedPane(axis: SplitAxis) {
        guard let container = activeSplitContainer(),
              let tree = container.tree else { return }

        let sessionName = tree.nextSessionName()
        let station = Station()
        station.sessionName = sessionName
        station.backend = config.backend
        StationRegistry.shared.register(station)

        let leafId = UUID().uuidString
        tree.splitFocusedLeaf(axis: axis, newLeafId: leafId, newStationId: station.id, newSessionName: sessionName)

        // Create the terminal
        _ = station.create(in: container, workingDirectory: tree.worktreePath, sessionName: sessionName)

        // Register view and re-layout
        container.surfaceViews[station.id] = station.view
        container.layoutTree()

        // Focus the new pane. Runs deferred so it fires after _createWithCommand's own
        // deferred async (which skips makeFirstResponder when a GhosttyNSView already has focus).
        // This ensures resignFirstResponder fires on the old pane, clearing its visual focus state.
        let capturedLeafId = leafId
        DispatchQueue.main.async { [weak container] in
            guard let container,
                  let tree = container.tree,
                  let newLeaf = tree.allLeaves.first(where: { $0.id == capturedLeafId }),
                  let newStation = StationRegistry.shared.station(forId: newLeaf.stationId),
                  let termView = newStation.view else { return }
            container.window?.makeFirstResponder(termView)
        }

        delegate?.terminalCoordinatorDidUpdateSurfaces(self)
        saveSplitLayout(tree)
    }

    func closeFocusedPane() {
        guard let container = activeSplitContainer(),
              let tree = container.tree else { return }

        guard let closed = tree.closeFocusedLeaf() else { return }

        // Kill zmx session
        SessionManager.killSession(closed.sessionName, backend: config.backend)
        config.agentSessions.removeValue(forKey: closed.sessionName)

        // Remove station
        if let station = StationRegistry.shared.station(forId: closed.stationId) {
            station.view?.removeFromSuperview()
            station.destroy()
        }
        StationRegistry.shared.unregister(closed.stationId)
        container.surfaceViews.removeValue(forKey: closed.stationId)
        container.layoutTree()

        // Focus new leaf
        if let focusedLeaf = tree.allLeaves.first(where: { $0.id == tree.focusedId }),
           let focusStation = StationRegistry.shared.station(forId: focusedLeaf.stationId),
           let terminalView = focusStation.view {
            container.window?.makeFirstResponder(terminalView)
        }

        // Re-sync surface size after Ghostty processes the pixel resize.
        if let focusedLeaf = tree.allLeaves.first(where: { $0.id == tree.focusedId }),
           let focusStation = StationRegistry.shared.station(forId: focusedLeaf.stationId) {
            DispatchQueue.main.async {
                focusStation.syncSize()
            }
        }

        delegate?.terminalCoordinatorDidUpdateSurfaces(self)
        saveSplitLayout(tree)
    }

    func moveFocus(_ axis: SplitAxis, positive: Bool) {
        guard let container = activeSplitContainer() else { return }
        if let newFocusId = container.focusLeaf(direction: axis, positive: positive) {
            if let tree = container.tree,
               let leaf = tree.root.findLeaf(id: newFocusId),
               let station = StationRegistry.shared.station(forId: leaf.stationId),
               let view = station.view {
                container.window?.makeFirstResponder(view)
            }
        }
    }

    func resizeSplit(_ axis: SplitAxis, delta: CGFloat) {
        guard let container = activeSplitContainer(),
              let tree = container.tree else { return }
        guard let splitId = tree.nearestAncestorSplit(axis: axis) else { return }
        func findRatio(in node: SplitNode) -> CGFloat? {
            if node.id == splitId, case .split(_, _, let ratio, _, _) = node { return ratio }
            if case .split(_, _, _, let first, let second) = node {
                return findRatio(in: first) ?? findRatio(in: second)
            }
            return nil
        }
        if let currentRatio = findRatio(in: tree.root) {
            tree.updateRatio(splitId: splitId, newRatio: currentRatio + delta)
            container.layoutTree()
            saveSplitLayout(tree)
        }
    }

    func resetSplitRatio() {
        guard let container = activeSplitContainer(),
              let tree = container.tree else { return }
        for axis in [SplitAxis.horizontal, .vertical] {
            if let splitId = tree.nearestAncestorSplit(axis: axis) {
                tree.updateRatio(splitId: splitId, newRatio: 0.5)
            }
        }
        container.layoutTree()
        saveSplitLayout(tree)
    }

    // MARK: - Worktree Deletion

    func confirmAndDeleteWorktree(_ info: WorktreeInfo, window: NSWindow?) {
        guard !info.isMainWorktree else { return }

        let hasChanges = WorktreeDeleter.hasUncommittedChanges(worktreePath: info.path)
        let repoPath = WorktreeDiscovery.findRepoRoot(from: info.path) ?? info.path

        let alert = NSAlert()
        alert.alertStyle = hasChanges ? .critical : .warning
        alert.messageText = "Delete worktree \"\(info.branch)\"?"
        if hasChanges {
            alert.informativeText = "This worktree has uncommitted changes that will be lost."
        } else {
            alert.informativeText = "The worktree directory will be removed."
        }
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Delete + Branch")
        alert.addButton(withTitle: "Cancel")

        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[1].hasDestructiveAction = true

        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.performDeleteWorktree(info, repoPath: repoPath, deleteBranch: false, force: hasChanges)
            case .alertSecondButtonReturn:
                self.performDeleteWorktree(info, repoPath: repoPath, deleteBranch: true, force: hasChanges)
            default:
                break
            }
        }
    }

    /// Delete a worktree without the confirm alert — caller already confirmed
    /// (e.g. First Mate return-to-port approval). Does full surface teardown.
    func deleteWorktreeForReturnToPort(path: String, branch: String,
                                       deleteBranch: Bool = false, force: Bool = false) {
        let info = WorktreeInfo(path: path, branch: branch, commitHash: "", isMainWorktree: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let repoPath = WorktreeDiscovery.findRepoRoot(from: path) ?? path
            // If the caller didn't request force, check for uncommitted changes and
            // force-remove so git doesn't refuse on a dirty worktree.
            let shouldForce = force || WorktreeDeleter.hasUncommittedChanges(worktreePath: path)
            DispatchQueue.main.async {
                self?.performDeleteWorktree(info, repoPath: repoPath,
                                            deleteBranch: deleteBranch, force: shouldForce)
            }
        }
    }

    private func performDeleteWorktree(_ info: WorktreeInfo, repoPath: String, deleteBranch: Bool, force: Bool) {
        // Drop any persisted resume refs for this worktree's sessions before the
        // tree (and its session names) are gone.
        if let tree = stationManager.tree(forPath: info.path) {
            for leaf in tree.allLeaves {
                config.agentSessions.removeValue(forKey: leaf.sessionName)
            }
        }
        stationManager.removeTree(forPath: info.path)

        // Notify delegate immediately so the UI card disappears instantly
        delegate?.terminalCoordinator(self, didDeleteWorktree: info)

        DispatchQueue.global().async { [weak self] in
            do {
                try WorktreeDeleter.deleteWorktree(
                    worktreePath: info.path,
                    repoPath: repoPath,
                    branchName: info.branch,
                    deleteBranch: deleteBranch,
                    force: force
                )
                // Git deletion succeeded — no further UI update needed
            } catch {
                DispatchQueue.main.async {
                    let errAlert = NSAlert()
                    errAlert.alertStyle = .critical
                    errAlert.messageText = "Failed to delete worktree"
                    errAlert.informativeText = error.localizedDescription
                    errAlert.runModal()
                }
            }
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        controlSocketServer?.stop()
        controlSocketServer = nil
        stationManager.removeAll()
    }
}
