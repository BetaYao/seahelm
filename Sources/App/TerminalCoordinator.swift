import AppKit

protocol TerminalCoordinatorDelegate: AnyObject {
    func terminalCoordinatorDidUpdateSurfaces(_ coordinator: TerminalCoordinator)
    func terminalCoordinator(_ coordinator: TerminalCoordinator, didDeleteWorktree info: WorktreeInfo)
}

class TerminalCoordinator {
    weak var delegate: TerminalCoordinatorDelegate?
    var config: Config
    /// Resolved runtime backend ("zmx" or "local"). Set by MainWindowController
    /// after zmx availability is checked; starts at "zmx" so early tree restore
    /// attaches persistent sessions before the async resolution lands.
    var runtimeBackend: String = "zmx"
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
        let backend = runtimeBackend
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

    /// Enrol a freshly split pane in ShipLog. StationRegistry alone is not enough:
    /// `ShipLog.handleWebhookEvent` resolves a hook's SEAHELM_PANE_ID to a station
    /// and then requires that station to be a known agent, so a pane missing here
    /// silently falls back to the worktree's *first* pane — every hook, and every
    /// suggestion chip tapped for this pane, lands in a sibling.
    /// Branch/project come from a sibling in the same worktree, which shares both.
    private func registerSplitStation(_ station: Station, worktreePath: String, sessionName: String) {
        let sibling = ShipLog.shared.sailor(forWorktree: worktreePath)
        ShipLog.shared.register(
            station: station,
            worktreePath: worktreePath,
            branch: sibling?.branch ?? "",
            project: sibling?.project ?? URL(fileURLWithPath: worktreePath).lastPathComponent,
            startedAt: Date(),
            sessionName: runtimeBackend == "local" ? nil : sessionName,
            backend: runtimeBackend
        )
    }

    func splitFocusedPane(axis: SplitAxis) {
        guard let container = activeSplitContainer(),
              let tree = container.tree else { return }

        let sessionName = tree.nextSessionName()
        let station = Station()
        station.sessionName = sessionName
        station.backend = runtimeBackend
        StationRegistry.shared.register(station)

        registerSplitStation(station, worktreePath: tree.worktreePath, sessionName: sessionName)

        let leafId = UUID().uuidString
        tree.splitFocusedLeaf(axis: axis, newLeafId: leafId, newStationId: station.id, newSessionName: sessionName)

        performStructuralSplitLayout(
            container: container,
            tree: tree,
            newStation: station,
            newLeafId: leafId,
            focusNew: true
        )

        delegate?.terminalCoordinatorDidUpdateSurfaces(self)
        saveSplitLayout(tree)
    }

    /// Split a specific pane (by station id, or the focused one when nil) in the
    /// active container. Returns the new pane's station id, or nil if the target
    /// isn't in the active container. When `focus` is false the previously focused
    /// pane keeps focus (the control API's `--no-focus`, for agents spawning a
    /// sibling without stealing their own cursor). Must be called on the main thread.
    /// Announce the tree's current `focusedId` to the container delegate.
    ///
    /// Split/close/focus mutate `focusedId` directly instead of going through
    /// `GhosttyNSView.becomeFirstResponder`, so `onFocusAcquired` may not fire
    /// (notably when the view is already first responder) and title-following
    /// UI would keep showing the previous pane. Re-announcing is idempotent.
    private func announceFocusChange(_ container: SplitContainerView) {
        guard let tree = container.tree, !tree.focusedId.isEmpty else { return }
        container.delegate?.splitContainer(container, didChangeFocus: tree.focusedId)
    }

    @discardableResult
    func splitPane(targetStationId: String?, axis: SplitAxis, focus: Bool, ratio: CGFloat? = nil) -> String? {
        guard let container = activeSplitContainer(),
              let tree = container.tree else { return nil }

        // Resolve the leaf to split. A caller-supplied station id must live in the
        // active container; otherwise we can't split it here.
        let previousFocus = tree.focusedId
        let targetLeafId: String
        if let sid = targetStationId {
            guard let leaf = tree.allLeaves.first(where: { $0.stationId == sid }) else { return nil }
            targetLeafId = leaf.id
        } else {
            targetLeafId = tree.focusedId
        }

        let sessionName = tree.nextSessionName()
        let station = Station()
        station.sessionName = sessionName
        station.backend = runtimeBackend
        StationRegistry.shared.register(station)
        registerSplitStation(station, worktreePath: tree.worktreePath, sessionName: sessionName)

        let leafId = UUID().uuidString
        // splitFocusedLeaf splits `focusedId`, so point it at the target first.
        tree.focusedId = targetLeafId
        let split = tree.splitFocusedLeaf(axis: axis, newLeafId: leafId, newStationId: station.id, newSessionName: sessionName)
        // Restore an exact divider ratio (e.g. from a layout template) instead of
        // the 0.5 default. layoutTree below reads it.
        if let ratio { tree.updateRatio(splitId: split.splitId, newRatio: ratio) }

        if !focus { tree.focusedId = previousFocus }
        performStructuralSplitLayout(
            container: container,
            tree: tree,
            newStation: station,
            newLeafId: leafId,
            focusNew: focus,
            restoreFocusLeafId: focus ? nil : previousFocus
        )

        delegate?.terminalCoordinatorDidUpdateSurfaces(self)
        saveSplitLayout(tree)
        announceFocusChange(container)
        return station.id
    }

    /// Create the new leaf and relayout without mid-create SIGWINCH storms on
    /// the existing pane (Auto Layout fill + partial `layoutTree` used to shrink
    /// the old surface before final frames existed — starship reprints a blank
    /// prompt line per SIGWINCH).
    private func performStructuralSplitLayout(
        container: SplitContainerView,
        tree: SplitTree,
        newStation: Station,
        newLeafId: String,
        focusNew: Bool,
        restoreFocusLeafId: String? = nil
    ) {
        let frames = SplitContainerView.computeFrames(node: tree.root, in: container.bounds)
        let newFrame = frames[newLeafId] ?? container.bounds

        // Existing panes must NOT receive TIOCSWINSZ during the split.
        // Even a single SIGWINCH makes starship/zsh reprint a blank prompt line.
        // Absorb the AppKit frame now; flush the real grid on the next keypress.
        GhosttyBridge.shared.beginLiveResize(pinHeight: false)
        container.suppressStructuralLayout = true
        // Freeze existing panes *before* create/layout so any incidental
        // setFrame / viewDidMoveToWindow during addSubview cannot SIGWINCH.
        let newId = newStation.id
        for leaf in tree.allLeaves where leaf.stationId != newId {
            StationRegistry.shared.station(forId: leaf.stationId)?
                .view?.absorbBoundsWithoutPtyResize()
        }
        _ = newStation.create(
            in: container,
            workingDirectory: tree.worktreePath,
            sessionName: newStation.sessionName,
            initialFrame: newFrame
        )
        container.surfaceViews[newStation.id] = newStation.view
        container.suppressStructuralLayout = false
        container.layoutTree()

        for leaf in tree.allLeaves where leaf.stationId != newId {
            StationRegistry.shared.station(forId: leaf.stationId)?
                .view?.absorbBoundsWithoutPtyResize()
        }
        GhosttyBridge.shared.endLiveResize()

        let focusLeafId = focusNew ? newLeafId : (restoreFocusLeafId ?? tree.focusedId)
        DispatchQueue.main.async { [weak container] in
            guard let container,
                  let tree = container.tree,
                  let leaf = tree.allLeaves.first(where: { $0.id == focusLeafId }),
                  let station = StationRegistry.shared.station(forId: leaf.stationId),
                  let termView = station.view else { return }
            // Focusing the *new* pane must not flush a pending sync on the old
            // one — only becomeFirstResponder on the absorbed view does that.
            container.window?.makeFirstResponder(termView)
        }
    }

    /// tmux-style zoom of a pane in the active container. `mode`: on|off|toggle.
    /// Returns whether the container is zoomed afterward, or nil if the pane
    /// isn't in the active container. Must be called on the main thread.
    func zoomPane(targetStationId: String?, mode: String) -> Bool? {
        guard let container = activeSplitContainer(), let tree = container.tree else { return nil }
        let leafId: String
        if let sid = targetStationId {
            guard let leaf = tree.allLeaves.first(where: { $0.stationId == sid }) else { return nil }
            leafId = leaf.id
        } else {
            leafId = tree.focusedId
        }
        let on: Bool? = mode == "on" ? true : (mode == "off" ? false : nil)
        return container.setZoom(leafId: leafId, on: on)
    }

    // MARK: - Layout export / apply (declarative templates)

    /// Serialize the active container's split tree as a portable LayoutNode.
    /// Must be called on the main thread.
    func exportLayout() -> [String: Any]? {
        guard let container = activeSplitContainer(), let tree = container.tree else { return nil }
        return ["root": Self.nodeToLayout(tree.root).dict, "worktree_path": tree.worktreePath]
    }

    private static func nodeToLayout(_ node: SplitNode) -> LayoutNode {
        switch node {
        case let .leaf(_, stationId, sessionName):
            let agent = ShipLog.shared.sailor(for: stationId)?.agentType
            let named = (agent != nil && agent != .unknown) ? agent!.rawValue : nil
            return .pane(label: sessionName, command: agent?.launchCommand, agent: named, cwd: nil)
        case let .split(_, axis, ratio, first, second):
            return .split(direction: axis == .vertical ? "down" : "right",
                          ratio: Double(ratio),
                          first: nodeToLayout(first), second: nodeToLayout(second))
        }
    }

    /// Rebuild structure by splitting out from the focused pane per `root`, then
    /// running each leaf's command. Ratios use the split default (exact ratios are
    /// not restored). Bounded pane count. Must be called on the main thread.
    @discardableResult
    func applyLayout(_ root: LayoutNode) -> Bool {
        guard root.paneCount <= 16 else { return false }
        guard let container = activeSplitContainer(), let tree = container.tree,
              let startStationId = tree.allLeaves.first(where: { $0.id == tree.focusedId })?.stationId
        else { return false }
        realize(root, intoStationId: startStationId)
        return true
    }

    private func realize(_ node: LayoutNode, intoStationId sid: String) {
        switch node {
        case let .pane(_, command, _, _):
            if let command, !command.isEmpty,
               let station = StationRegistry.shared.station(forId: sid) {
                station.sendText(command)
                station.sendEnterKey()
            }
        case let .split(direction, ratio, first, second):
            let axis: SplitAxis = (direction == "down" || direction == "up") ? .vertical : .horizontal
            guard let newId = splitPane(targetStationId: sid, axis: axis, focus: false,
                                        ratio: CGFloat(ratio)) else { return }
            realize(first, intoStationId: sid)
            realize(second, intoStationId: newId)
        }
    }

    func closeFocusedPane() {
        guard let container = activeSplitContainer(),
              let tree = container.tree else { return }

        guard let closed = tree.closeFocusedLeaf() else { return }

        // Kill zmx session
        SessionManager.killSession(closed.sessionName, backend: runtimeBackend)
        config.agentSessions.removeValue(forKey: closed.sessionName)

        // Remove station
        if let station = StationRegistry.shared.station(forId: closed.stationId) {
            station.view?.removeFromSuperview()
            station.destroy()
        }
        StationRegistry.shared.unregister(closed.stationId)
        ShipLog.shared.unregister(terminalID: closed.stationId)
        container.surfaceViews.removeValue(forKey: closed.stationId)

        // Same SIGWINCH tolerance as structural split: grow the remaining pane's
        // AppKit frame without TIOCSWINSZ until the user types in it.
        GhosttyBridge.shared.beginLiveResize(pinHeight: false)
        container.layoutTree()
        for leaf in tree.allLeaves {
            StationRegistry.shared.station(forId: leaf.stationId)?
                .view?.absorbBoundsWithoutPtyResize()
        }
        GhosttyBridge.shared.endLiveResize()

        // Focus new leaf — do NOT syncSize(); that clears the freeze and reprints prompts.
        if let focusedLeaf = tree.allLeaves.first(where: { $0.id == tree.focusedId }),
           let focusStation = StationRegistry.shared.station(forId: focusedLeaf.stationId),
           let terminalView = focusStation.view {
            DispatchQueue.main.async {
                container.window?.makeFirstResponder(terminalView)
            }
        }

        delegate?.terminalCoordinatorDidUpdateSurfaces(self)
        saveSplitLayout(tree)
        announceFocusChange(container)
    }

    /// Close a specific pane (by station id) in the active container. Returns
    /// false if the pane isn't there. Reuses the focused-close teardown path
    /// (kills the zmx session, destroys the station, re-lays out). Main thread.
    @discardableResult
    func closePane(targetStationId: String) -> Bool {
        guard let container = activeSplitContainer(), let tree = container.tree,
              let leaf = tree.allLeaves.first(where: { $0.stationId == targetStationId }) else { return false }
        tree.focusedId = leaf.id
        closeFocusedPane()
        return true
    }

    /// Focus a specific pane (by station id) in the active container. Main thread.
    @discardableResult
    func focusPane(targetStationId: String) -> Bool {
        guard let container = activeSplitContainer(), let tree = container.tree,
              let leaf = tree.allLeaves.first(where: { $0.stationId == targetStationId }),
              let station = StationRegistry.shared.station(forId: leaf.stationId),
              let view = station.view else { return false }
        tree.focusedId = leaf.id
        container.window?.makeFirstResponder(view)
        container.layoutTree()
        announceFocusChange(container)
        return true
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
        guard let window else { return }

        // Both are synchronous git subprocesses (up to a 5s timeout on a wedged
        // repo) — run them off the main thread, then present the alert.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hasChanges = WorktreeDeleter.hasUncommittedChanges(worktreePath: info.path)
            let repoPath = WorktreeDiscovery.findRepoRoot(from: info.path) ?? info.path
            DispatchQueue.main.async {
                self?.presentDeleteConfirmation(info, window: window,
                                                hasChanges: hasChanges, repoPath: repoPath)
            }
        }
    }

    private func presentDeleteConfirmation(_ info: WorktreeInfo, window: NSWindow,
                                           hasChanges: Bool, repoPath: String) {
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
        // Tear the sessions down BEFORE the tree (and its session names) are gone —
        // afterwards there is nothing left to name them by.
        //
        // Killing them is not optional. `SessionManager.expectedSessionNames` counts
        // every session named in `config.splitLayouts` as live, so a layout left
        // behind here makes the orphan reaper skip these sessions forever, and
        // `resolveTree` can restore that same layout and resurrect the deleted
        // worktree's card. Deleting the directory is not enough; the worktree's
        // state has to go with it. (`performCloseRepo` already does this.)
        if let tree = stationManager.tree(forPath: info.path) {
            for leaf in tree.allLeaves {
                config.agentSessions.removeValue(forKey: leaf.sessionName)
                if runtimeBackend != "local" {
                    SessionManager.killSession(leaf.sessionName, backend: runtimeBackend)
                }
            }
        }
        config.splitLayouts.removeValue(forKey: info.path)
        config.focusedPaneIds.removeValue(forKey: info.path)
        config.save()
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
