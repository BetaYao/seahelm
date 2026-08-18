import AppKit

protocol TerminalCoordinatorDelegate: AnyObject {
    func terminalCoordinatorDidUpdateSurfaces(_ coordinator: TerminalCoordinator)
    func terminalCoordinator(_ coordinator: TerminalCoordinator, didDeleteWorktree info: WorktreeInfo)
    /// A pane and its session are gone. Anything keyed by its terminal id — most
    /// visibly a pending suggestion card — has to go with it.
    func terminalCoordinator(_ coordinator: TerminalCoordinator, didClosePane terminalID: String)
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
                if let ref = config.agentSessions[leaf.paneSessionKey] {
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

    /// Re-serialize every live tree so the latest per-pane titles (written into
    /// each Station during status polling) are captured. Layouts are otherwise
    /// only saved on structural changes, so a title that resolved after the last
    /// split/close would be lost on relaunch.
    func saveAllSplitLayouts() {
        let trees = stationManager.allTrees
        guard !trees.isEmpty else { return }
        for tree in trees {
            config.splitLayouts[tree.worktreePath] = tree.toCodable()
        }
        config.save()
    }

    // MARK: - Split Pane Operations

    /// Enrol a freshly split pane in AgentRegistry. StationRegistry alone is not enough:
    /// `AgentRegistry.handleWebhookEvent` resolves a hook's SEAHELM_PANE_ID to a station
    /// and then requires that station to be a known agent, so a pane missing here
    /// silently falls back to the worktree's *first* pane — every hook, and every
    /// suggestion chip tapped for this pane, lands in a sibling.
    /// Branch/project come from a sibling in the same worktree, which shares both.
    private func registerSplitStation(_ station: Station, worktreePath: String, paneSessionKey: String) {
        let sibling = AgentRegistry.shared.pane(forWorktree: worktreePath)
        AgentRegistry.shared.register(
            station: station,
            worktreePath: worktreePath,
            branch: sibling?.branch ?? "",
            project: sibling?.project ?? URL(fileURLWithPath: worktreePath).lastPathComponent,
            startedAt: Date(),
            paneSessionKey: runtimeBackend == "local" ? nil : paneSessionKey,
            backend: runtimeBackend
        )
    }

    func splitFocusedPane(axis: SplitAxis) {
        guard let container = activeSplitContainer(),
              let tree = container.tree else { return }

        let paneSessionKey = tree.nextSessionName()
        let station = Station()
        station.paneSessionKey = paneSessionKey
        station.backend = runtimeBackend
        StationRegistry.shared.register(station)

        registerSplitStation(station, worktreePath: tree.worktreePath, paneSessionKey: paneSessionKey)

        let leafId = UUID().uuidString
        tree.splitFocusedLeaf(axis: axis, newLeafId: leafId, newStationId: station.id, newSessionName: paneSessionKey)

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
    func splitPane(targetStationId: String?, axis: SplitAxis, focus: Bool, ratio: CGFloat? = nil,
                   paneSessionKeyOverride: String? = nil) -> String? {
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

        let paneSessionKey = paneSessionKeyOverride ?? tree.nextSessionName()
        let station = Station()
        station.paneSessionKey = paneSessionKey
        station.backend = runtimeBackend
        StationRegistry.shared.register(station)
        registerSplitStation(station, worktreePath: tree.worktreePath, paneSessionKey: paneSessionKey)

        let leafId = UUID().uuidString
        // splitFocusedLeaf splits `focusedId`, so point it at the target first.
        tree.focusedId = targetLeafId
        let split = tree.splitFocusedLeaf(axis: axis, newLeafId: leafId, newStationId: station.id, newSessionName: paneSessionKey)
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

    /// Whether an existing pane should adopt the new frame *without* a PTY
    /// resize when the layout changes structurally (split / close).
    ///
    /// Plain shells do: starship / oh-my-zsh reprint a blank prompt line per
    /// SIGWINCH, so we defer the grid sync to the next keypress. Agent TUIs
    /// (Claude Code, Codex, …) redraw their whole frame *from* SIGWINCH — defer
    /// it and the pane keeps painting at the old width until the user focuses
    /// it and hits Enter. They take the resize immediately.
    private static func defersPtyResize(_ stationId: String) -> Bool {
        !(AgentRegistry.shared.pane(for: stationId)?.agentType.isAIAgent ?? false)
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
        for leaf in tree.allLeaves
        where leaf.stationId != newId && Self.defersPtyResize(leaf.stationId) {
            StationRegistry.shared.station(forId: leaf.stationId)?
                .view?.absorbBoundsWithoutPtyResize()
        }
        _ = newStation.create(
            in: container,
            workingDirectory: tree.worktreePath,
            paneSessionKey: newStation.paneSessionKey,
            initialFrame: newFrame
        )
        container.surfaceViews[newStation.id] = newStation.view
        container.suppressStructuralLayout = false
        container.layoutTree()

        for leaf in tree.allLeaves
        where leaf.stationId != newId && Self.defersPtyResize(leaf.stationId) {
            StationRegistry.shared.station(forId: leaf.stationId)?
                .view?.absorbBoundsWithoutPtyResize()
        }
        // Agent panes were left unfrozen, so this flush delivers their SIGWINCH.
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
        case let .leaf(_, stationId, paneSessionKey):
            let agent = AgentRegistry.shared.pane(for: stationId)?.agentType
            let named = (agent != nil && agent != .unknown) ? agent!.rawValue : nil
            return .pane(label: paneSessionKey, command: agent?.launchCommand, agent: named, cwd: nil)
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
        SessionManager.killSession(closed.paneSessionKey, backend: runtimeBackend)
        config.agentSessions.removeValue(forKey: closed.paneSessionKey)

        // Remove station
        if let station = StationRegistry.shared.station(forId: closed.stationId) {
            station.view?.removeFromSuperview()
            station.destroy()
        }
        StationRegistry.shared.unregister(closed.stationId)
        AgentRegistry.shared.unregister(terminalID: closed.stationId)
        delegate?.terminalCoordinator(self, didClosePane: closed.stationId)
        container.surfaceViews.removeValue(forKey: closed.stationId)

        // Same SIGWINCH tolerance as structural split: grow the remaining pane's
        // AppKit frame without TIOCSWINSZ until the user types in it.
        GhosttyBridge.shared.beginLiveResize(pinHeight: false)
        container.layoutTree()
        for leaf in tree.allLeaves where Self.defersPtyResize(leaf.stationId) {
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

    // MARK: - Sleep / Wake

    /// Sleep a pane by station id — frees its ghostty surface while the zmx
    /// session keeps running. Unlike close/focus this is not limited to the
    /// active container: the panes worth sleeping are the ones off screen.
    /// Main thread. Returns the ids actually slept ([] = nothing eligible).
    @discardableResult
    func sleepPane(targetStationId: String?) -> [String] {
        stations(matching: targetStationId).compactMap { $0.sleep() ? $0.id : nil }
    }

    // MARK: - Auto sleep

    /// When each off-screen pane was first seen off screen. Only panes absent
    /// from the displayed tree get an entry; coming back on screen clears it, so
    /// the timer measures one continuous absence rather than accumulated time.
    private var offscreenSince: [String: Date] = [:]

    /// Which panes have been off screen long enough to sleep, and the updated
    /// clock. Pure so the policy is testable without stations, a window, or a
    /// real clock — the part that can silently sleep a pane the user is looking
    /// at is exactly the part worth pinning down in tests.
    static func autoSleepPlan(
        visible: Set<String>,
        sleepable: [String],
        offscreenSince: [String: Date],
        idleAfter: TimeInterval,
        now: Date
    ) -> (sleep: [String], offscreenSince: [String: Date]) {
        var since = offscreenSince
        for id in visible { since.removeValue(forKey: id) }

        var due: [(id: String, firstSeen: Date)] = []
        for id in sleepable where !visible.contains(id) {
            guard let firstSeen = since[id] else {
                since[id] = now
                continue
            }
            if now.timeIntervalSince(firstSeen) >= idleAfter {
                due.append((id, firstSeen))
            }
        }

        // One per tick. `Station.sleep()` frees a Metal surface on the main
        // thread, and sleeping a batch in a single pass produced 13-20s of main
        // thread stall — the app looks dead. The threshold is minutes, so a
        // backlog drains a pane every tick with nobody waiting on it. Oldest
        // first, so the queue is deterministic rather than dictionary order.
        guard let chosen = due.min(by: { $0.firstSeen < $1.firstSeen })?.id else {
            let known = visible.union(sleepable)
            return ([], since.filter { known.contains($0.key) })
        }
        // Only the chosen pane's clock is cleared; the rest stay due and are
        // picked up on following ticks.
        since.removeValue(forKey: chosen)
        // Closed panes would otherwise keep their entry forever.
        let known = visible.union(sleepable)
        return ([chosen], since.filter { known.contains($0.key) })
    }

    /// Sleep panes that have stayed off screen past `idleAfter`. Main thread.
    /// Returns the ids actually slept. Nothing wakes automatically: a slept pane
    /// renders as a placeholder with a Wake button, which is the existing
    /// contract for panes whose surface is gone.
    @discardableResult
    func sleepIdleOffscreenPanes(idleAfter: TimeInterval, now: Date = Date()) -> [String] {
        let visible = Set(activeSplitContainer()?.tree?.allLeaves.map(\.stationId) ?? [])
        let sleepable = StationRegistry.shared.allStations().filter(\.canSleep).map(\.id)
        let plan = Self.autoSleepPlan(visible: visible,
                                      sleepable: sleepable,
                                      offscreenSince: offscreenSince,
                                      idleAfter: idleAfter,
                                      now: now)
        offscreenSince = plan.offscreenSince
        return plan.sleep.filter { StationRegistry.shared.station(forId: $0)?.sleep() == true }
    }

    /// Wake a slept pane by station id (nil = every slept pane). Main thread.
    @discardableResult
    func wakePane(targetStationId: String?) -> [String] {
        stations(matching: targetStationId).compactMap { $0.wake() ? $0.id : nil }
    }

    /// The stations a sleep/wake request applies to: one named pane, or every
    /// pane except the focused one (which must stay live — sleeping the pane the
    /// user is typing into would yank the surface out from under first responder).
    private func stations(matching targetStationId: String?) -> [Station] {
        if let targetStationId {
            return StationRegistry.shared.station(forId: targetStationId).map { [$0] } ?? []
        }
        var focused: String?
        if let container = activeSplitContainer(), let tree = container.tree,
           let leaf = tree.allLeaves.first(where: { $0.id == tree.focusedId }) {
            focused = leaf.stationId
        }
        return StationRegistry.shared.allStations().filter { $0.id != focused }
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

    func confirmAndDeleteWorktree(_ info: WorktreeInfo, window: NSWindow?, preferredDeleteBranch: Bool? = nil) {
        guard !info.isMainWorktree else { return }
        guard let window else { return }

        // Both are synchronous git subprocesses (up to a 5s timeout on a wedged
        // repo) — run them off the main thread, then present the alert.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hasChanges = WorktreeDeleter.hasUncommittedChanges(worktreePath: info.path)
            let repoPath = WorktreeDiscovery.findRepoRoot(from: info.path) ?? info.path
            DispatchQueue.main.async {
                self?.presentDeleteConfirmation(info, window: window,
                                                hasChanges: hasChanges,
                                                repoPath: repoPath,
                                                preferredDeleteBranch: preferredDeleteBranch)
            }
        }
    }

    private func presentDeleteConfirmation(_ info: WorktreeInfo, window: NSWindow,
                                           hasChanges: Bool, repoPath: String,
                                           preferredDeleteBranch: Bool?) {
        let alert = NSAlert()
        alert.alertStyle = hasChanges ? .critical : .warning
        alert.messageText = "Delete worktree \"\(info.branch)\"?"
        let deleteBranch = preferredDeleteBranch ?? false
        if hasChanges {
            if deleteBranch {
                alert.informativeText = "This worktree has uncommitted changes that will be lost. Seahelm will also try to delete the local branch."
            } else {
                alert.informativeText = "This worktree has uncommitted changes that will be lost."
            }
        } else {
            if deleteBranch {
                alert.informativeText = "The worktree directory will be removed, then Seahelm will try to delete the local branch."
            } else {
                alert.informativeText = "The worktree directory will be removed."
            }
        }
        if let preferredDeleteBranch {
            alert.addButton(withTitle: preferredDeleteBranch ? "Delete + Branch" : "Delete")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Delete + Branch")
            alert.addButton(withTitle: "Cancel")
        }

        alert.buttons[0].hasDestructiveAction = true
        if preferredDeleteBranch == nil {
            alert.buttons[1].hasDestructiveAction = true
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if let preferredDeleteBranch {
                if response == .alertFirstButtonReturn {
                    self.performDeleteWorktree(info, repoPath: repoPath, deleteBranch: preferredDeleteBranch, force: hasChanges)
                }
                return
            }
            if response == .alertFirstButtonReturn {
                self.performDeleteWorktree(info, repoPath: repoPath, deleteBranch: false, force: hasChanges)
            } else if response == .alertSecondButtonReturn {
                self.performDeleteWorktree(info, repoPath: repoPath, deleteBranch: true, force: hasChanges)
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try WorktreeDeleter.deleteWorktree(
                    worktreePath: info.path,
                    repoPath: repoPath,
                    branchName: info.branch,
                    deleteBranch: deleteBranch,
                    force: force
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finalizeDeletedWorktree(info)
                    if let warning = result.branchWarning {
                        self.presentDeleteWarning(title: "Worktree deleted, branch kept", message: warning)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.presentDeleteError(error)
                }
            }
        }
    }

    private func finalizeDeletedWorktree(_ info: WorktreeInfo) {
        // Tear sessions down only after git deletion succeeded.
        if let tree = stationManager.tree(forPath: info.path) {
            for leaf in tree.allLeaves {
                config.agentSessions.removeValue(forKey: leaf.paneSessionKey)
                if runtimeBackend != "local" {
                    SessionManager.killSession(leaf.paneSessionKey, backend: runtimeBackend)
                }
            }
        }
        config.splitLayouts.removeValue(forKey: info.path)
        config.focusedPaneIds.removeValue(forKey: info.path)
        config.save()
        stationManager.removeTree(forPath: info.path)
        delegate?.terminalCoordinator(self, didDeleteWorktree: info)
    }

    private func presentDeleteError(_ error: Error) {
        let errAlert = NSAlert()
        errAlert.alertStyle = .critical
        errAlert.messageText = "Failed to delete worktree"
        errAlert.informativeText = error.localizedDescription
        errAlert.runModal()
    }

    private func presentDeleteWarning(title: String, message: String) {
        let warn = NSAlert()
        warn.alertStyle = .warning
        warn.messageText = title
        warn.informativeText = message
        warn.runModal()
    }

    // MARK: - Cleanup

    func cleanup() {
        controlSocketServer?.stop()
        controlSocketServer = nil
        stationManager.removeAll()
    }
}

// MARK: - Remote layout mirroring

extension TerminalCoordinator {
    /// Every live split tree, keyed by worktree path.
    ///
    /// A remote client needs this to mirror the window rather than invent its own
    /// arrangement: the tree is the layout, and its leaves are already keyed by
    /// the `paneSessionKey` that `pane.vt_open` attaches to.
    func liveLayouts() -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for tree in stationManager.allTrees {
            var entry: [String: Any] = ["root": tree.toCodable().dict]
            if let focused = tree.allLeaves.first(where: { $0.id == tree.focusedId }) {
                entry["focused_pane_session_key"] = focused.paneSessionKey
            }
            out[tree.worktreePath] = entry
        }
        return out
    }
}
