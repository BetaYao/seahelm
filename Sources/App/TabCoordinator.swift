import AppKit

protocol TabCoordinatorDelegate: AnyObject {
    func tabCoordinator(_ coordinator: TabCoordinator, embedViewController vc: NSViewController)
    func tabCoordinatorDidSwitchTab(_ coordinator: TabCoordinator)
    func tabCoordinatorRequestUpdateTitleBar(_ coordinator: TabCoordinator)
    func tabCoordinatorRequestShowNewBranchDialog(_ coordinator: TabCoordinator)
    func tabCoordinatorRequestClearContentContainer(_ coordinator: TabCoordinator)
}

class TabCoordinator {
    weak var delegate: TabCoordinatorDelegate?
    var config: Config
    let workspaceManager = WorkspaceManager()

    var activeTabIndex: Int = 0
    var allWorktrees: [(info: WorktreeInfo, tree: SplitTree)] = []
    var worktreeRepoCache: [String: String] = [:]

    /// Display name of the repo owning a given worktree path.
    func repoName(forWorktree path: String) -> String {
        let repoPath = worktreeRepoCache[path] ?? path
        return workspaceManager.tabs.first(where: { $0.repoPath == repoPath })?.displayName
            ?? URL(fileURLWithPath: repoPath).lastPathComponent
    }
    var branchRefreshTimer: Timer?
    weak var dashboardVC: DashboardViewController?

    // References provided by MainWindowController
    var terminalCoordinator: TerminalCoordinator!
    var statusPublisher: StatusPublisher!
    var statusAggregator: WorktreeStatusAggregator!
    var runtimeBackend: String = "local"
    private let pendingTransfers = PendingTransferTracker()

    // First Mate — status-transition engine + red-zone queue + green-zone watch
    let pendingOrders = PendingOrdersQueue()
    let watchFeed = WatchFeed()
    let suggestionFeed = SuggestionFeed()
    private(set) var firstMate: FirstMateCoordinator!

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    var selectedAgent: AgentDisplayInfo? {
        guard let dashboard = dashboardVC else { return nil }
        let index = dashboard.selectedAgentIndex
        let agents = dashboard.agents
        guard index < agents.count else { return nil }
        return agents[index]
    }

    /// Save config with split layouts synced from TerminalCoordinator.
    /// Config is a value type — each coordinator holds its own copy.
    /// Without syncing, saves from this coordinator would overwrite
    /// splitLayouts written by TerminalCoordinator with an empty dictionary.
    private func saveConfig() {
        if let tc = terminalCoordinator {
            config.splitLayouts = tc.config.splitLayouts
        }
        config.save()
    }

    init(config: Config) {
        self.config = config
        let fmConfig = config.firstMate
        let orders = pendingOrders
        let feed = watchFeed
        firstMate = FirstMateCoordinator(
            config: fmConfig,
            queue: orders,
            notify: { action in
                feed.record(action)
                let status: AgentStatus = action.kind == .watchError ? .error : .waiting
                NotificationManager.shared.notify(
                    worktreePath: action.worktreePath,
                    workspaceName: action.project,
                    branch: action.branch,
                    oldStatus: .running,
                    newStatus: status,
                    lastMessage: action.message
                )
            },
            runInspection: { [weak self] action in
                self?.runFirstMateInspection(action)
            },
            hasOrders: { worktreePath in
                WorktreeTaskStore.shared.task(forWorktree: worktreePath) != nil
            }
        )
        ShipLog.shared.onStatusTransition = { [weak self] t in
            self?.firstMate?.handle(t)
        }
        NotificationCenter.default.addObserver(forName: .repoViewDidChangeWorktree, object: nil, queue: .main) { [weak self] notification in
            guard let self,
                  let worktreePath = notification.userInfo?["worktreePath"] as? String,
                  let repoPath = self.worktreeRepoCache[worktreePath] else { return }
            self.config.activeWorktreePaths[repoPath] = worktreePath
            self.saveConfig()
        }
        NotificationCenter.default.addObserver(forName: .repoViewDidChangeFocusedPane, object: nil, queue: .main) { [weak self] notification in
            guard let self,
                  let worktreePath = notification.userInfo?["worktreePath"] as? String,
                  let leafId = notification.userInfo?["focusedLeafId"] as? String else { return }
            // Save session name (stable across launches) instead of leaf ID
            if let tree = self.terminalCoordinator.stationManager.tree(forPath: worktreePath),
               let leaf = tree.allLeaves.first(where: { $0.id == leafId }) {
                self.config.focusedPaneIds[worktreePath] = leaf.sessionName
            }
            self.saveConfig()
        }
    }

    deinit { ShipLog.shared.onStatusTransition = nil }

    // MARK: - Tab Switching

    func switchToTab(_ index: Int) {
        guard index != activeTabIndex else { return }

        dashboardVC?.detachTerminals()
        activeTabIndex = 0

        if let dashboard = dashboardVC {
            delegate?.tabCoordinator(self, embedViewController: dashboard)
            dashboard.updateAgents(buildAgentDisplayInfos())
        }

        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
        updateStatusPollPreferences()
        delegate?.tabCoordinatorDidSwitchTab(self)
        saveSessionState()
    }

    func updateStatusPollPreferences() {
        // Dashboard is always active (no separate repo tabs), so no preferred filtering.
        statusPublisher.setPreferredPaths([])
    }

    func openRepoTab(repoPath: String, completion: (() -> Void)? = nil) {
        WorktreeDiscovery.discoverAsync(repoPath: repoPath) { [weak self] worktrees in
            guard let self else { return }
            _ = self.integrateDiscoveredRepo(repoPath: repoPath, worktrees: worktrees)
            completion?()
        }
    }

    // MARK: - Add Repo

    func addRepoViaOpenPanel(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a git repository to add"
        panel.prompt = "Add Repo"

        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.addRepo(at: url.path)
        }
    }

    func addRepo(at path: String) {
        WorktreeDiscovery.discoverAsync(repoPath: path) { [weak self] worktrees in
            guard let self else { return }
            // Resolve to main worktree path so the display name reflects the repo root directory
            let repoPath = worktrees.first(where: { $0.isMainWorktree })?.path ?? path

            guard !self.config.workspacePaths.contains(repoPath) else {
                return
            }

            self.config.workspacePaths.append(repoPath)
            self.saveConfig()

            _ = self.integrateDiscoveredRepo(repoPath: repoPath, worktrees: worktrees)
        }
    }

    // MARK: - Worktree Integration

    @discardableResult
    func integrateDiscoveredRepo(repoPath: String, worktrees: [WorktreeInfo], activateTab: Bool = true) -> Int {
        let effectiveWorktrees: [WorktreeInfo]
        if worktrees.isEmpty {
            effectiveWorktrees = [WorktreeInfo(path: repoPath, branch: "main", commitHash: "", isMainWorktree: true)]
        } else {
            effectiveWorktrees = worktrees
        }

        let tabIndex = workspaceManager.addTab(repoPath: repoPath, worktrees: effectiveWorktrees)

        for info in effectiveWorktrees {
            let tree = terminalCoordinator.resolveTree(for: info)
            allWorktrees.append((info: info, tree: tree))
            worktreeRepoCache[info.path] = repoPath

            let proj = workspaceManager.tabs.first(where: { $0.repoPath == repoPath })?.displayName
                ?? URL(fileURLWithPath: repoPath).lastPathComponent
            let started = config.worktreeStartedAt[info.path].flatMap { Self.iso8601.date(from: $0) }
            let sessionName = runtimeBackend == "local" ? nil : SessionManager.persistentSessionName(for: info.path)
            if let surface = terminalCoordinator.stationManager.primaryStation(forPath: info.path) {
                ShipLog.shared.register(station: surface, worktreePath: info.path, branch: info.branch, project: proj, startedAt: started, tmuxSessionName: sessionName, backend: runtimeBackend)
            }
        }

        // Record startedAt for newly discovered worktrees
        let now = Self.iso8601.string(from: Date())
        var configChanged = false
        for info in effectiveWorktrees {
            if config.worktreeStartedAt[info.path] == nil {
                config.worktreeStartedAt[info.path] = now
                configChanged = true
            }
        }
        if configChanged { saveConfig() }

        dashboardVC?.updateAgents(buildAgentDisplayInfos())
        statusPublisher.updateSurfaces(terminalCoordinator.stationManager.all)
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)

        return tabIndex
    }

    // MARK: - Build Agent Display Infos

    func buildAgentDisplayInfos() -> [AgentDisplayInfo] {
        let agents = ShipLog.shared.allAgents()
        var seen = Set<String>()
        var result: [AgentDisplayInfo] = []

        for agent in agents {
            guard let station = agent.station else { continue }
            guard !seen.contains(agent.worktreePath) else { continue }
            seen.insert(agent.worktreePath)

            let tree = terminalCoordinator.stationManager.tree(forPath: agent.worktreePath)
            let paneCount = tree?.leafCount ?? 1
            let paneStations: [Station] = tree?.allLeaves.compactMap {
                StationRegistry.shared.station(forId: $0.stationId)
            } ?? [station]

            let ws = statusAggregator.status(for: agent.worktreePath)
            let paneStatuses = ws?.statuses ?? [agent.status]
            let mostRecentMessage = ws?.mostRecentMessage ?? (agent.lastMessage.isEmpty ? "No active task." : agent.lastMessage)
            let mostRecentUserPrompt = ws?.mostRecentUserPrompt ?? agent.lastUserPrompt
            let mostRecentPaneIndex = ws?.mostRecentPaneIndex ?? 1

            let matchedWorktree = allWorktrees.first(where: { $0.info.path == agent.worktreePath })
            let isMain = matchedWorktree?.info.isMainWorktree ?? false
            let freshBranch = matchedWorktree?.info.branch ?? agent.branch

            result.append(AgentDisplayInfo(
                id: agent.id,
                name: freshBranch,
                project: agent.project,
                thread: freshBranch,
                paneStatuses: paneStatuses,
                mostRecentMessage: mostRecentMessage,
                lastUserPrompt: mostRecentUserPrompt,
                mostRecentPaneIndex: mostRecentPaneIndex,
                totalDuration: AgentDisplayHelpers.formatDuration(agent.totalDuration),
                roundDuration: AgentDisplayHelpers.formatDuration(agent.roundDuration),
                station: station,
                worktreePath: agent.worktreePath,
                paneCount: paneCount,
                paneStations: paneStations,
                isMainWorktree: isMain,
                tasks: agent.tasks,
                activityEvents: agent.activityEvents
            ))
        }

        // Respect user-defined card order from config.
        let cardOrder = config.cardOrder
        if !cardOrder.isEmpty {
            let orderIndex: [String: Int] = Dictionary(uniqueKeysWithValues:
                cardOrder.enumerated().map { ($1, $0) }
            )
            result.sort { a, b in
                let ia = orderIndex[a.worktreePath] ?? Int.max
                let ib = orderIndex[b.worktreePath] ?? Int.max
                return ia < ib
            }
        }

        return result
    }

    // MARK: - Workspace Loading

    func loadWorkspaces() {
        let repoPaths = config.workspacePaths
        let cardOrder = config.cardOrder

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var discoveredWorktrees: [(repoPath: String, worktrees: [WorktreeInfo])] = []
            var resolvedPaths: [String] = []
            for repoPath in repoPaths {
                let worktrees = WorktreeDiscovery.discover(repoPath: repoPath)
                // Resolve to main worktree path so display name reflects the repo root
                let resolved = worktrees.first(where: { $0.isMainWorktree })?.path ?? repoPath
                discoveredWorktrees.append((resolved, worktrees))
                resolvedPaths.append(resolved)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // Update config if any paths were resolved to their main worktree
                if resolvedPaths != repoPaths {
                    self.config.workspacePaths = resolvedPaths
                    self.saveConfig()
                }

                var allWorktreeInfos: [(info: WorktreeInfo, tree: SplitTree)] = []

                for (repoPath, worktrees) in discoveredWorktrees {
                    if worktrees.isEmpty {
                        let info = WorktreeInfo(
                            path: repoPath,
                            branch: "main",
                            commitHash: "",
                            isMainWorktree: true
                        )
                        let tree = self.terminalCoordinator.resolveTree(for: info)
                        allWorktreeInfos.append((info: info, tree: tree))
                        self.worktreeRepoCache[info.path] = repoPath
                    } else {
                        for info in worktrees {
                            let tree = self.terminalCoordinator.resolveTree(for: info)
                            allWorktreeInfos.append((info: info, tree: tree))
                            self.worktreeRepoCache[info.path] = repoPath
                        }
                    }

                    _ = self.workspaceManager.addTab(repoPath: repoPath, worktrees: worktrees)
                }

                // Record startedAt for newly discovered worktrees
                let now = Self.iso8601.string(from: Date())
                var configChanged = false
                for (info, _) in allWorktreeInfos {
                    if self.config.worktreeStartedAt[info.path] == nil {
                        self.config.worktreeStartedAt[info.path] = now
                        configChanged = true
                    }
                }
                if configChanged { self.saveConfig() }

                // Apply saved card order
                if !cardOrder.isEmpty {
                    allWorktreeInfos.sort { a, b in
                        let ai = cardOrder.firstIndex(of: a.info.path) ?? Int.max
                        let bi = cardOrder.firstIndex(of: b.info.path) ?? Int.max
                        return ai < bi
                    }
                }

                self.allWorktrees = allWorktreeInfos

                // Register all agents with ShipLog
                for (info, _) in allWorktreeInfos {
                    let repo = self.worktreeRepoCache[info.path] ?? WorktreeDiscovery.findRepoRoot(from: info.path) ?? info.path
                    let proj = self.workspaceManager.tabs.first(where: { $0.repoPath == repo })?.displayName
                        ?? URL(fileURLWithPath: repo).lastPathComponent
                    let started = self.config.worktreeStartedAt[info.path].flatMap { Self.iso8601.date(from: $0) }
                    let sessionName = self.runtimeBackend == "local" ? nil : SessionManager.persistentSessionName(for: info.path)
                    if let surface = self.terminalCoordinator.stationManager.primaryStation(forPath: info.path) {
                        ShipLog.shared.register(station: surface, worktreePath: info.path, branch: info.branch, project: proj, startedAt: started, tmuxSessionName: sessionName, backend: self.runtimeBackend)
                    }
                }
                if !cardOrder.isEmpty {
                    ShipLog.shared.reorder(paths: cardOrder)
                }

                self.dashboardVC?.updateAgents(self.buildAgentDisplayInfos())
                self.delegate?.tabCoordinatorRequestUpdateTitleBar(self)

                if allWorktreeInfos.isEmpty {
                    NSLog("No workspaces configured. Add paths to ~/.config/seahelm/config.json")
                }

                // Start polling for agent status
                self.statusPublisher.start(trees: self.terminalCoordinator.stationManager.all)
                self.updateStatusPollPreferences()

                // Restore last session state (tab, worktree, pane)
                self.restoreSessionState()

                // Start periodic branch name refresh
                self.startBranchRefreshTimer()

                // Start webhook server for agent hook events
                if self.config.webhook.enabled {
                    self.statusPublisher.webhookProvider.onNewWorktreeDetected = { [weak self] worktreePath in
                        self?.handleNewWorktreeFromHook(worktreePath)
                    }
                    self.statusPublisher.webhookProvider.onSuggestions = { [weak self] worktreePath, options in
                        guard let self else { return }
                        let canon = WorktreeDiscovery.canonicalPath(worktreePath)
                        let agent = ShipLog.shared.agent(forWorktree: worktreePath)
                            ?? ShipLog.shared.allAgents().first { WorktreeDiscovery.canonicalPath($0.worktreePath) == canon }
                        self.suggestionFeed.set(
                            worktreePath: worktreePath,
                            branch: agent?.branch ?? "",
                            terminalID: agent?.id ?? "",
                            options: options
                        )
                    }
                    self.statusPublisher.webhookProvider.onWorktreeCreateReceived = { [weak self] sourcePath, worktreeName, sessionId in
                        guard let self else { return }
                        NSLog("[TabCoordinator] WorktreeCreate: recording pending transfer from \(sourcePath) for \(worktreeName)")
                        self.pendingTransfers.record(sourceWorktreePath: sourcePath, worktreeName: worktreeName, sessionId: sessionId)
                    }
                    let server = WebhookServer(port: self.config.webhook.port) { [weak self] event in
                        self?.statusPublisher.webhookProvider.handleEvent(event)
                        ShipLog.shared.handleWebhookEvent(event)
                        // TODO: Enable when webhook→TODO matching logic is implemented
                        // ShipLog.shared.updateTodoFromWebhook(event)
                    }
                    server.start()
                    self.terminalCoordinator.webhookServer = server
                }
            }
        }
    }

    // MARK: - Shared Worktree Integration

    /// Integrate newly discovered worktrees into the dashboard.
    /// Called from both webhook-triggered discovery and periodic polling.
    private func integrateNewWorktrees(repoRoot: String, allDiscovered: [WorktreeInfo], newWorktrees: [WorktreeInfo]) {
        // Idempotency guard: drop any worktree already tracked (compared by
        // canonical path) so no caller can append a duplicate entry/tab.
        let knownPaths = Set(allWorktrees.map { WorktreeDiscovery.canonicalPath($0.info.path) })
        let newWorktrees = newWorktrees.filter { !knownPaths.contains(WorktreeDiscovery.canonicalPath($0.path)) }
        guard !newWorktrees.isEmpty else { return }

        NSLog("[TabCoordinator] Integrating \(newWorktrees.count) new worktree(s) for \(repoRoot)")

        // Update WorkspaceManager tab
        if let tabIndex = workspaceManager.tabs.firstIndex(where: { $0.repoPath == repoRoot }) {
            workspaceManager.updateWorktrees(at: tabIndex, worktrees: allDiscovered)
        }

        for info in newWorktrees {
            let proj = workspaceManager.tabs.first(where: { $0.repoPath == repoRoot })?.displayName
                ?? URL(fileURLWithPath: repoRoot).lastPathComponent

            // Check if this worktree has a pending transfer (created via hook from an existing pane)
            if let transfer = pendingTransfers.consume(newWorktreePath: info.path) {
                NSLog("[TabCoordinator] Transferring pane from \(transfer.sourceWorktreePath) to \(info.path)")
                performPaneTransfer(transfer: transfer, newInfo: info, repoRoot: repoRoot, project: proj, allDiscoveredWorktrees: allDiscovered)
            } else {
                // No pending transfer — create a fresh tree
                let tree = terminalCoordinator.resolveTree(for: info)
                allWorktrees.append((info: info, tree: tree))
                worktreeRepoCache[info.path] = repoRoot

                let sessionName = runtimeBackend == "local" ? nil : SessionManager.persistentSessionName(for: info.path)
                if let surface = terminalCoordinator.stationManager.primaryStation(forPath: info.path) {
                    ShipLog.shared.register(station: surface, worktreePath: info.path, branch: info.branch, project: proj, startedAt: Date(), tmuxSessionName: sessionName, backend: runtimeBackend)
                }
            }
        }

        // Record startedAt for new worktrees
        let now = Self.iso8601.string(from: Date())
        var configChanged = false
        for info in newWorktrees {
            if config.worktreeStartedAt[info.path] == nil {
                config.worktreeStartedAt[info.path] = now
                configChanged = true
            }
        }
        if configChanged { saveConfig() }

        dashboardVC?.updateAgents(buildAgentDisplayInfos())
        statusPublisher.updateSurfaces(terminalCoordinator.stationManager.all)
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
    }

    // MARK: - Worktree Auto-Discovery (via Agent Hooks)

    private func handleNewWorktreeFromHook(_ worktreePath: String) {
        WorktreeDiscovery.findRepoRootAsync(from: worktreePath) { [weak self] repoRoot in
            guard let self, let repoRoot else {
                NSLog("[TabCoordinator] Could not find repo root for hook-discovered worktree: \(worktreePath)")
                return
            }

            if self.config.workspacePaths.contains(repoRoot) {
                WorktreeDiscovery.discoverAsync(repoPath: repoRoot) { [weak self] worktrees in
                    guard let self else { return }
                    let knownPaths = Set(self.allWorktrees.map { $0.info.path })
                    let newWorktrees = worktrees.filter { !knownPaths.contains($0.path) }
                    self.integrateNewWorktrees(repoRoot: repoRoot, allDiscovered: worktrees, newWorktrees: newWorktrees)
                }
            } else {
                NSLog("[TabCoordinator] Auto-adding new repo via hook: \(repoRoot)")
                self.addRepo(at: repoRoot)
            }
        }
    }

    private func performPaneTransfer(transfer: PendingWorktreeTransfer, newInfo: WorktreeInfo, repoRoot: String, project: String, allDiscoveredWorktrees: [WorktreeInfo]) {
        let sourcePath = transfer.sourceWorktreePath

        // 1. Transfer the SplitTree from source → new worktree path
        guard let transferredTree = terminalCoordinator.stationManager.transferTree(fromPath: sourcePath, toPath: newInfo.path) else {
            NSLog("[TabCoordinator] Transfer failed: no tree at \(sourcePath), falling back to fresh tree")
            let tree = terminalCoordinator.resolveTree(for: newInfo)
            allWorktrees.append((info: newInfo, tree: tree))
            worktreeRepoCache[newInfo.path] = repoRoot
            return
        }

        // 2. Update allWorktrees: remove old entry for source, add new entry
        allWorktrees.removeAll { $0.info.path == sourcePath }
        allWorktrees.append((info: newInfo, tree: transferredTree))
        worktreeRepoCache[newInfo.path] = repoRoot

        // 3. Re-register transferred surfaces in ShipLog under new worktree
        // Unregister all old agents for the source path first
        while let oldAgent = ShipLog.shared.agent(forWorktree: sourcePath) {
            ShipLog.shared.unregister(terminalID: oldAgent.id)
        }
        for leaf in transferredTree.allLeaves {
            if let station = StationRegistry.shared.station(forId: leaf.stationId) {
                let sessionName = runtimeBackend == "local" ? nil : SessionManager.persistentSessionName(for: newInfo.path)
                ShipLog.shared.register(station: station, worktreePath: newInfo.path, branch: newInfo.branch, project: project, startedAt: Date(), tmuxSessionName: sessionName, backend: runtimeBackend)
            }
        }

        // 4. Save the transferred tree's layout under the new path, remove old
        terminalCoordinator.config.splitLayouts.removeValue(forKey: sourcePath)
        terminalCoordinator.saveSplitLayout(transferredTree)

        // 5. Invalidate the old split container so the UI rebuilds it
        dashboardVC?.invalidateSplitContainer(forPath: sourcePath)

        // 6. Create a fresh tree for the source worktree (e.g., main)
        if let sourceInfo = allDiscoveredWorktrees.first(where: { $0.path == transfer.sourceWorktreePath }) {
            let freshTree = terminalCoordinator.stationManager.tree(for: sourceInfo, backend: runtimeBackend)
            if let idx = allWorktrees.firstIndex(where: { $0.info.path == sourceInfo.path }) {
                allWorktrees[idx] = (info: sourceInfo, tree: freshTree)
            } else {
                allWorktrees.append((info: sourceInfo, tree: freshTree))
            }
            worktreeRepoCache[sourceInfo.path] = repoRoot
            let sessionName = runtimeBackend == "local" ? nil : SessionManager.persistentSessionName(for: sourceInfo.path)
            if let surface = terminalCoordinator.stationManager.primaryStation(forPath: sourceInfo.path) {
                ShipLog.shared.register(station: surface, worktreePath: sourceInfo.path, branch: sourceInfo.branch, project: project, startedAt: Date(), tmuxSessionName: sessionName, backend: runtimeBackend)
            }
            terminalCoordinator.saveSplitLayout(freshTree)
        }
    }

    // MARK: - Worktree Lifecycle

    func worktreeDidDelete(_ info: WorktreeInfo) {
        let repoPath = worktreeRepoCache[info.path]
        allWorktrees.removeAll { $0.info.path == info.path }
        worktreeRepoCache.removeValue(forKey: info.path)
        if let repoPath,
           let tabIndex = workspaceManager.tabs.firstIndex(where: { $0.repoPath == repoPath }) {
            let remaining = workspaceManager.tabs[tabIndex].worktrees.filter { $0.path != info.path }
            workspaceManager.updateWorktrees(at: tabIndex, worktrees: remaining)
        }
        if let agent = ShipLog.shared.agent(forWorktree: info.path) {
            ShipLog.shared.unregister(terminalID: agent.id)
        }
        dashboardVC?.invalidateSplitContainer(forPath: info.path)
        dashboardVC?.updateAgents(buildAgentDisplayInfos())
        statusPublisher.updateSurfaces(terminalCoordinator.stationManager.all)

        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
    }

    // MARK: - Close Repo

    func performCloseRepo(projectName: String) {
        guard let tabIndex = workspaceManager.tabs.firstIndex(where: { $0.displayName == projectName }) else { return }
        let tab = workspaceManager.tabs[tabIndex]

        // Kill persisted sessions and destroy surfaces for this repo's worktrees
        for worktree in tab.worktrees {
            let primaryStation = terminalCoordinator.stationManager.primaryStation(forPath: worktree.path)
            terminalCoordinator.stationManager.removeTree(forPath: worktree.path)

            if let agent = ShipLog.shared.agent(forWorktree: worktree.path) {
                ShipLog.shared.unregister(terminalID: agent.id)
            } else if let primaryStation {
                ShipLog.shared.unregister(terminalID: primaryStation.id)
            }
            if runtimeBackend != "local" {
                let sessionName = SessionManager.persistentSessionName(for: worktree.path)
                SessionManager.killSession(sessionName, backend: runtimeBackend)
            }
        }

        allWorktrees.removeAll { item in
            tab.worktrees.contains(where: { $0.path == item.info.path })
        }

        config.workspacePaths.removeAll { $0 == tab.repoPath }
        saveConfig()

        workspaceManager.removeTab(at: tabIndex)

        activeTabIndex = -1
        delegate?.tabCoordinatorRequestClearContentContainer(self)

        dashboardVC?.updateAgents(buildAgentDisplayInfos())
        statusPublisher.updateSurfaces(terminalCoordinator.stationManager.all)
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
        switchToTab(0)
    }

    // MARK: - Modals

    func showCloseProjectModal(_ projectName: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Close \"\(projectName)\"?"
        alert.informativeText = "This will close all terminals and kill persisted sessions for this repository."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            performCloseRepo(projectName: projectName)
        }
    }

    weak var panelCoordinator: PanelCoordinator?

    func showAddProjectModal(window: NSWindow?) {
        addRepoViaOpenPanel(window: window)
    }

    func showNewThreadModal(window: NSWindow?) {
        delegate?.tabCoordinatorRequestShowNewBranchDialog(self)
    }

    // MARK: - Branch Refresh

    func startBranchRefreshTimer() {
        branchRefreshTimer?.invalidate()
        branchRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshBranches()
            // Re-evaluate worktree-tab idle collapse even when nothing changed.
            self.delegate?.tabCoordinatorRequestUpdateTitleBar(self)
        }
    }

    private func refreshBranches() {
        let tabs = workspaceManager.tabs
        for (tabIndex, tab) in tabs.enumerated() {
            WorktreeDiscovery.discoverAsync(repoPath: tab.repoPath) { [weak self] freshWorktrees in
                guard let self else { return }
                _ = self.reconcileDiscoveredWorktrees(tabIndex: tabIndex, oldWorktrees: tab.worktrees, freshWorktrees: freshWorktrees)
            }
        }
    }

    @discardableResult
    func reconcileDiscoveredWorktrees(tabIndex: Int, oldWorktrees: [WorktreeInfo], freshWorktrees: [WorktreeInfo]) -> Bool {
        guard !freshWorktrees.isEmpty else { return false }
        guard let tab = workspaceManager.tab(at: tabIndex) else { return false }

        // Compare by canonical path: discovery emits symlink-resolved paths that
        // may differ as strings from how a worktree path was originally stored.
        let knownPaths = Set(allWorktrees.map { WorktreeDiscovery.canonicalPath($0.info.path) })
        let freshPaths = Set(freshWorktrees.map(\.path))
        let deletedWorktrees = oldWorktrees.filter { !freshPaths.contains($0.path) }

        var changed = false
        if !deletedWorktrees.isEmpty {
            workspaceManager.updateWorktrees(at: tabIndex, worktrees: freshWorktrees)
            for deleted in deletedWorktrees {
                terminalCoordinator.stationManager.removeTree(forPath: deleted.path)
                worktreeDidDelete(deleted)
            }
            changed = true
        }

        let newWorktrees = freshWorktrees.filter { !knownPaths.contains(WorktreeDiscovery.canonicalPath($0.path)) }
        if !newWorktrees.isEmpty {
            integrateNewWorktrees(repoRoot: tab.repoPath, allDiscovered: freshWorktrees, newWorktrees: newWorktrees)
            changed = true
        }

        let branchChanged = freshWorktrees.contains { fresh in
            oldWorktrees.first(where: { $0.path == fresh.path })?.branch != fresh.branch
        }

        guard changed || branchChanged else { return false }

        for (i, entry) in allWorktrees.enumerated() {
            if let fresh = freshWorktrees.first(where: { $0.path == entry.info.path }) {
                allWorktrees[i] = (info: fresh, tree: entry.tree)
            }
        }

        workspaceManager.updateWorktrees(at: tabIndex, worktrees: freshWorktrees)
        dashboardVC?.updateAgents(buildAgentDisplayInfos())
        statusPublisher.updateSurfaces(terminalCoordinator.stationManager.all)
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
        return true
    }

    // MARK: - Session State Persistence

    func saveSessionState() {
        config.activeTabRepoPath = nil
        saveSelectedWorktree()
        saveConfig()
    }

    func saveSelectedWorktree() {
        if let agent = selectedAgent {
            config.selectedWorktreePath = agent.worktreePath
        }
    }

    func restoreSessionState() {
        // Restore selected agent card from config
        if let savedPath = config.selectedWorktreePath {
            dashboardVC?.selectAgent(byWorktreePath: savedPath)
        }
    }

    // MARK: - Navigation

    // MARK: - Dashboard Delegate Forwarding

    func dashboardDidSelectProject(_ project: String, thread: String) {
        guard let tab = workspaceManager.tabs.first(where: { $0.displayName == project }) else { return }
        // Save the selected worktree for this project
        if let worktreePath = tab.worktrees.first(where: { $0.branch == thread })?.path {
            config.activeWorktreePaths[tab.repoPath] = worktreePath
            saveConfig()
        }
        // Dashboard handles focus panel display via agent card selection
    }

    func dashboardDidRequestEnterProject(_ project: String) {
        // Dashboard handles focus panel — no separate tab needed
    }

    func dashboardDidRequestDelete(_ terminalID: String, window: NSWindow?) {
        guard let agent = ShipLog.shared.agent(for: terminalID) else { return }
        let worktreePath = agent.worktreePath
        guard let item = allWorktrees.first(where: { $0.info.path == worktreePath }) else { return }
        terminalCoordinator.confirmAndDeleteWorktree(item.info, window: window)
    }

    // MARK: - New Branch Integration

    func handleNewBranch(info: WorktreeInfo, repoPath: String) {
        // Build the full worktree list for this repo (existing + newly created)
        // so integrateNewWorktrees can update workspaceManager correctly.
        let existing = workspaceManager.tabs.first(where: { $0.repoPath == repoPath })?.worktrees ?? []
        let allDiscovered = existing + [info]

        integrateNewWorktrees(repoRoot: repoPath, allDiscovered: allDiscovered, newWorktrees: [info])

        // Focus the newly created worktree's minicard
        dashboardVC?.selectAgent(byWorktreePath: info.path)
    }

    // MARK: - Status Update Forwarding

    func handleWorktreeStatusUpdate(_ status: WorktreeStatus) {
        dashboardVC?.updateAgents(buildAgentDisplayInfos())
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
    }

    func handlePaneStatusChange(worktreePath: String, paneIndex: Int, oldStatus: AgentStatus, newStatus: AgentStatus, lastMessage: String) {
        let branch = allWorktrees.first(where: { $0.info.path == worktreePath })?.info.branch ?? ""
        let repoPath = worktreeRepoCache[worktreePath] ?? WorktreeDiscovery.findRepoRoot(from: worktreePath) ?? worktreePath
        let workspaceName = workspaceManager.tabs.first(where: { $0.repoPath == repoPath })?.displayName
            ?? URL(fileURLWithPath: repoPath).lastPathComponent
        let worktreeStatus = statusAggregator.status(for: worktreePath)
        let paneCount = worktreeStatus?.panes.count ?? 1
        let paneStatus = worktreeStatus?.panes.first(where: { $0.paneIndex == paneIndex })
        let terminalID = paneStatus?.terminalID ?? ""
        let lastUserPrompt = paneStatus?.lastUserPrompt ?? ""

        // Determine if this pane is the currently focused one
        let isFocused = isFocusedPane(worktreePath: worktreePath, paneIndex: paneIndex)

        NotificationManager.shared.notify(
            terminalID: terminalID,
            worktreePath: worktreePath,
            workspaceName: workspaceName,
            branch: branch,
            paneIndex: paneIndex,
            paneCount: paneCount,
            oldStatus: oldStatus,
            newStatus: newStatus,
            lastMessage: lastMessage,
            lastUserPrompt: lastUserPrompt,
            isFocusedPane: isFocused
        )
    }

    /// Check if a specific worktree + pane is the currently focused pane.
    private func isFocusedPane(worktreePath: String, paneIndex: Int) -> Bool {
        guard let container = dashboardVC?.activeSplitContainer,
              let tree = container.tree,
              tree.worktreePath == worktreePath else { return false }
        let leaves = tree.allLeaves
        let zeroBasedIndex = paneIndex - 1
        guard zeroBasedIndex >= 0, zeroBasedIndex < leaves.count else { return false }
        return leaves[zeroBasedIndex].id == tree.focusedId
    }

    // MARK: - Tab Selection

    static func tabIndex(forWorktree path: String, in paths: [String]) -> Int? {
        paths.firstIndex(of: path)
    }

    func selectTab(forWorktree path: String) {
        dashboardVC?.selectAgent(byWorktreePath: path)
        saveSelectedWorktree()
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
    }

    // MARK: - Navigation

    func handleNavigateToWorktree(worktreePath: String, paneIndex: Int?) {
        // Navigation is now handled by the dashboard — select the matching agent card.
        // If the worktree is already known, the dashboard will show it in the focus panel.
        // If not yet tracked, discover and add it first.
        if workspaceManager.tabs.contains(where: { tab in
            tab.worktrees.contains(where: { $0.path == worktreePath })
        }) {
            dashboardVC?.updateAgents(buildAgentDisplayInfos())
            dashboardVC?.selectAgent(byWorktreePath: worktreePath)
            saveSelectedWorktree()
            delegate?.tabCoordinatorRequestUpdateTitleBar(self)
            return
        }

        // Fall back: search workspace paths asynchronously
        let workspacePaths = config.workspacePaths
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var foundRepoPath: String?
            for wsPath in workspacePaths {
                let worktrees = WorktreeDiscovery.discover(repoPath: wsPath)
                if worktrees.contains(where: { $0.path == worktreePath }) {
                    foundRepoPath = wsPath
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self, let repoPath = foundRepoPath else { return }
                self.openRepoTab(repoPath: repoPath) { [weak self] in
                    self?.dashboardVC?.selectAgent(byWorktreePath: worktreePath)
                    self?.saveSelectedWorktree()
                    if let self {
                        self.delegate?.tabCoordinatorRequestUpdateTitleBar(self)
                    }
                }
            }
        }
    }
}

// MARK: - First Mate Inspection

extension TabCoordinator {
    /// Run inspectionCommands in the worktree dir on a background queue,
    /// then notify with the combined output. autoReview is stubbed — the
    /// auto-launch mechanism lives in MainWindowController and requires
    /// backend/session context not available here (DONE_WITH_CONCERNS).
    func runFirstMateInspection(_ action: FirstMateAction) {
        let commands = config.firstMate.inspectionCommands
        let worktreePath = action.worktreePath
        let isAutoCommit = action.kind == .autoCommit
        guard !commands.isEmpty || isAutoCommit else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var results: [String] = []
            var firstFailedCmd: String? = nil
            for cmd in commands {
                let rawOutput = ProcessRunner.output(["bash", "-lc", "cd \(worktreePath.shellQuoted) && \(cmd)"])
                if rawOutput == nil && firstFailedCmd == nil { firstFailedCmd = cmd }
                results.append("[\(cmd)]\n\(rawOutput ?? "(failed)")")
            }
            let combined = results.joined(separator: "\n---\n")
            let passed = firstFailedCmd == nil

            var commitResult: String? = nil
            if isAutoCommit {
                _ = ProcessRunner.output(["git", "-C", worktreePath, "add", "-A"])
                let commitOut = ProcessRunner.output(["git", "-C", worktreePath, "commit", "-m", "seahelm: auto-commit after agent completion"])
                commitResult = commitOut != nil ? "auto-commit succeeded" : "auto-commit: nothing to commit or failed"
            }

            DispatchQueue.main.async {
                if !combined.isEmpty {
                    NotificationManager.shared.notify(
                        worktreePath: worktreePath,
                        workspaceName: action.project,
                        branch: action.branch,
                        oldStatus: .running,
                        newStatus: .idle,
                        lastMessage: combined
                    )
                }
                // Record inspection result in watch feed
                var watchMsg: String
                if let cr = commitResult {
                    watchMsg = cr
                } else if passed {
                    watchMsg = self.config.firstMate.autoReview
                        ? "验船通过 · review 就绪(手动拉起)"
                        : "验船通过"
                } else {
                    watchMsg = "验船失败: \(firstFailedCmd!)"
                }
                let watchAction = FirstMateAction(
                    kind: isAutoCommit ? .autoCommit : .inspect,
                    zone: passed ? .green : .red,
                    worktreePath: action.worktreePath,
                    branch: action.branch,
                    project: action.project,
                    terminalID: action.terminalID,
                    message: watchMsg
                )
                self.watchFeed.record(watchAction)
            }
        }
    }
}

private extension String {
    var shellQuoted: String { "'\(self.replacingOccurrences(of: "'", with: "'\\''"))'" }
}
