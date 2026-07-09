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
    private(set) var firstMate: FirstMateCoordinator!

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    var selectedSailor: SailorDisplayInfo? {
        guard let dashboard = dashboardVC else { return nil }
        let index = dashboard.selectedSailorIndex
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
            // TerminalCoordinator is the authoritative holder of agentSessions
            // (restore/close/delete all live there). Sync before saving so this
            // coordinator's copy doesn't clobber it.
            config.agentSessions = tc.config.agentSessions
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
                let status: SailorStatus = action.kind == .watchError ? .error : .waiting
                // First Mate watches are background attention signals — surface
                // them even when frontmost (isTargetVisible defaults to false).
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
            }
        )
        ShipLog.shared.onOutcome = { [weak self] outcome in
            guard let self else { return }
            self.firstMate?.handle(outcome)
            // Feed the worktree aggregator from ShipLog's arbitrated status
            // (scan + hook + OSC), so the dashboard reflects hook/OSC-driven
            // "running" that the scan-only path misses when the viewport text is
            // static (agent thinking; only the OSC-title spinner animates).
            self.statusAggregator?.agentDidUpdate(
                terminalID: outcome.info.id,
                status: outcome.newStatus,
                lastMessage: outcome.info.lastMessage,
                lastUserPrompt: outcome.info.lastUserPrompt,
                agentType: outcome.info.agentType)
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

    deinit { ShipLog.shared.onOutcome = nil }

    // MARK: - Tab Switching

    func switchToTab(_ index: Int) {
        guard index != activeTabIndex else { return }

        dashboardVC?.detachTerminals()
        activeTabIndex = 0

        if let dashboard = dashboardVC {
            delegate?.tabCoordinator(self, embedViewController: dashboard)
            dashboard.updateSailors(buildSailorDisplayInfos())
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
            // A failed discovery on a vanished directory must not fall through to
            // persisting `path` — that's how a deleted worktree once got stuck in
            // workspace_paths as a phantom repo.
            if worktrees.isEmpty, !FileManager.default.fileExists(atPath: path) {
                NSLog("[TabCoordinator] Refusing to add nonexistent repo path: \(path)")
                return
            }
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
                ShipLog.shared.register(station: surface, worktreePath: info.path, branch: info.branch, project: proj, startedAt: started, sessionName: sessionName, backend: runtimeBackend)
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

        dashboardVC?.updateSailors(buildSailorDisplayInfos())
        statusPublisher.updateSurfaces(terminalCoordinator.stationManager.all)
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)

        return tabIndex
    }

    /// Drop per-worktree config entries whose directory no longer exists, so a
    /// deleted worktree doesn't leave timestamps/layouts/session names behind
    /// forever. Runs once per loadWorkspaces.
    private func pruneStaleWorktreeConfigEntries() {
        // Probe every candidate path up front, concurrently and with a timeout.
        // A synchronous `fileExists` per path on the main thread would beachball
        // the app when the paths live on a removable volume that was ejected and
        // remounted (stale-mount `stat()` blocks forever). `missingPaths` only
        // reports paths that *definitively* don't exist, so an unreachable drive
        // never causes us to prune (and destroy) the user's saved workspaces.
        var candidates = Set<String>()
        candidates.formUnion(config.worktreeStartedAt.keys)
        candidates.formUnion(config.worktreeLastActivityAt.keys)
        candidates.formUnion(config.splitLayouts.keys)
        candidates.formUnion(config.focusedPaneIds.keys)
        candidates.formUnion(config.activeWorktreePaths.values)
        if let selected = config.selectedWorktreePath { candidates.insert(selected) }
        candidates.formUnion(config.cardOrder)

        let missing = FileSystemProbe.missingPaths(from: Array(candidates))
        guard !missing.isEmpty else { return }

        var changed = false
        func prune<V>(_ map: inout [String: V]) {
            for path in map.keys where missing.contains(path) {
                map.removeValue(forKey: path)
                changed = true
            }
        }
        prune(&config.worktreeStartedAt)
        prune(&config.worktreeLastActivityAt)
        prune(&config.splitLayouts)
        prune(&config.focusedPaneIds)
        for (repo, worktree) in config.activeWorktreePaths where missing.contains(worktree) {
            config.activeWorktreePaths.removeValue(forKey: repo)
            changed = true
        }
        if let selected = config.selectedWorktreePath, missing.contains(selected) {
            config.selectedWorktreePath = nil
            changed = true
        }
        let prunedOrder = config.cardOrder.filter { !missing.contains($0) }
        if prunedOrder != config.cardOrder {
            config.cardOrder = prunedOrder
            changed = true
        }
        if changed { saveConfig() }
    }

    // MARK: - Build Agent Display Infos

    func buildSailorDisplayInfos() -> [SailorDisplayInfo] {
        let agents = ShipLog.shared.allSailors()
        var seen = Set<String>()
        var result: [SailorDisplayInfo] = []

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
            // Roll up EVERY pane's ShipLog status for this worktree (authoritative,
            // arbitrated). A multi-pane worktree must reflect its busiest pane, so
            // don't collapse to the aggregator's list or a single sailor here.
            let shipLogPaneStatuses = agents.filter { $0.worktreePath == agent.worktreePath }.map(\.status)
            let paneStatuses = !shipLogPaneStatuses.isEmpty ? shipLogPaneStatuses
                : (ws?.statuses ?? [agent.status])
            let mostRecentMessage = ws?.mostRecentMessage ?? (agent.lastMessage.isEmpty ? "No active task." : agent.lastMessage)
            let mostRecentUserPrompt = ws?.mostRecentUserPrompt ?? agent.lastUserPrompt
            let mostRecentPaneIndex = ws?.mostRecentPaneIndex ?? 1

            let matchedWorktree = allWorktrees.first(where: { $0.info.path == agent.worktreePath })
            let isMain = matchedWorktree?.info.isMainWorktree ?? false
            let freshBranch = matchedWorktree?.info.branch ?? agent.branch

            result.append(SailorDisplayInfo(
                id: agent.id,
                name: freshBranch,
                project: agent.project,
                thread: freshBranch,
                paneStatuses: paneStatuses,
                mostRecentMessage: mostRecentMessage,
                lastUserPrompt: mostRecentUserPrompt,
                mostRecentPaneIndex: mostRecentPaneIndex,
                totalDuration: SailorDisplayHelpers.formatDuration(agent.totalDuration),
                roundDuration: SailorDisplayHelpers.formatDuration(agent.roundDuration),
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
                // Self-heal: a workspace path whose directory vanished (deleted
                // worktree/repo) is dropped instead of resurrected as a phantom
                // "main" tab on every launch.
                // Bounded probe: a stale removable-mount `stat()` would otherwise
                // block this background discovery forever, so the launch
                // completion never fires and the app looks hung. `FileSystemProbe`
                // treats an unreachable path as present (kept), not pruned.
                guard FileSystemProbe.exists(repoPath) else {
                    NSLog("[TabCoordinator] Pruning nonexistent workspace path: \(repoPath)")
                    continue
                }
                let worktrees = WorktreeDiscovery.discover(repoPath: repoPath)
                // Resolve to main worktree path so display name reflects the repo root
                let resolved = worktrees.first(where: { $0.isMainWorktree })?.path ?? repoPath
                // Two entries can resolve to the same repo root (e.g. a worktree
                // added by mistake alongside its main repo) — keep one tab.
                guard !resolvedPaths.contains(resolved) else { continue }
                discoveredWorktrees.append((resolved, worktrees))
                resolvedPaths.append(resolved)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // Update config if any paths were resolved to their main worktree
                // or pruned above.
                if resolvedPaths != repoPaths {
                    self.config.workspacePaths = resolvedPaths
                    self.saveConfig()
                }
                self.pruneStaleWorktreeConfigEntries()

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
                        ShipLog.shared.register(station: surface, worktreePath: info.path, branch: info.branch, project: proj, startedAt: started, sessionName: sessionName, backend: self.runtimeBackend)
                    }
                }
                if !cardOrder.isEmpty {
                    ShipLog.shared.reorder(paths: cardOrder)
                }

                self.dashboardVC?.updateSailors(self.buildSailorDisplayInfos())
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
                    self.statusPublisher.webhookProvider.onAgentSessionResolved = { [weak self] worktreePath, ref in
                        self?.recordAgentSession(worktreePath: worktreePath, ref: ref)
                    }
                    self.statusPublisher.webhookProvider.onWorktreeCreateReceived = { [weak self] sourcePath, worktreeName, sessionId, paneId in
                        guard let self else { return }
                        NSLog("[TabCoordinator] WorktreeCreate: recording pending transfer from \(sourcePath) for \(worktreeName) (pane \(paneId ?? "?"))")
                        self.pendingTransfers.record(sourceWorktreePath: sourcePath, worktreeName: worktreeName, sessionId: sessionId, paneId: paneId)
                    }
                    // Per-session timestamps: when we last blocked a session for suggestions,
                    // and when a user prompt last arrived for that session. If the user sent a
                    // message AFTER our last block, Claude's next stop is a response to explicit
                    // user direction — suppress the suggestion block so Claude can respond cleanly
                    // without mixing suggestion overhead into the user-directed response.
                    var sessionBlockedAt: [String: Date] = [:]
                    var sessionUserPromptedAt: [String: Date] = [:]
                    // When the agent voluntarily called seahelm-suggest this turn (it was
                    // instructed to as its last action). If so, we needn't force a
                    // suggestion via a blocking Stop — that saves the block→continue
                    // round-trip. Reset each turn (on the next user prompt).
                    var sessionSuggestedAt: [String: Date] = [:]

                    // Shared inbound-event sink, serialized so the webhook and the
                    // control socket can both feed it without racing the per-session
                    // dictionaries below.
                    let eventQueue = DispatchQueue(label: "seahelm.event-sink")
                    let handleEvent: (WebhookEvent) -> String? = { [weak self] event in
                      eventQueue.sync {
                        guard let self else { return nil }
                        // Correlate the suggest→Stop suppression by pane, not session:
                        // the agent-invoked `seahelm-suggest` carries only a pane id, while
                        // the native Stop hook carries Claude's real session UUID. Keying off
                        // sessionId made the two never match, so the block fired every turn.
                        // paneId is stable across both; fall back to sessionId outside a pane.
                        let turnKey = event.paneId ?? event.sessionId
                        // Track when the user sent a message to this session; a new
                        // user prompt starts a fresh turn, so the agent must suggest again.
                        if event.event == .userPrompt {
                            sessionUserPromptedAt[turnKey] = Date()
                            sessionSuggestedAt.removeValue(forKey: turnKey)
                        }
                        // Track per-worktree background-task state (subagent/shell/cron).
                        ShipLog.shared.updateBackgroundBusy(from: event)
                        // Drop a (voluntary) suggestion while background work is still running —
                        // the agent will auto-resume, so it isn't a real end-of-turn yet.
                        if event.event == .suggest, ShipLog.shared.isBackgroundBusy(cwd: event.cwd) {
                            return nil
                        }
                        // The agent gave its own suggestions this turn (per the injected
                        // instruction) — record it so the Stop below won't force another.
                        if event.event == .suggest {
                            sessionSuggestedAt[turnKey] = Date()
                        }
                        // Suppress the suggestion block when the user sent a message after our
                        // last block — Claude is responding to explicit user direction and doesn't
                        // need suggestion overhead layered on top of the user-directed response.
                        if event.event == .agentStop, sessionSuggestedAt[turnKey] != nil {
                            // The agent already emitted buttons as its last action this
                            // turn — no forced block needed (no extra round-trip).
                            sessionSuggestedAt.removeValue(forKey: turnKey)
                        } else if event.event == .agentStop,
                           let blockedAt = sessionBlockedAt[turnKey],
                           let promptedAt = sessionUserPromptedAt[turnKey],
                           promptedAt > blockedAt {
                            sessionBlockedAt.removeValue(forKey: turnKey)
                            sessionUserPromptedAt.removeValue(forKey: turnKey)
                        } else if let block = StopHookResponder.blockBody(
                            for: event, suggestOnStop: self.config.webhook.suggestOnStop) {
                            // Blocking Stop: agent will continue and call seahelm-suggest.
                            // Do NOT ingest this stop as completion (avoid premature idle), but
                            // stash the agent's final message so the suggestion card can show it.
                            sessionBlockedAt[turnKey] = Date()
                            if let msg = event.data?["last_assistant_message"] as? String {
                                ShipLog.shared.noteAssistantMessage(cwd: event.cwd, message: msg)
                            }
                            return block
                        }
                        self.statusPublisher.webhookProvider.handleEvent(event)
                        ShipLog.shared.handleWebhookEvent(event)
                        // TODO: Enable when webhook→TODO matching logic is implemented
                        // ShipLog.shared.updateTodoFromWebhook(event)
                        return nil
                      }
                    }
                    // Local control socket is the sole inbound transport: reads
                    // (snapshot/read) + the shared event sink for hook/suggest.
                    // (The HTTP webhook was retired once the socket path was
                    // verified end-to-end.)
                    let controlDataSource = SeahelmControlDataSource(hookSink: handleEvent)
                    controlDataSource.splitHandler = { [weak self] targetStationId, axis, focus in
                        self?.terminalCoordinator.splitPane(targetStationId: targetStationId, axis: axis, focus: focus)
                    }
                    controlDataSource.closeHandler = { [weak self] stationId in
                        self?.terminalCoordinator.closePane(targetStationId: stationId) ?? false
                    }
                    controlDataSource.focusHandler = { [weak self] stationId in
                        self?.terminalCoordinator.focusPane(targetStationId: stationId) ?? false
                    }
                    controlDataSource.exportLayoutHandler = { [weak self] in
                        self?.terminalCoordinator.exportLayout()
                    }
                    controlDataSource.applyLayoutHandler = { [weak self] node in
                        self?.terminalCoordinator.applyLayout(node) ?? false
                    }
                    controlDataSource.zoomHandler = { [weak self] stationId, mode in
                        self?.terminalCoordinator.zoomPane(targetStationId: stationId, mode: mode)
                    }
                    let control = ControlSocketServer(
                        router: ControlRouter(dataSource: controlDataSource))
                    control.start()
                    self.terminalCoordinator.controlSocketServer = control
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
                    ShipLog.shared.register(station: surface, worktreePath: info.path, branch: info.branch, project: proj, startedAt: Date(), sessionName: sessionName, backend: runtimeBackend)
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

        dashboardVC?.updateSailors(buildSailorDisplayInfos())
        statusPublisher.updateSurfaces(terminalCoordinator.stationManager.all)
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
    }

    // MARK: - Worktree Auto-Discovery (via Agent Hooks)

    /// Persist an agent resume ref (keyed by backend session name) and apply it
    /// to the live station so a mid-session zmx recovery can relaunch the agent.
    /// Called on the main thread.
    private func recordAgentSession(worktreePath: String, ref: AgentSessionRef) {
        let name = SessionManager.persistentSessionName(for: worktreePath)
        // Apply to the live primary station (best-effort; drives mid-session recovery).
        terminalCoordinator.stationManager.primaryStation(forPath: worktreePath)?.agentSessionRef = ref
        // Write to the authoritative (TerminalCoordinator) copy, then persist.
        guard terminalCoordinator.config.agentSessions[name] != ref else { return }
        terminalCoordinator.config.agentSessions[name] = ref
        saveConfig()
    }

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
        while let oldAgent = ShipLog.shared.sailor(forWorktree: sourcePath) {
            ShipLog.shared.unregister(terminalID: oldAgent.id)
        }
        for leaf in transferredTree.allLeaves {
            if let station = StationRegistry.shared.station(forId: leaf.stationId) {
                // zmx has no rename, so the session keeps its original (source-derived)
                // name. Register with that real name — NOT persistentSessionName(for:
                // newInfo.path), which would build a channel to a nonexistent session
                // and let the orphan-reaper reap the live one.
                let sessionName = runtimeBackend == "local" ? nil : leaf.sessionName
                ShipLog.shared.register(station: station, worktreePath: newInfo.path, branch: newInfo.branch, project: project, startedAt: Date(), sessionName: sessionName, backend: runtimeBackend)
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
                ShipLog.shared.register(station: surface, worktreePath: sourceInfo.path, branch: sourceInfo.branch, project: project, startedAt: Date(), sessionName: sessionName, backend: runtimeBackend)
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
        if let agent = ShipLog.shared.sailor(forWorktree: info.path) {
            ShipLog.shared.unregister(terminalID: agent.id)
        }
        dashboardVC?.invalidateSplitContainer(forPath: info.path)
        dashboardVC?.updateSailors(buildSailorDisplayInfos())
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

            if let agent = ShipLog.shared.sailor(forWorktree: worktree.path) {
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

        dashboardVC?.updateSailors(buildSailorDisplayInfos())
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
        dashboardVC?.updateSailors(buildSailorDisplayInfos())
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
        if let agent = selectedSailor {
            config.selectedWorktreePath = agent.worktreePath
        }
    }

    func restoreSessionState() {
        // Restore selected agent card from config
        if let savedPath = config.selectedWorktreePath {
            dashboardVC?.selectSailor(byWorktreePath: savedPath)
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
        guard let agent = ShipLog.shared.sailor(for: terminalID) else { return }
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
        dashboardVC?.selectSailor(byWorktreePath: info.path)
    }

    // MARK: - Status Update Forwarding

    func handleWorktreeStatusUpdate(_ status: WorktreeStatus) {
        dashboardVC?.updateSailors(buildSailorDisplayInfos(), changedWorktreePath: status.worktreePath)
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
    }

    func handlePaneStatusChange(worktreePath: String, paneIndex: Int, oldStatus: SailorStatus, newStatus: SailorStatus, lastMessage: String) {
        let branch = allWorktrees.first(where: { $0.info.path == worktreePath })?.info.branch ?? ""
        let repoPath = worktreeRepoCache[worktreePath] ?? WorktreeDiscovery.findRepoRoot(from: worktreePath) ?? worktreePath
        let workspaceName = workspaceManager.tabs.first(where: { $0.repoPath == repoPath })?.displayName
            ?? URL(fileURLWithPath: repoPath).lastPathComponent
        let worktreeStatus = statusAggregator.status(for: worktreePath)
        let paneCount = worktreeStatus?.panes.count ?? 1
        let paneStatus = worktreeStatus?.panes.first(where: { $0.paneIndex == paneIndex })
        let terminalID = paneStatus?.terminalID ?? ""
        let lastUserPrompt = paneStatus?.lastUserPrompt ?? ""

        NotificationManager.shared.notify(
            worktreePath: worktreePath,
            workspaceName: workspaceName,
            branch: branch,
            paneIndex: paneIndex,
            paneCount: paneCount,
            terminalID: terminalID,
            oldStatus: oldStatus,
            newStatus: newStatus,
            lastMessage: lastMessage,
            lastUserPrompt: lastUserPrompt,
            isTargetVisible: isWorktreeVisible(worktreePath)
        )
    }

    /// Whether this worktree is the one currently shown in the dashboard (all its
    /// panes are on screen). Combined with app-frontmost in `NotificationManager`
    /// to decide whether a system banner would be redundant.
    private func isWorktreeVisible(_ worktreePath: String) -> Bool {
        dashboardVC?.activeSplitContainer?.tree?.worktreePath == worktreePath
    }

    // MARK: - Tab Selection

    static func tabIndex(forWorktree path: String, in paths: [String]) -> Int? {
        paths.firstIndex(of: path)
    }

    func selectTab(forWorktree path: String) {
        dashboardVC?.selectSailor(byWorktreePath: path)
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
            dashboardVC?.updateSailors(buildSailorDisplayInfos())
            dashboardVC?.selectSailor(byWorktreePath: worktreePath)
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
                    self?.dashboardVC?.selectSailor(byWorktreePath: worktreePath)
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
                        lastMessage: combined,
                        isTargetVisible: self.isWorktreeVisible(worktreePath)
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
