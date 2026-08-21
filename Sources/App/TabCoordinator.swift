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

    private var hostGatewayServer: HostGatewayServer?
    private var zmxVTAttachManager: ZmxVTAttachManager?
    /// The live control data source. Also the pane lookup + write channel the
    /// iMessage rule engine and Host Gateway dispatch through.
    private(set) var mqttDataSource: ControlDataSource?
    private var mailPaneRouter: MailPaneRouter?
    /// Set by `MainWindowController`, which owns the fleet accessors and the
    /// shared chat route mail commands are executed through.
    weak var mailCommandContext: MailCommandContext? {
        didSet { mailPaneRouter?.commandContext = mailCommandContext }
    }
    private let mailConversationStore = EmailConversationStore()
    private lazy var mailPaneObserver = MailPaneObserver(conversations: mailConversationStore)

    var activeTabIndex: Int = 0
    var allWorktrees: [(info: WorktreeInfo, tree: SplitTree)] = []
    var worktreeRepoCache: [String: String] = [:]

    /// Display name of the repo owning a given worktree path.
    func repoName(forWorktree path: String) -> String {
        let repoPath = worktreeRepoCache[path] ?? path
        return workspaceManager.tabs.first(where: { $0.repoPath == repoPath })?.displayName
            ?? URL(fileURLWithPath: repoPath).lastPathComponent
    }
    /// Repo path behind a project display name — the inverse of `repoName`, for
    /// surfaces (fleet group headers) that only carry the display title.
    func repoPath(forProject project: String) -> String? {
        workspaceManager.tabs.first(where: { $0.displayName == project })?.repoPath
    }

    var branchRefreshTimer: Timer?
    weak var dashboardVC: DashboardViewController?
    /// Per-worktree signature of the last-persisted pane titles, so the display
    /// rebuild only re-saves a layout when a pane's title actually changed.
    private var lastSavedPaneTitles: [String: [String]] = [:]

    // References provided by MainWindowController
    var terminalCoordinator: TerminalCoordinator!
    var statusPublisher: StatusPublisher!
    var statusAggregator: WorktreeStatusAggregator!
    var runtimeBackend: String = "local"
    let pendingTransfers = PendingTransferTracker()

    // First Mate — status-transition engine + red-zone queue + green-zone watch
    let pendingOrders = PendingOrdersQueue()
    let watchFeed = WatchFeed()
    private(set) var firstMate: FirstMateCoordinator!

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    var selectedPane: WorktreeRowInfo? {
        guard let dashboard = dashboardVC else { return nil }
        let index = dashboard.selectedPaneIndex
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
        // MainWindow owns chrome layout; when saving from here, those fields on
        // `config` may be stale — leave them alone unless the caller updated them.
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
                // Watch feed only. The pane status path (deliverPaneStatusChange)
                // already notified on the same running → waiting/error edge; a
                // second NotificationManager call here used a different cooldown
                // key ("wt:" vs "tid:") and re-bannered the same episode ~30s
                // later. First Mate watches are now a feed record, not a banner.
                feed.record(action)
            },
            runInspection: { [weak self] action in
                self?.runFirstMateInspection(action)
            }
        )
        AgentRegistry.shared.onOutcome = { [weak self] outcome in
            guard let self else { return }
            switch outcome.event.source {
            case .scan:
                break
            case .hook, .mcp, .shell:
                self.statusPublisher.invalidateScanCache(terminalID: outcome.info.id)
            }
            self.firstMate?.handle(outcome)
            self.mailPaneObserver.ingest(outcome)
            // Feed the worktree aggregator from AgentRegistry's arbitrated status
            // (scan + hook + OSC), so the dashboard reflects hook/OSC-driven
            // "running" that the scan-only path misses when the viewport text is
            // static (agent thinking; only the OSC-title spinner animates).
            self.statusAggregator?.agentDidUpdate(
                terminalID: outcome.info.id,
                status: outcome.newStatus,
                lastMessage: outcome.info.lastMessage,
                lastUserPrompt: outcome.info.lastUserPrompt,
                agentType: outcome.info.agentType,
                backgroundBusy: outcome.info.backgroundBusy)
            // Aggregator ignores commandLine-only changes; chrome pane title
            // still needs a refresh when the foreground shell job updates.
            self.delegate?.tabCoordinatorRequestUpdateTitleBar(self)
        }
        NotificationCenter.default.addObserver(forName: .repoViewDidChangeFocusedPane, object: nil, queue: .main) { [weak self] notification in
            guard let self,
                  let worktreePath = notification.userInfo?["worktreePath"] as? String,
                  let leafId = notification.userInfo?["focusedLeafId"] as? String else { return }
            // Save session name (stable across launches) instead of leaf ID
            if let tree = self.terminalCoordinator.stationManager.tree(forPath: worktreePath),
               let leaf = tree.allLeaves.first(where: { $0.id == leafId }) {
                self.config.focusedPaneIds[worktreePath] = leaf.paneSessionKey
            }
            self.saveConfig()
        }
    }

    deinit { AgentRegistry.shared.onOutcome = nil }

    // MARK: - Tab Switching

    func switchToTab(_ index: Int) {
        guard index != activeTabIndex else { return }

        dashboardVC?.detachTerminals()
        activeTabIndex = 0

        if let dashboard = dashboardVC {
            delegate?.tabCoordinator(self, embedViewController: dashboard)
            dashboard.updatePanes(buildWorktreeRowInfos())
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
        panel.message = "Select a directory to add (git repo or any folder)"
        panel.prompt = "Add"

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
            effectiveWorktrees = [WorktreeInfo(path: repoPath, branch: "", commitHash: "", isMainWorktree: true)]
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
            registerPanes(of: info, project: proj, startedAt: started)
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

        dashboardVC?.updatePanes(buildWorktreeRowInfos())
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

    /// - Parameter changedWorktreePath: when set (single-worktree status change),
    ///   only that worktree kicks an async git-stats refresh; every card still
    ///   reads its cached stats. A full rebuild (nil) refreshes all.
    func buildWorktreeRowInfos(changedWorktreePath: String? = nil) -> [WorktreeRowInfo] {
        let agents = AgentRegistry.shared.allPanes()
        // Index once — the per-agent loop below used to re-filter the full agent
        // list and re-scan allWorktrees for every worktree (O(N²) per rebuild,
        // and this rebuilds on every single-worktree status change).
        let agentsByWorktree = Dictionary(grouping: agents, by: \.worktreePath)
        let worktreeInfoByPath = Dictionary(allWorktrees.map { ($0.info.path, $0.info) },
                                            uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [WorktreeRowInfo] = []

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
            // Every pane's AgentRegistry status, in leaf order — these draw the per-pane
            // dots. The worktree's own status is NOT derived from them here: the
            // aggregator already picked the most recently changed pane, and
            // re-deriving it would let the row and the tab badge disagree.
            let shipLogPaneStatuses = (agentsByWorktree[agent.worktreePath] ?? []).map(\.displayStatus)
            let paneStatuses = !shipLogPaneStatuses.isEmpty ? shipLogPaneStatuses
                : (ws?.statuses ?? [agent.status])
            let rolledUpStatus = ws?.rolledUpStatus ?? agent.status
            let mostRecentMessage = ws?.mostRecentMessage ?? (agent.lastMessage.isEmpty ? "No active task." : agent.lastMessage)
            let mostRecentUserPrompt = ws?.mostRecentUserPrompt ?? agent.lastUserPrompt
            let mostRecentPaneIndex = ws?.mostRecentPaneIndex ?? 1

            let isMain = worktreeInfoByPath[agent.worktreePath]?.isMainWorktree ?? false
            // Card label is the worktree's own name — its directory's last path
            // component — not the branch (the branch is visible inside the
            // terminal). The main worktree always reads as "main".
            let worktreeName = isMain
                ? "main"
                : URL(fileURLWithPath: agent.worktreePath).lastPathComponent

            // "Last activity" age: seconds since the aggregator last saw a real
            // status/message change for this worktree (persisted across launches),
            // falling back to the pane's start time.
            let lastActivity = statusAggregator.lastActivity(for: agent.worktreePath) ?? agent.startedAt
            let lastActivityAge = WorktreeRowHelpers.relativeAge(since: lastActivity)

            // Git summary (diff size + ahead/behind). Served from an 8s cache;
            // kick an off-main refresh so the next build has fresh numbers.
            if changedWorktreePath == nil || changedWorktreePath == agent.worktreePath {
                WorktreeGitStatsCache.shared.refresh(worktreePath: agent.worktreePath)
            }
            let gitStats = WorktreeGitStatsCache.shared.cachedStats(worktreePath: agent.worktreePath)

            // Warm the shared title cache (session summary → task → prompt) so
            // both the cards and the overview rows can read cachedTitle synchronously.
            WorktreeTitleCache.shared.title(worktreePath: agent.worktreePath,
                                            lastUserPrompt: mostRecentUserPrompt,
                                            branch: worktreeName) { _ in }

            // Worktree title = the current (focused) pane, or the most recently
            // active pane when this worktree has no genuine focus.
            let focusedStationId = PaneTitleResolver.focusedStationId(in: tree)
            let focusedPane = PaneTitleResolver.representativePane(
                focusedStationId: focusedStationId,
                among: agentsByWorktree[agent.worktreePath] ?? [],
                fallback: agent
            )
            let currentPaneTitle = PaneTitleResolver.title(for: focusedPane)
            let currentPaneRunTime: String = {
                if focusedPane.status == .running, focusedPane.roundDuration > 0 {
                    return WorktreeRowHelpers.compactDuration(
                        WorktreeRowHelpers.formatDuration(focusedPane.roundDuration))
                }
                return lastActivityAge
            }()

            // Per-pane rows for the expanded "Group by Pane" mode. Aligned to
            // paneStations (leaf order); title/status come from each pane's own
            // AgentRegistry pane, so sibling panes read distinctly.
            let worktreePanes = agentsByWorktree[agent.worktreePath] ?? []
            let panes: [PaneDisplayInfo] = paneStations.map { paneStation in
                let panePane = worktreePanes.first(where: { $0.id == paneStation.id })
                return PaneDisplayInfo(
                    stationId: paneStation.id,
                    title: panePane.map { PaneTitleResolver.title(for: $0) }
                        ?? PaneTitleResolver.shortenPath(agent.worktreePath),
                    status: panePane?.status ?? .unknown,
                    isFocused: paneStation.id == focusedStationId
                )
            }

            // Resolving the titles above wrote each pane's strong title into its
            // Station. Persist the layout when those titles changed since the last
            // save, so a kill/relaunch (dev builds rarely get applicationWill-
            // Terminate) still restores real per-pane titles. Change-gated, so the
            // common no-change poll writes nothing.
            if let tree {
                let signature = paneStations.map { $0.persistedTitle ?? "" }
                if lastSavedPaneTitles[agent.worktreePath] != signature {
                    lastSavedPaneTitles[agent.worktreePath] = signature
                    terminalCoordinator.saveSplitLayout(tree)
                }
            }

            result.append(WorktreeRowInfo(
                id: agent.id,
                name: worktreeName,
                project: agent.project,
                thread: worktreeName,
                paneStatuses: paneStatuses,
                rolledUpStatus: rolledUpStatus,
                mostRecentMessage: mostRecentMessage,
                lastUserPrompt: mostRecentUserPrompt,
                mostRecentPaneIndex: mostRecentPaneIndex,
                totalDuration: WorktreeRowHelpers.formatDuration(agent.totalDuration),
                roundDuration: WorktreeRowHelpers.formatDuration(agent.roundDuration),
                station: station,
                worktreePath: agent.worktreePath,
                paneCount: paneCount,
                paneStations: paneStations,
                isMainWorktree: isMain,
                tasks: agent.tasks,
                activityEvents: agent.activityEvents,
                lastActivityAge: lastActivityAge,
                lastActivityAt: lastActivity,
                gitStats: gitStats,
                currentPaneTitle: currentPaneTitle,
                currentPaneRunTime: currentPaneRunTime,
                panes: panes
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

                // Register all agents with AgentRegistry
                for (info, _) in allWorktreeInfos {
                    let repo = self.worktreeRepoCache[info.path] ?? WorktreeDiscovery.findRepoRoot(from: info.path) ?? info.path
                    let proj = self.workspaceManager.tabs.first(where: { $0.repoPath == repo })?.displayName
                        ?? URL(fileURLWithPath: repo).lastPathComponent
                    let started = self.config.worktreeStartedAt[info.path].flatMap { Self.iso8601.date(from: $0) }
                    self.registerPanes(of: info, project: proj, startedAt: started)
                }
                if !cardOrder.isEmpty {
                    AgentRegistry.shared.reorder(paths: cardOrder)
                }

                self.dashboardVC?.updatePanes(self.buildWorktreeRowInfos())
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
                    self.statusPublisher.webhookProvider.onAgentSessionResolved = { [weak self] worktreePath, paneId, ref in
                        self?.recordAgentSession(worktreePath: worktreePath, paneId: paneId, ref: ref)
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
                        // Set when this Stop is answered with a `decision: block` body.
                        // Held rather than returned early so the event still reaches
                        // ingest — see the blocking branch below.
                        var block: String?
                        // Track when the user sent a message to this session; a new
                        // user prompt starts a fresh turn, so the agent must suggest again.
                        if event.event == .userPrompt {
                            sessionUserPromptedAt[turnKey] = Date()
                            sessionSuggestedAt.removeValue(forKey: turnKey)
                        }
                        // Track per-worktree background-task state (subagent/shell/cron).
                        AgentRegistry.shared.updateBackgroundBusy(from: event)
                        // Drop a (voluntary) suggestion while background work is still running —
                        // the agent will auto-resume, so it isn't a real end-of-turn yet.
                        if event.event == .suggest, AgentRegistry.shared.isBackgroundBusy(cwd: event.cwd) {
                            NSLog("[suggest] DROP background-busy — cwd=\(event.cwd) paneId=\(event.paneId ?? "nil")")
                            return nil
                        }
                        if event.event == .suggest {
                            NSLog("[suggest] pass gate1 (not background-busy) — cwd=\(event.cwd) paneId=\(event.paneId ?? "nil")")
                        }
                        // The agent gave its own suggestions this turn (per the injected
                        // instruction) — record it so the Stop below won't force another.
                        if event.event == .suggest {
                            sessionSuggestedAt[turnKey] = Date()
                        }
                        // Cursor has no last_assistant_message on stop. Always stash
                        // afterAgentResponse `text` as the card summary — even when the
                        // agent forgot the sentinel and already emitted options via a
                        // Shell-invoked seahelm-suggest (that path leaves message="Shell").
                        // Harvest options from the sentinel only when present.
                        if event.event == .assistantResponse,
                           let text = event.data?["text"] as? String {
                            let prose = StopHookResponder.stripSentinel(from: text)
                            if let tid = AgentRegistry.shared.noteAssistantMessage(
                                cwd: event.cwd, paneId: event.paneId, message: prose) {
                                self.pendingOrders.refreshSuggestMessage(
                                    terminalID: tid, message: prose)
                            }
                            if let options = StopHookResponder.parseSuggestions(from: text) {
                                let suggestEvent = WebhookEvent(
                                    source: "seahelm-suggest", sessionId: event.sessionId,
                                    event: .suggest, cwd: event.cwd, timestamp: nil,
                                    data: ["options": options], paneId: event.paneId)
                                self.statusPublisher.webhookProvider.handleEvent(suggestEvent)
                                AgentRegistry.shared.handleWebhookEvent(suggestEvent)
                                sessionSuggestedAt[turnKey] = Date()
                            }
                        }
                        // Suppress the suggestion block when the user sent a message after our
                        // last block — Claude is responding to explicit user direction and doesn't
                        // need suggestion overhead layered on top of the user-directed response.
                        if event.event == .agentStop, sessionSuggestedAt[turnKey] != nil {
                            // The agent already emitted buttons as its last action this
                            // turn — no forced block needed (no extra round-trip).
                            sessionSuggestedAt.removeValue(forKey: turnKey)
                        } else if event.event == .agentStop,
                                  let msg = event.data?["last_assistant_message"] as? String,
                                  let options = StopHookResponder.parseSuggestions(from: msg) {
                            // Direction 3: the agent declared its next-step options as a
                            // final plain-text line (per the injected instruction). They
                            // ride this Stop hook's own round-trip — no seahelm-suggest tool
                            // call — so the answer prose is never left before a trailing
                            // tool_use for the TUI to swallow. Surface the buttons here, then
                            // let the Stop fall through to normal completion below.
                            AgentRegistry.shared.noteAssistantMessage(
                                cwd: event.cwd, paneId: event.paneId,
                                message: StopHookResponder.stripSentinel(from: msg))
                            let suggestEvent = WebhookEvent(
                                source: "seahelm-suggest", sessionId: event.sessionId,
                                event: .suggest, cwd: event.cwd, timestamp: nil,
                                data: ["options": options], paneId: event.paneId)
                            self.statusPublisher.webhookProvider.handleEvent(suggestEvent)
                            AgentRegistry.shared.handleWebhookEvent(suggestEvent)
                            sessionSuggestedAt[turnKey] = Date()
                        } else if event.event == .agentStop,
                           let blockedAt = sessionBlockedAt[turnKey],
                           let promptedAt = sessionUserPromptedAt[turnKey],
                           promptedAt > blockedAt {
                            sessionBlockedAt.removeValue(forKey: turnKey)
                            sessionUserPromptedAt.removeValue(forKey: turnKey)
                        } else if let body = StopHookResponder.blockBody(
                            for: event, suggestOnStop: self.config.webhook.suggestOnStop) {
                            // Blocking Stop: the agent will continue and declare its
                            // options. Stash its final message so the suggestion card
                            // can show it, and remember that we blocked.
                            sessionBlockedAt[turnKey] = Date()
                            if let msg = event.data?["last_assistant_message"] as? String {
                                AgentRegistry.shared.noteAssistantMessage(cwd: event.cwd, paneId: event.paneId, message: msg)
                            }
                            // Fall through to ingest: the turn is over as far as the user
                            // is concerned — the agent has written its answer — and the
                            // extra round-trip this block buys is seahelm's own suggestion
                            // overhead. Withholding the stop here used to delay every
                            // completion (status, banner, chat mirror) by a whole model
                            // round-trip: 2.6s to 20s, median ~9s, measured across real
                            // sessions. The agent's follow-up turn re-reports running and
                            // stops again; the notification cooldown collapses that pair.
                            block = body
                        }
                        self.statusPublisher.webhookProvider.handleEvent(event)
                        AgentRegistry.shared.handleWebhookEvent(event)
                        // TODO: Enable when webhook→TODO matching logic is implemented
                        // AgentRegistry.shared.updateTodoFromWebhook(event)
                        return block
                      }
                    }
                    // Local control socket is the sole inbound transport: reads
                    // (snapshot/read) + the shared event sink for hook/suggest.
                    // (The HTTP webhook was retired once the socket path was
                    // verified end-to-end.)
                    let controlDataSource = SeahelmControlDataSource(hookSink: handleEvent)
                    self.mailPaneRouter = MailPaneRouter(control: controlDataSource, store: self.mailConversationStore, accountEmail: self.config.gmailMail?.accountEmail)
                    self.mailPaneRouter?.commandContext = self.mailCommandContext
                    if let account = self.config.gmailMail?.accountEmail {
                        let sender = GmailRESTMailSender(account: account)
                        self.mailPaneObserver.onIntent = { intent, commander in
                            sender.send(intent, to: commander?.isEmpty == false ? commander! : account) { _ in }
                        }
                        // Command replies ride the same in-thread sender as
                        // status mail, but skip the intent store: a reply is
                        // already idempotent per inbound mail, and persisting
                        // one would have it retried after it was answered.
                        // Echo the subject the thread already carries. Gmail
                        // threads on `threadId`, but clients group on subject
                        // too, and nothing parses it any more — the recipient
                        // alias is the whole gate.
                        self.mailPaneRouter?.onReply = { body, threadID, subject, replyTo in
                            let replySubject = subject.isEmpty ? "Seahelm"
                                : (subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)")
                            sender.send(OutboundMailIntent(id: UUID().uuidString, threadID: threadID, paneSessionKey: "",
                                                           sequence: 0, kind: .reply, subject: replySubject,
                                                           body: body, state: "pending"),
                                        to: replyTo.isEmpty ? account : replyTo) { _ in }
                        }
                    }
                    controlDataSource.splitHandler = { [weak self] targetStationId, axis, focus in
                        self?.terminalCoordinator.splitPane(targetStationId: targetStationId, axis: axis, focus: focus)
                    }
                    controlDataSource.closeHandler = { [weak self] stationId in
                        self?.terminalCoordinator.closePane(targetStationId: stationId) ?? false
                    }
                    controlDataSource.focusHandler = { [weak self] stationId in
                        self?.terminalCoordinator.focusPane(targetStationId: stationId) ?? false
                    }
                    controlDataSource.sleepHandler = { [weak self] stationId in
                        self?.terminalCoordinator.sleepPane(targetStationId: stationId) ?? []
                    }
                    controlDataSource.wakeHandler = { [weak self] stationId in
                        self?.terminalCoordinator.wakePane(targetStationId: stationId) ?? []
                    }
                    controlDataSource.dismissDecisionHandler = { [weak self] paneId in
                        // Station id or the stable session key — the queue keys off the
                        // former, remote callers usually hold the latter.
                        guard let self else { return false }
                        let stationId = StationRegistry.shared.station(forSessionName: paneId)?.id ?? paneId
                        return self.pendingOrders.dismissSuggestion(terminalID: stationId)
                    }
                    controlDataSource.liveLayoutsHandler = { [weak self] in
                        self?.terminalCoordinator.liveLayouts() ?? [:]
                    }
                    controlDataSource.worktreeGroupsHandler = { [weak self] mode in
                        self?.worktreeGroups(mode: mode) ?? []
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
                    // start() unlinks the socket path before binding, so starting
                    // here would steal the live app's socket out from under it.
                    if !DebugFlags.forceEmptyState {
                        control.start()
                        self.terminalCoordinator.controlSocketServer = control
                        // Host Gateway shares the control socket's dataSource.
                        self.mqttDataSource = controlDataSource
                        self.setupHostGateway(dataSource: controlDataSource)
                    }
                }
            }
        }
    }

    /// Localhost WebSocket gateway for browser clients when `config.hostGateway` is enabled.
    private func setupHostGateway(dataSource: ControlDataSource) {
        guard config.hostGateway?.resolvedEnabled == true else { return }
        guard hostGatewayServer == nil else { return }
        guard let hgConfig = config.hostGateway else { return }

        if config.mqtt == nil { config.mqtt = MqttConfig(host: "localhost") }
        let mqtt = config.mqtt!
        let macId = mqtt.macId ?? MqttConfig.deriveMacId()
        let rootB64 = mqtt.rootSecret ?? ""

        let vt = ZmxVTAttachManager()
        zmxVTAttachManager = vt
        let server = HostGatewayServer(
            config: hgConfig,
            router: ControlRouter(dataSource: dataSource),
            expectedMacId: macId,
            rootSecretBase64url: rootB64,
            vt: vt)
        server.start()
        hostGatewayServer = server
        NSLog("[TabCoordinator] Host Gateway started port=\(hgConfig.resolvedPort) pair=\(hgConfig.resolvedPublicURL)")
    }

    private func stopHostGateway() {
        hostGatewayServer?.stop()
        hostGatewayServer = nil
        zmxVTAttachManager = nil
    }

    func teardownRemoteBackends() {
        stopHostGateway()
    }

    /// Rebuild the gateway after pairing mints a new root secret.
    private func reloadHostGateway() {
        stopHostGateway()
        if let ds = mqttDataSource { setupHostGateway(dataSource: ds) }
    }

    /// Apply a freshly-minted pairing secret to the *live* config and reload
    /// Host Gateway so auth picks up the new root — no app restart needed.
    func applyMqttRootSecret(_ secret: String) {
        if config.mqtt == nil { config.mqtt = MqttConfig(host: "localhost") }
        config.mqtt?.rootSecret = secret
        reloadHostGateway()
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

                registerPanes(of: info, project: proj, startedAt: Date())
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

        dashboardVC?.updatePanes(buildWorktreeRowInfos())
        statusPublisher.updateSurfaces(terminalCoordinator.stationManager.all)
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
    }

    // MARK: - Worktree Auto-Discovery (via Agent Hooks)

    /// Persist an agent resume ref and apply it to the live station so a
    /// mid-session zmx recovery can relaunch the agent. Called on the main thread.
    ///
    /// Routed to the *emitting* pane's own station (via `paneId`, the hook's
    /// SEAHELM_PANE_ID = the pane's session name). Applying it to the worktree's
    /// primary station instead let sibling agents in one worktree stomp a single
    /// shared ref, so the primary pane's resolved title flipped to whichever
    /// agent hooked last. Persisting under the pane's own session name also lets
    /// restore reapply it — `config.agentSessions` is read back keyed by
    /// `leaf.paneSessionKey`, which the old worktree-scoped key never matched.
    /// Falls back to the primary station / worktree name for legacy hooks that
    /// carry no paneId.
    private func recordAgentSession(worktreePath: String, paneId: String?, ref: AgentSessionRef) {
        let station = paneId.flatMap { StationRegistry.shared.station(forSessionName: $0) }
            ?? terminalCoordinator.stationManager.primaryStation(forPath: worktreePath)
        station?.agentSessionRef = ref
        // Prefer the resolved pane's own session name (matches restore); fall back
        // to the raw paneId, then the worktree-scoped name.
        let key = station?.paneSessionKey ?? paneId
            ?? SessionManager.persistentSessionName(for: worktreePath)
        // Write to the authoritative (TerminalCoordinator) copy, then persist.
        guard terminalCoordinator.config.agentSessions[key] != ref else { return }
        terminalCoordinator.config.agentSessions[key] = ref
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
            } else if Self.isEphemeralRepoPath(repoRoot) {
                // An agent that clones into $TMPDIR to build and cd's there would
                // otherwise join that clone to the workspace permanently.
                NSLog("[TabCoordinator] Ignoring ephemeral repo from hook: \(repoRoot)")
            } else {
                NSLog("[TabCoordinator] Auto-adding new repo via hook: \(repoRoot)")
                self.addRepo(at: repoRoot)
            }
        }
    }

    /// Directories the OS hands out for throwaway work. Auto-add is driven by an
    /// agent's cwd, so a repo cloned into one is disposable by construction — and
    /// `workspacePaths` is never pruned, so adding it strands a card that outlives
    /// the directory itself (discovery then synthesizes a fake main worktree for it).
    /// Only the hook-driven path consults this; an explicit Add Repo is the user's call.
    static func isEphemeralRepoPath(_ path: String) -> Bool {
        // Foundation's resolvingSymlinksInPath deliberately leaves "/var" and
        // "/tmp" unresolved, while real cwds (hook payloads, $TMPDIR) often
        // arrive as "/private/var/...". Strip the "/private" prefix on both
        // sides so the two spellings of the same directory always match.
        func normalize(_ p: String) -> String {
            let canon = WorktreeDiscovery.canonicalPath(p)
            return canon.hasPrefix("/private/") ? String(canon.dropFirst("/private".count)) : canon
        }
        let canon = normalize(path)
        var roots = ["/tmp", "/var/folders", "/var/tmp"].map(normalize)
        roots.append(normalize(NSTemporaryDirectory()))
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(normalize(caches.path))
        }
        return roots.contains { canon == $0 || canon.hasPrefix($0 + "/") }
    }

    private func performPaneTransfer(transfer: PendingWorktreeTransfer, newInfo: WorktreeInfo, repoRoot: String, project: String, allDiscoveredWorktrees: [WorktreeInfo]) {
        let sourcePath = transfer.sourceWorktreePath
        // Capture the source's own info before step 2 drops it. Step 6 restores the
        // source from `allDiscoveredWorktrees`, but that list only covers `repoRoot`
        // — the *new* worktree's repo. Transfers are matched by worktree name alone
        // (a worktree may be created at any sibling path), so a name collision can
        // pair this new worktree with a source in a *different* repo, and then the
        // lookup finds nothing and the source is destroyed with no way back until
        // relaunch. Falling back to the captured info keeps that unrecoverable.
        let sourceEntryInfo = allWorktrees.first(where: { $0.info.path == sourcePath })?.info
        // The source keeps its OWN repo/project — `repoRoot` and `project` describe
        // the new worktree, which is only the same repo when no cross-repo name
        // collision routed us here.
        let sourceRepo = worktreeRepoCache[sourcePath] ?? repoRoot

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

        // 3. Re-register transferred surfaces in AgentRegistry under new worktree
        // Unregister all old agents for the source path first
        while let oldAgent = AgentRegistry.shared.pane(forWorktree: sourcePath) {
            AgentRegistry.shared.unregister(terminalID: oldAgent.id)
        }
        for leaf in transferredTree.allLeaves {
            if let station = StationRegistry.shared.station(forId: leaf.stationId) {
                // zmx has no rename, so the session keeps its original (source-derived)
                // name. Register with that real name — NOT persistentSessionName(for:
                // newInfo.path), which would build a channel to a nonexistent session
                // and let the orphan-reaper reap the live one.
                let paneSessionKey = runtimeBackend == "local" ? nil : leaf.paneSessionKey
                AgentRegistry.shared.register(station: station, worktreePath: newInfo.path, branch: newInfo.branch, project: project, startedAt: Date(), paneSessionKey: paneSessionKey, backend: runtimeBackend)
            }
        }

        // 4. Save the transferred tree's layout under the new path, remove old
        terminalCoordinator.config.splitLayouts.removeValue(forKey: sourcePath)
        terminalCoordinator.saveSplitLayout(transferredTree)

        // 5. Invalidate the old split container so the UI rebuilds it
        dashboardVC?.invalidateSplitContainer(forPath: sourcePath)

        // 6. Create a fresh tree for the source worktree (e.g., main)
        let rediscoveredSource = allDiscoveredWorktrees.first(where: {
            WorktreeDiscovery.canonicalPath($0.path) == WorktreeDiscovery.canonicalPath(sourcePath)
        })
        if rediscoveredSource == nil, sourceEntryInfo != nil {
            NSLog("[TabCoordinator] Transfer source \(sourcePath) absent from \(repoRoot) discovery — restoring from its tracked info")
        }
        if let sourceInfo = rediscoveredSource ?? sourceEntryInfo {
            let freshTree = terminalCoordinator.stationManager.tree(for: sourceInfo, backend: runtimeBackend)
            if let idx = allWorktrees.firstIndex(where: { $0.info.path == sourceInfo.path }) {
                allWorktrees[idx] = (info: sourceInfo, tree: freshTree)
            } else {
                allWorktrees.append((info: sourceInfo, tree: freshTree))
            }
            worktreeRepoCache[sourceInfo.path] = sourceRepo
            let sourceProject = workspaceManager.tabs.first(where: { $0.repoPath == sourceRepo })?.displayName
                ?? URL(fileURLWithPath: sourceRepo).lastPathComponent
            let paneSessionKey = runtimeBackend == "local" ? nil : SessionManager.persistentSessionName(for: sourceInfo.path)
            if let surface = terminalCoordinator.stationManager.primaryStation(forPath: sourceInfo.path) {
                AgentRegistry.shared.register(station: surface, worktreePath: sourceInfo.path, branch: sourceInfo.branch, project: sourceProject, startedAt: Date(), paneSessionKey: paneSessionKey, backend: runtimeBackend)
            }
            terminalCoordinator.saveSplitLayout(freshTree)
        }
    }

    // MARK: - Worktree Lifecycle

    func worktreeDidDelete(_ info: WorktreeInfo) {
        // Idempotent surface teardown: every current caller already removed the
        // tree, but destroying here too means a future call path can't leak the
        // worktree's stations (removeTree on a missing path is a no-op).
        _ = terminalCoordinator.stationManager.removeTree(forPath: info.path)
        let repoPath = worktreeRepoCache[info.path]
        allWorktrees.removeAll { $0.info.path == info.path }
        worktreeRepoCache.removeValue(forKey: info.path)
        if let repoPath,
           let tabIndex = workspaceManager.tabs.firstIndex(where: { $0.repoPath == repoPath }) {
            let remaining = workspaceManager.tabs[tabIndex].worktrees.filter { $0.path != info.path }
            workspaceManager.updateWorktrees(at: tabIndex, worktrees: remaining)
        }
        // Unregister EVERY pane of the worktree (split worktrees have N agents;
        // taking just the first leaked the rest for the app's lifetime).
        for terminalID in AgentRegistry.shared.terminalIDs(forWorktree: info.path) {
            AgentRegistry.shared.unregister(terminalID: terminalID)
        }
        WorktreeTitleCache.shared.evict(worktreePath: info.path)
        WorktreeGitStatsCache.shared.evict(worktreePath: info.path)
        dashboardVC?.invalidateSplitContainer(forPath: info.path)
        dashboardVC?.updatePanes(buildWorktreeRowInfos())
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

            // Unregister EVERY pane of the worktree, not just the first pane.
            let ids = AgentRegistry.shared.terminalIDs(forWorktree: worktree.path)
            if ids.isEmpty, let primaryStation {
                AgentRegistry.shared.unregister(terminalID: primaryStation.id)
            } else {
                for id in ids { AgentRegistry.shared.unregister(terminalID: id) }
            }
            WorktreeTitleCache.shared.evict(worktreePath: worktree.path)
            WorktreeGitStatsCache.shared.evict(worktreePath: worktree.path)
            if runtimeBackend != "local" {
                let paneSessionKey = SessionManager.persistentSessionName(for: worktree.path)
                SessionManager.killSession(paneSessionKey, backend: runtimeBackend)
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

        dashboardVC?.updatePanes(buildWorktreeRowInfos())
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

    private var branchRefreshTick = 0
    /// Every 2nd tick of the 5s timer, i.e. 10s. This is the *only* thing that
    /// advances the seconds-resolution elapsed labels (AgentRegistry stopped fanning
    /// out on roundDuration ticks), so a slower cadence reads as a frozen
    /// counter. `buildWorktreeRowInfos` is cache-served and the render it
    /// feeds is now incremental, so the tick is cheap enough to keep at 10s.
    private static let elapsedRefreshEveryTicks = 2

    static func shouldRefreshDashboardElapsedTime(tick: Int) -> Bool {
        guard tick > 0 else { return false }
        return tick % elapsedRefreshEveryTicks == 0
    }

    func startBranchRefreshTimer() {
        branchRefreshTimer?.invalidate()
        branchRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.branchRefreshTick += 1
            self.refreshBranches()
            // Re-evaluate worktree-tab idle collapse even when nothing changed.
            self.delegate?.tabCoordinatorRequestUpdateTitleBar(self)
            // AgentRegistry no longer fans out on roundDuration ticks (see
            // displayedStateUnchanged), so elapsed-time and activity-age labels
            // are advanced here at a gentle cadence while anything is running.
            if Self.shouldRefreshDashboardElapsedTime(tick: self.branchRefreshTick),
               AgentRegistry.shared.allPanes().contains(where: { $0.status == .running }) {
                self.dashboardVC?.updatePanes(self.buildWorktreeRowInfos())
            }
            // Rides this timer rather than starting its own: the policy only
            // needs to notice minutes-scale absences, and a 5s tick is already
            // far finer than that.
            if self.config.autoSleep.enabled {
                self.terminalCoordinator?.sleepIdleOffscreenPanes(
                    idleAfter: self.config.autoSleep.effectiveAfterSeconds
                )
            }
        }
    }

    private func refreshBranches() {
        let tabs = workspaceManager.tabs
        // The active tab refreshes every tick (5s); background tabs only every
        // 6th tick (30s) — each refresh forks a `git worktree list` subprocess
        // per repo, so polling every open repo at 5s is wasteful.
        let refreshAll = branchRefreshTick % 6 == 0
        for (tabIndex, tab) in tabs.enumerated() {
            guard refreshAll || tabIndex == activeTabIndex else { continue }
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
        let freshPaths = Set(freshWorktrees.map { WorktreeDiscovery.canonicalPath($0.path) })
        let absent = oldWorktrees.filter { !freshPaths.contains(WorktreeDiscovery.canonicalPath($0.path)) }

        // Absent from `git worktree list` is not proof of deletion — a partial or
        // degraded listing (repo mid-write, a hiccup on a removable volume) drops
        // live entries. Deleting on that evidence destroys the worktree's stations
        // and its dashboard card until relaunch. Only act when the directory is
        // *definitively* gone; `missingPaths` never reports an unreachable path.
        let deletedWorktrees: [WorktreeInfo]
        if absent.isEmpty {
            deletedWorktrees = []
        } else {
            let missing = FileSystemProbe.missingPaths(from: absent.map(\.path))
            deletedWorktrees = absent.filter { missing.contains($0.path) }
            for kept in absent where !missing.contains(kept.path) {
                NSLog("[TabCoordinator] \(kept.path) missing from git worktree list but still on disk — keeping")
            }
        }

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
        dashboardVC?.updatePanes(buildWorktreeRowInfos())
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
        if let agent = selectedPane {
            config.selectedWorktreePath = agent.worktreePath
            saveConfig()
        }
    }

    func restoreSessionState() {
        // Restore selected agent card from config. Use commitWorktreeSelection
        // (not selectPane) so the left "First mate" overview selection stays in
        // sync with the right-hand terminal — selectPane moves only the terminal,
        // leaving the overview highlight on the first row and mismatched on launch.
        if let savedPath = config.selectedWorktreePath {
            dashboardVC?.commitWorktreeSelection(path: savedPath, focusTerminal: true)
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
        guard let agent = AgentRegistry.shared.pane(for: terminalID) else { return }
        let worktreePath = agent.worktreePath
        guard let item = allWorktrees.first(where: { $0.info.path == worktreePath }) else { return }
        terminalCoordinator.confirmAndDeleteWorktree(item.info, window: window)
    }

    func dashboardDidRequestDeleteWithBranch(_ terminalID: String, window: NSWindow?) {
        guard let agent = AgentRegistry.shared.pane(for: terminalID) else { return }
        let worktreePath = agent.worktreePath
        guard let item = allWorktrees.first(where: { $0.info.path == worktreePath }) else { return }
        terminalCoordinator.confirmAndDeleteWorktree(item.info, window: window, preferredDeleteBranch: true)
    }

    // MARK: - New Branch Integration

    func handleNewBranch(info: WorktreeInfo, repoPath: String) {
        // Build the full worktree list for this repo (existing + newly created)
        // so integrateNewWorktrees can update workspaceManager correctly.
        let existing = workspaceManager.tabs.first(where: { $0.repoPath == repoPath })?.worktrees ?? []
        let allDiscovered = existing + [info]

        integrateNewWorktrees(repoRoot: repoPath, allDiscovered: allDiscovered, newWorktrees: [info])

        Analytics.trackWorktreeCreated(totalCount: allWorktrees.count)

        // Focus the newly created worktree's minicard
        dashboardVC?.selectPane(byWorktreePath: info.path)
    }

    // MARK: - Status Update Forwarding

    func handleWorktreeStatusUpdate(_ status: WorktreeStatus) {
        dashboardVC?.updatePanes(buildWorktreeRowInfos(changedWorktreePath: status.worktreePath),
                                   changedWorktreePath: status.worktreePath)
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
    }

    func handlePaneStatusChange(worktreePath: String, paneIndex: Int, oldStatus: AgentStatus, newStatus: AgentStatus, lastMessage: String) {
        // Cache miss means a synchronous `git rev-parse` (up to 5s on a wedged
        // repo) — resolve off-thread, then deliver the notification on main.
        guard let repoPath = worktreeRepoCache[worktreePath] else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let resolved = WorktreeDiscovery.findRepoRoot(from: worktreePath) ?? worktreePath
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.worktreeRepoCache[worktreePath] = resolved
                    self.deliverPaneStatusChange(worktreePath: worktreePath, paneIndex: paneIndex,
                                                 oldStatus: oldStatus, newStatus: newStatus,
                                                 lastMessage: lastMessage, repoPath: resolved)
                }
            }
            return
        }
        deliverPaneStatusChange(worktreePath: worktreePath, paneIndex: paneIndex,
                                oldStatus: oldStatus, newStatus: newStatus,
                                lastMessage: lastMessage, repoPath: repoPath)
    }

    private func deliverPaneStatusChange(worktreePath: String, paneIndex: Int, oldStatus: AgentStatus,
                                         newStatus: AgentStatus, lastMessage: String, repoPath: String) {
        let branch = allWorktrees.first(where: { $0.info.path == worktreePath })?.info.branch ?? ""
        let workspaceName = workspaceManager.tabs.first(where: { $0.repoPath == repoPath })?.displayName
            ?? URL(fileURLWithPath: repoPath).lastPathComponent
        let worktreeStatus = statusAggregator.status(for: worktreePath)
        let paneCount = worktreeStatus?.panes.count ?? 1
        let paneStatus = worktreeStatus?.panes.first(where: { $0.paneIndex == paneIndex })
        let terminalID = paneStatus?.terminalID ?? ""
        let lastUserPrompt = paneStatus?.lastUserPrompt ?? ""
        // The agent's final prose (Stop hook) — the most informative body line;
        // without it completed panes surface placeholder labels like
        // "Processing prompt".
        let pane = AgentRegistry.shared.pane(for: terminalID)
        let lastAssistantMessage = pane?.lastAssistantMessage ?? ""
        // Did the agent report this itself, or did the screen scan infer it? Only
        // an agent-reported state is trusted enough to correct a banner already
        // sent inside the cooldown window — see `NotificationManager.shouldNotify`.
        let source: NotificationManager.NotificationSource =
            pane?.hookStatus == newStatus ? .agent : .scan

        // A pending order card (AskUserQuestion / suggestion) for this pane
        // already surfaces the "needs input" state in the island and cockpit —
        // a banner + history entry on top of the card is the same event shown
        // twice. Errors and completions still notify.
        if newStatus == .waiting, !terminalID.isEmpty,
           pendingOrders.all().contains(where: { $0.action.terminalID == terminalID }) {
            return
        }

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
            lastAssistantMessage: lastAssistantMessage,
            isTargetVisible: isPaneFocused(worktreePath: worktreePath, terminalID: terminalID),
            source: source
        )
    }

    /// Whether this worktree is the one currently shown in the dashboard (all its
    /// panes are on screen). Combined with app-frontmost in `NotificationManager`
    /// to decide whether a system banner would be redundant, and by the island /
    /// First Mate reveal to decide which of the two surfaces a suggestion belongs on.
    func isWorktreeVisible(_ worktreePath: String) -> Bool {
        dashboardVC?.activeSplitContainer?.tree?.worktreePath == worktreePath
    }

    /// Register every pane of a worktree's tree with AgentRegistry — not just the first.
    /// A pane missing here cannot be resolved from its hook's SEAHELM_PANE_ID
    /// (`AgentRegistry.handleWebhookEvent` only accepts a station that is a known agent),
    /// so its events — and any suggestion chip tapped for it — silently fall back
    /// to the worktree's FIRST pane. Restored splits are the common case: every
    /// pane comes back through here on launch, not through the split path.
    /// Each leaf registers under its own `paneSessionKey`, which is exactly what that
    /// pane exports as SEAHELM_PANE_ID.
    private func registerPanes(of info: WorktreeInfo, project: String, startedAt: Date?) {
        guard let tree = terminalCoordinator.stationManager.tree(forPath: info.path) else { return }
        for leaf in tree.allLeaves {
            guard let station = StationRegistry.shared.station(forId: leaf.stationId) else { continue }
            AgentRegistry.shared.register(
                station: station, worktreePath: info.path, branch: info.branch,
                project: project, startedAt: startedAt,
                paneSessionKey: runtimeBackend == "local" ? nil : leaf.paneSessionKey,
                backend: runtimeBackend)
        }
    }

    /// Pane-level visibility: a banner is redundant only when THIS pane is the
    /// focused pane of the on-screen worktree. Any other pane — including a
    /// sibling split of the same worktree — still notifies, so an agent
    /// finishing in a pane you're not looking at never goes silent.
    private func isPaneFocused(worktreePath: String, terminalID: String) -> Bool {
        guard let tree = dashboardVC?.activeSplitContainer?.tree,
              tree.worktreePath == worktreePath else { return false }
        // No pane identity (shouldn't happen on the pane path) — fall back to
        // worktree-level visibility.
        guard !terminalID.isEmpty else { return true }
        guard let focused = tree.allLeaves.first(where: { $0.id == tree.focusedId }) else { return false }
        return focused.stationId == terminalID
    }

    // MARK: - Tab Selection

    static func tabIndex(forWorktree path: String, in paths: [String]) -> Int? {
        paths.firstIndex(of: path)
    }

    func selectTab(forWorktree path: String) {
        dashboardVC?.selectPane(byWorktreePath: path)
        saveSelectedWorktree()
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
    }

    /// `⌃⇥` / `⌃⇧⇥`. Same as `selectTab(forWorktree:)` plus the fleet-list
    /// highlight, which `selectPane` alone leaves on the previous worktree.
    func cycleTab(toWorktree path: String) {
        dashboardVC?.enterWorktree(byWorktreePath: path)
        saveSelectedWorktree()
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
    }

    /// Session names currently attached to panes that exist in the live split
    /// trees. Cleanup code uses this as the source of truth: if a zmx session is
    /// not in this set, no pane is using it right now.
    func livePaneSessionNames() -> Set<String> {
        guard runtimeBackend == "zmx" else { return [] }
        guard allConfiguredReposAreRepresented() else {
            NSLog("[TabCoordinator] Withholding live pane sessions — a configured repo has no worktrees")
            return []
        }
        let names = allWorktrees.flatMap { entry in
            entry.tree.allLeaves.map(\.paneSessionKey)
        }
        return Set(names.filter { !$0.isEmpty })
    }

    /// Whether every configured repo contributed at least one worktree to
    /// `allWorktrees`. A repo always has its main worktree, so a repo with none
    /// means discovery never landed — git lock, unmounted volume, a path that
    /// vanished. Its panes are live but absent from the trees above, and callers
    /// treat this set as authoritative, so a partial answer would have the
    /// orphan sweep force-kill those sessions with their agents inside. Both
    /// callers skip on an empty set, which is the safe direction to fail.
    private func allConfiguredReposAreRepresented() -> Bool {
        let represented = Set(allWorktrees.compactMap { entry in
            worktreeRepoCache[entry.info.path].map(WorktreeDiscovery.canonicalPath)
        })
        return config.workspacePaths.allSatisfy {
            represented.contains(WorktreeDiscovery.canonicalPath($0))
        }
    }

    // MARK: - Navigation

    func handleNavigateToWorktree(worktreePath: String, paneIndex: Int?) {
        // Navigation is now handled by the dashboard — select the matching agent card.
        // If the worktree is already known, the dashboard will show it in the focus panel.
        // If not yet tracked, discover and add it first.
        if workspaceManager.tabs.contains(where: { tab in
            tab.worktrees.contains(where: { $0.path == worktreePath })
        }) {
            dashboardVC?.updatePanes(buildWorktreeRowInfos())
            // enterWorktree (not selectPane): it also moves the overview
            // list's selection highlight to the target row.
            dashboardVC?.enterWorktree(byWorktreePath: worktreePath)
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
                    self?.dashboardVC?.enterWorktree(byWorktreePath: worktreePath)
                    self?.saveSelectedWorktree()
                    if let self {
                        self.delegate?.tabCoordinatorRequestUpdateTitleBar(self)
                    }
                }
            }
        }
    }
}

extension TabCoordinator {
    func routeMail(message: GmailInboundMessage) {
        mailPaneRouter?.route(message: message, text: message.bodyText)
    }
    func closeMailPane(paneID: String) -> EmailConversation? { mailPaneRouter?.close(paneID: paneID) }
}

extension TabCoordinator {
    /// Deadline for one FirstMate inspection command (a test suite, a build, a
    /// lint pass). Generous, but bounded — a hung command must not park a
    /// background thread for the rest of the session.
    static let inspectionCommandTimeout: TimeInterval = 15 * 60

    /// Deadline for the auto-commit pair. Wide enough for a big `add -A` plus
    /// whatever pre-commit hooks the repo installs.
    static let autoCommitTimeout: TimeInterval = 5 * 60

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
                // A user-configured inspection command is a whole test/lint run:
                // unbounded output (which is why it must not be read only after
                // exit) and minutes of runtime, so it gets a far wider deadline
                // than the quick lookups.
                let rawOutput = ProcessRunner.output(
                    ["bash", "-lc", "cd \(worktreePath.shellQuoted) && \(cmd)"],
                    timeout: Self.inspectionCommandTimeout
                )
                if rawOutput == nil && firstFailedCmd == nil { firstFailedCmd = cmd }
                results.append("[\(cmd)]\n\(rawOutput ?? "(failed)")")
            }
            let combined = results.joined(separator: "\n---\n")
            let passed = firstFailedCmd == nil

            var commitResult: String? = nil
            if isAutoCommit {
                // `add -A` walks the whole tree and `commit` runs the repo's
                // pre-commit hooks, so neither fits the default quick-lookup
                // deadline.
                _ = ProcessRunner.output(
                    ["git", "-C", worktreePath, "add", "-A"],
                    timeout: Self.autoCommitTimeout
                )
                let commitOut = ProcessRunner.output(
                    ["git", "-C", worktreePath, "commit", "-m", "seahelm: auto-commit after agent completion"],
                    timeout: Self.autoCommitTimeout
                )
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
                        ? "Inspection passed · review ready (launch manually)"
                        : "Inspection passed"
                } else {
                    watchMsg = "Inspection failed: \(firstFailedCmd!)"
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

// MARK: - Remote grouping

extension TabCoordinator {
    /// The dashboard's own grouping, computed here and shipped as data.
    ///
    /// Remote clients render these groups verbatim; re-implementing the rules on
    /// the far side is what would let the browser and the desktop disagree.
    func worktreeGroups(mode: String) -> [[String: Any]] {
        let items = buildWorktreeRowInfos().map {
            $0.groupingItem(creationDate: DashboardOverviewView.creationDate($0.worktreePath))
        }
        return WorktreeGrouping
            .groups(items, mode: WorktreeGroupingMode(wire: mode), now: Date())
            .map(\.dict)
    }
}
