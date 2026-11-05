import AppKit

protocol TabCoordinatorDelegate: AnyObject {
    func tabCoordinator(_ coordinator: TabCoordinator, embedViewController vc: NSViewController)
    func tabCoordinatorDidSwitchTab(_ coordinator: TabCoordinator)
    func tabCoordinatorRequestUpdateTitleBar(_ coordinator: TabCoordinator)
    func tabCoordinatorRequestShowNewBranchDialog(_ coordinator: TabCoordinator)
    func tabCoordinatorRequestClearContentContainer(_ coordinator: TabCoordinator)
    /// Worktrees that discovery used to list and no longer does — removed
    /// outside seahelm, which for the `.worktrees/` checkouts an agent makes
    /// and unmakes itself is the normal way they go. The deletion paths inside
    /// the app report themselves; this is the only word anyone gets about the
    /// rest.
    func tabCoordinator(_ coordinator: TabCoordinator, worktreesDidVanish paths: [String])
}

class TabCoordinator {
    weak var delegate: TabCoordinatorDelegate?
    var config: Config
    let workspaceManager = WorkspaceManager()

    /// The live control data source: the pane lookup + write channel the
    /// window reads pane snapshots through.
    private(set) var controlDataSource: ControlDataSource?

    var activeTabIndex: Int = 0
    /// Every worktree across all repos. `tree` is optional because the tree is
    /// owned by `StationManager`, not by this list, and a worktree can be between
    /// trees — a pane move unkeys the source's before its replacement is built.
    var allWorktrees: [(info: WorktreeInfo, tree: SplitTree?)] = []
    /// Keeps each repo's integration checkout current as agents finish turns.
    /// Nil until `init` builds it; only acts on repos that already have one.
    private var integration: IntegrationCoordinator?
    var worktreeRepoCache: [String: String] = [:]
    /// First Mate: the LLM pane rules wake up.
    let firstMate = FirstMateLink()

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
    var statusAggregator: WorktreeStatusAggregator!
    var runtimeBackend: String = "local"
    /// Set by the window: start a worktree (task, repo, agent) the way the
    /// desktop does, calling back with its path or nil. Lets the control API —
    /// the web client's composer — start work too.
    var worktreeCreator: ((String, String, AgentType, @escaping (String?) -> Void) -> Void)?
    /// Answers a question card as a tap on it would (owner-set: the window
    /// controller drives the dialog). Remote clients answer through this so a
    /// multi-select or multi-question ask behaves as it does on the desktop.
    /// Answers one of First Mate's cards as a tap on it would (owner-set).
    // First Mate — status-transition engine + red-zone queue + green-zone watch
    /// The core's cards, as the island, Telegram and the web show them.
    let cards = CardDeck()

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
        }
        // MainWindow owns chrome layout; when saving from here, those fields on
        // `config` may be stale — leave them alone unless the caller updated them.
        config.save()
    }

    init(config: Config) {
        self.config = config
        integration = IntegrationCoordinator(
            isEnabled: { [weak self] in
                guard let self else { return false }
                return self.config.integrationEnabled && self.config.autoIntegrate
            },
            // Same reason as `worktrees` below: a worktree we already track
            // names its repo without asking git. The fallback covers a path
            // discovery has not filed yet.
            repoRoot: { [weak self] path in
                self?.workspaceManager.tabs
                    .first(where: { $0.worktrees.contains(where: { $0.path == path }) })?.repoPath
                    ?? WorktreeDiscovery.findRepoRoot(from: path)
            },
            // `workspaceManager` already files every worktree under the repo it
            // belongs to, so answering from it is both exact and free. Asking
            // git instead — once per worktree, on the main thread, every
            // integration round — is what pinned the main thread at 78% inside
            // `posix_spawn`, and each worktree on an unreachable volume added a
            // full `gitTimeout` to that.
            worktrees: { [weak self] repo in
                self?.workspaceManager.tabs.first(where: { $0.repoPath == repo })?.worktrees ?? []
            },
            integrationPath: { IntegrationWorktreeStore.shared.worktreePath(forRepo: $0) },
            isCheckoutBusy: { Fleet.shared.hasRunningPane(inWorktree: $0) },
            isWorktreeBusy: { Fleet.shared.hasRunningPane(inWorktree: $0) },
            lastPublished: { IntegrationWorktreeStore.shared.lastPublishedCommit(forCheckout: $0) },
            onReport: { [weak self] report, repo in
                IntegrationStatusStore.shared.set(report.panelState, forWorktree: report.integrationWorktreePath)
                if case .published(let commit) = report.outcome {
                    IntegrationWorktreeStore.shared.recordPublished(
                        commit, forCheckout: report.integrationWorktreePath)
                }
                guard report.needsAttention else { return }
                // One card per checkout: the core keeps the latest round's
                // (its key is worktree and kind), as the side panel does.
                guard let options = report.cardOptions, !options.isEmpty else { return }
                self?.cards.raise(kind: .report, worktreePath: report.integrationWorktreePath,
                                  project: self?.repoName(forWorktree: report.integrationWorktreePath) ?? "",
                                  message: report.summary, options: options,
                                  // The repo to re-run against: the card's path is the checkout.
                                  payload: repo)
            }
        )
        Fleet.shared.onChange = { [weak self] outcome in
            guard let self else { return }
            self.integration?.handle(outcome)
            // Completions and notices are the core's to decide: `pane.notice`
            // (handleCoreNotice).
            // The worktree rows roll up their panes' statuses.
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
        // Coming back to the app is looking at whatever it shows.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.markVisiblePanesSeen()
        }
        // Leaving the app makes nothing on screen: finished turns stay unseen.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.reportVisibility()
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
        WorktreeCleanupStore.shared.onChange = { [weak self] _ in self?.scheduleCleanupRepaint() }
        WorktreePRStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.scheduleCleanupRepaint()
        }
    }

    deinit { Fleet.shared.onChange = nil }

    private var cleanupRepaintScheduled = false

    /// Probes resolve one after another off a serial queue; fold a burst of
    /// them into one fleet repaint.
    private func scheduleCleanupRepaint() {
        guard !cleanupRepaintScheduled else { return }
        cleanupRepaintScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.cleanupRepaintScheduled = false
            self.dashboardVC?.updatePanes(self.buildWorktreeRowInfos())
        }
    }

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
        statusAggregator.sync(trees: terminalCoordinator.stationManager.all)
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)

        return tabIndex
    }

    /// Worktrees discovery used to list and no longer does.
    ///
    /// Empty when the new list is empty, and that guard is the point: a
    /// `git worktree list` that failed, or a removable volume that went away,
    /// comes back as *nothing* — indistinguishable from a fleet deleted one
    /// worktree at a time, except that one of those readings deletes every
    /// Telegram thread the fleet has and cannot be undone. So it is not
    /// believed: something must still be there for anything to have gone.
    static func vanishedWorktrees(previous: Set<String>, current: Set<String>) -> Set<String> {
        guard !current.isEmpty else { return [] }
        return previous.subtracting(current)
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
        let agents = Fleet.shared.allPanes()
            .filter { !FirstMatePane.isFirstMate(worktreePath: $0.worktreePath) }
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
            // Every pane's Fleet status, in leaf order — these draw the per-pane
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

            // Ready to clean up? Only a worktree the fleet has already seen sit
            // quiet for a day costs a git probe; the store serves the answer
            // from cache and repaints the fleet when a probe changes it.
            let isIntegration = IntegrationWorktreeStore.shared.isIntegrationWorktree(agent.worktreePath)
            let cleanupStatuses = paneStatuses + [rolledUpStatus]
            let now = Date()
            if WorktreeCleanupPolicy.isQuiet(isMain: isMain, isIntegration: isIntegration,
                                             statuses: cleanupStatuses, lastActivity: lastActivity, now: now) {
                WorktreeCleanupStore.shared.refresh(worktreePath: agent.worktreePath, now: now)
            }
            let isCleanupCandidate = WorktreeCleanupPolicy.isCandidate(
                isMain: isMain, isIntegration: isIntegration, statuses: cleanupStatuses,
                lastActivity: lastActivity,
                probe: WorktreeCleanupStore.shared.probe(worktreePath: agent.worktreePath),
                now: now)

            // The branch's PR and its CI, as seahelm-core last fetched them.
            // Main and the integration checkout are not PR work.
            let branch = worktreeInfoByPath[agent.worktreePath]?.branch ?? agent.branch
            var prStatus: WorktreePRStatus?
            if !isMain, !isIntegration, !branch.isEmpty {
                prStatus = WorktreePRStore.shared.status(worktreePath: agent.worktreePath, branch: branch)
            }

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
            let currentPaneRunningSince: Date? = focusedPane.status == .running && focusedPane.roundDuration > 0
                ? Date().addingTimeInterval(-focusedPane.roundDuration) : nil

            // Per-pane rows for the expanded "Group by Pane" mode. Aligned to
            // paneStations (leaf order); title/status come from each pane's own
            // Fleet pane, so sibling panes read distinctly.
            let worktreePanes = agentsByWorktree[agent.worktreePath] ?? []
            let panes: [PaneDisplayInfo] = paneStations.map { paneStation in
                let panePane = worktreePanes.first(where: { $0.id == paneStation.id })
                return PaneDisplayInfo(
                    stationId: paneStation.id,
                    handle: CoreLink.shared.handle(forSession: paneStation.paneSessionKey),
                    title: panePane.map { PaneTitleResolver.title(for: $0) }
                        ?? PaneTitleResolver.shortenPath(agent.worktreePath),
                    status: panePane?.status ?? .unknown,
                    isFocused: paneStation.id == focusedStationId,
                    unseenCompletion: panePane?.unseenCompletion ?? false
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
                currentPaneRunningSince: currentPaneRunningSince,
                panes: panes,
                label: WorktreeLabelStore.shared.label(forWorktree: agent.worktreePath),
                isCleanupCandidate: isCleanupCandidate,
                prStatus: prStatus,
                hasUnseenCompletion: worktreePanes.contains(where: \.unseenCompletion)
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
                // Keep the volume monitor's watched set in sync with the live
                // workspace list (repos + every discovered worktree path).
                let watchPaths = resolvedPaths + discoveredWorktrees.flatMap { $0.worktrees.map(\.path) }
                VolumePresenceMonitor.shared.start(workspacePaths: watchPaths)

                var allWorktreeInfos: [(info: WorktreeInfo, tree: SplitTree?)] = []

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

                let previousPaths = Set(self.allWorktrees.map(\.info.path))
                self.allWorktrees = allWorktreeInfos

                let vanished = Self.vanishedWorktrees(
                    previous: previousPaths, current: Set(allWorktreeInfos.map(\.info.path)))
                if !vanished.isEmpty {
                    self.delegate?.tabCoordinator(self, worktreesDidVanish: Array(vanished))
                }

                // Register all agents with Fleet
                for (info, _) in allWorktreeInfos {
                    let repo = self.worktreeRepoCache[info.path] ?? WorktreeDiscovery.findRepoRoot(from: info.path) ?? info.path
                    let proj = self.workspaceManager.tabs.first(where: { $0.repoPath == repo })?.displayName
                        ?? URL(fileURLWithPath: repo).lastPathComponent
                    let started = self.config.worktreeStartedAt[info.path].flatMap { Self.iso8601.date(from: $0) }
                    self.registerPanes(of: info, project: proj, startedAt: started)
                }
                if !cardOrder.isEmpty {
                    Fleet.shared.reorder(paths: cardOrder)
                }

                self.dashboardVC?.updatePanes(self.buildWorktreeRowInfos())
                self.delegate?.tabCoordinatorRequestUpdateTitleBar(self)

                if allWorktreeInfos.isEmpty {
                    NSLog("No workspaces configured. Add paths to ~/.config/seahelm/config.json")
                }

                // Start polling for agent status
                self.statusAggregator.sync(trees: self.terminalCoordinator.stationManager.all)
                self.updateStatusPollPreferences()
                self.applyAutopilotConfig()

                // Restore last session state (tab, worktree, pane)
                self.restoreSessionState()

                // Start periodic branch name refresh
                self.startBranchRefreshTimer()

                // Start webhook server for agent hook events
                if self.config.webhook.enabled {
                    // What hooks tell, seahelm-core has made sense of: where each
                    // agent works, worktrees agents start in, resume references.
                    CoreClient.shared.observe { [weak self] event in
                        guard let self else { return }
                        switch event {
                        case .worktreeDiscovered(let path, _):
                            // Discover the card; the pane stays where it is filed.
                            self.handleNewWorktreeFromHook(path)
                        case .location(let id, let worktree, let location, let created):
                            self.noteAgentLocation(terminalID: id, worktreePath: worktree, cwd: location,
                                                   createdByAgent: created)
                        case .session(let key, let ref):
                            StationRegistry.shared.station(forSessionName: key)?.agentSessionRef = AgentSessionRef(dict: ref)
                        default:
                            break
                        }
                    }
                    let controlDataSource = SeahelmControlDataSource()
                    // seahelm-core watches what the app shows and runs the command
                    // language; see CoreLink.
                    CoreLink.shared.panes = { [weak controlDataSource] in
                        controlDataSource?.snapshotPanes().map(\.dict) ?? []
                    }
                    CoreLink.shared.worktrees = { [weak self] in self?.allWorktrees.map(\.info.path) ?? [] }
                    CoreLink.shared.start()
                    // What every pane is doing comes from the core, and so do
                    // the notices and unseen completions.
                    CoreClient.shared.observe { [weak self] event in
                        guard let self else { return }
                        switch event {
                        case .notice(let notice, let terminalID):
                            self.handleCoreNotice(notice, terminalID: terminalID)
                        case .unseen(let terminalID, let unseen):
                            self.setUnseenCompletion(unseen, terminalID: terminalID)
                        case .connected(true):
                            self.reportVisibility()
                        case .paneRegistered(let session, let path):
                            self.adoptCoreSession(session, worktreePath: path)
                        case .paneClosedByRequest(let session, _):
                            self.removePaneEndedByRequest(paneSessionKey: session)
                        case .presence(let caller, let target, let note):
                            // A `seahelm` call the core answered: shown as the
                            // app shows calls on its own socket.
                            controlDataSource.notePresence(callerPaneId: caller, targetPaneId: target, note: note)
                        case .raw(let ev):
                            // The control socket's subscribers hear the core's
                            // events as the core sent them.
                            EventHub.shared.publish(seq: (ev["seq"] as? NSNumber)?.uint64Value ?? 0, event: ev)
                        default:
                            break
                        }
                    }
                    self.cards.start()
                    CoreClient.shared.start()
                    controlDataSource.splitHandler = { [weak self] targetStationId, axis, focus in
                        guard let self, self.preparePaneControlTarget(targetStationId) else { return nil }
                        return self.terminalCoordinator.splitPane(
                            targetStationId: targetStationId, axis: axis, focus: focus)
                    }
                    controlDataSource.closeHandler = { [weak self] stationId in
                        guard let self, self.preparePaneControlTarget(stationId) else { return false }
                        return self.terminalCoordinator.closePane(targetStationId: stationId)
                    }
                    controlDataSource.focusHandler = { [weak self] stationId in
                        guard let self, self.preparePaneControlTarget(stationId) else { return false }
                        return self.terminalCoordinator.focusPane(targetStationId: stationId)
                    }
                    controlDataSource.moveHandler = { [weak self] stationId, worktreePath in
                        self?.movePane(stationId: stationId, toWorktreePath: worktreePath) ?? false
                    }
                    PanePresence.shared.onNavigate = { [weak self] stationId in
                        guard let self, self.preparePaneControlTarget(stationId) else { return }
                        // Selecting the worktree embeds its surface; focus after that.
                        DispatchQueue.main.async {
                            _ = self.terminalCoordinator.focusPane(targetStationId: stationId)
                        }
                    }
                    controlDataSource.forkHandler = { [weak self] stationId, worktreePath, done in
                        guard let self else { done(.failure(.unknownPane)); return }
                        self.forkPane(stationId: stationId, toWorktreePath: worktreePath, completion: done)
                    }
                    controlDataSource.sleepHandler = { [weak self] stationId in
                        self?.terminalCoordinator.sleepPane(targetStationId: stationId) ?? []
                    }
                    controlDataSource.wakeHandler = { [weak self] stationId in
                        self?.terminalCoordinator.wakePane(targetStationId: stationId) ?? []
                    }
                    controlDataSource.deleteWorktreeHandler = { [weak self] path, done in
                        guard let self else { return done(.failure(.unavailable)) }
                        let wanted = WorktreeDiscovery.canonicalPath(path)
                        guard let item = self.allWorktrees.first(where: {
                            WorktreeDiscovery.canonicalPath($0.info.path) == wanted && !$0.info.isMainWorktree
                        }) else { return done(.failure(.failed("not a worktree seahelm can delete"))) }
                        // Unattended: approved on a card that showed what it holds,
                        // so no sheet — and the answer is what happened, not "asked".
                        self.dashboardVC?.setWorktreePending(path: item.info.path, pending: true)
                        self.terminalCoordinator.deleteWorktreeUnattended(item.info) { [weak self] outcome in
                            self?.dashboardVC?.setWorktreePending(path: item.info.path, pending: false)
                            switch outcome {
                            case .success(let note):
                                done(.success(["worktree_path": path, "deleted": true, "note": note]))
                            case .failure(let error):
                                done(.failure(.failed(error.message)))
                            }
                        }
                    }
                    controlDataSource.firstMateStateHandler = { FirstMateLink.remoteState() ?? ["enabled": false] }
                    controlDataSource.paneSeenHandler = { [weak self] paneId in
                        self?.markPaneSeen(paneId: paneId) ?? false
                    }
                    controlDataSource.liveLayoutsHandler = { [weak self] in
                        self?.terminalCoordinator.liveLayouts() ?? [:]
                    }
                    controlDataSource.repoPathsHandler = { [weak self] in
                        self?.config.workspacePaths ?? []
                    }
                    controlDataSource.createWorktreeHandler = { [weak self] repo, agent, prompt, done in
                        guard let create = self?.worktreeCreator else { done(nil); return }
                        create(prompt, repo, agent, done)
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
                        self.controlDataSource = controlDataSource
                    }
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

            // New worktrees always get their own tree. Panes no longer follow
            // their agent here — see `noteAgentLocation` / chrome away title.
            let tree = terminalCoordinator.resolveTree(for: info)
            allWorktrees.append((info: info, tree: tree))
            worktreeRepoCache[info.path] = repoRoot

            registerPanes(of: info, project: proj, startedAt: Date())
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
        statusAggregator.sync(trees: terminalCoordinator.stationManager.all)
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
            } else if Self.isEphemeralRepoPath(repoRoot) {
                // An agent that clones into $TMPDIR to build and cd's there would
                // otherwise join that clone to the workspace permanently.
                NSLog("[TabCoordinator] Ignoring ephemeral repo from hook: \(repoRoot)")
            } else if Self.isToolStateRepoPath(repoRoot) {
                NSLog("[TabCoordinator] Ignoring tool-state repo from hook: \(repoRoot)")
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

    /// Repos that live inside a hidden directory — `~/.amuxd/teams/<id>/apps/<id>`,
    /// `~/.local/state/…`. That is a tool's own generated state, not a project the
    /// user opened, and the generator often runs agents inside it; those agents
    /// inherit `SEAHELM_PANE_ID` from the pane that started the generator, so their
    /// cwd arrives looking exactly like a pane that moved. Auto-add is silent and
    /// `workspacePaths` is never pruned, so every generated app became a permanent
    /// project. Only the hook-driven path consults this — a repo under a dot
    /// directory the user actually works in (`~/.dotfiles`) is still theirs to add.
    static func isToolStateRepoPath(_ path: String) -> Bool {
        WorktreeDiscovery.canonicalPath(path)
            .split(separator: "/")
            .contains { $0.hasPrefix(".") }
    }

    /// Record where a pane's agent last reported itself. Does not move the pane;
    /// refresh the chrome title so a mismatch can show as an "away" suffix.
    private func noteAgentLocation(terminalID: String, worktreePath: String?, cwd: String, createdByAgent: Bool) {
        guard let station = StationRegistry.shared.station(forId: terminalID) else { return }
        let next = Station.HookLocation(worktreePath: worktreePath, cwd: cwd)
        let prev = station.hookLocation
        let changed = prev?.worktreePath != next.worktreePath || prev?.cwd != next.cwd
        station.hookLocation = next
        if changed {
            delegate?.tabCoordinatorRequestUpdateTitleBar(self)
        }
        if let worktreePath, createdByAgent { autoForkIntoCreated(station: station, worktreePath: worktreePath) }
    }

    /// Pane + destination pairs already auto-forked, so the original pane's
    /// later events (it is still filed where it was) do not fork it again.
    private var autoForked: Set<String> = []
    /// Where each pane was last forked to, by the original pane's station id.
    /// In memory: the durable record is the notice in the original pane's own
    /// transcript (`PaneFork.originNotice`).
    private var forkRecords: [String: PaneFork.Record] = [:]

    /// Fork the pane into `worktreePath`, a worktree its agent created itself and
    /// is now working in (`PaneFork.shouldAutoFork`). The original pane stays,
    /// its turn stopped; the fork is told to carry on, and the view stays where
    /// the user has it.
    private func autoForkIntoCreated(station: Station, worktreePath: String) {
        guard let located = terminalCoordinator.stationManager.locate(stationId: station.id) else { return }
        let canon = WorktreeDiscovery.canonicalPath(worktreePath)
        let key = station.id + "\u{0}" + canon
        guard PaneFork.shouldAutoFork(enabled: config.autoForkPanes,
                                      filedWorktree: located.tree.worktreePath,
                                      destination: canon,
                                      alreadyForked: autoForked.contains(key)),
              case .success = forkPlan(stationId: station.id, toWorktreePath: worktreePath) else { return }
        autoForked.insert(key)
        NSLog("[TabCoordinator] Auto-forking pane \(station.id) into the worktree its agent created: \(canon)")
        forkPane(stationId: station.id, toWorktreePath: worktreePath,
                 continueTask: true, reveal: false) { result in
            if case .failure(let error) = result {
                NSLog("[TabCoordinator] Auto-fork into \(canon) failed: \(error.message)")
            }
        }
    }

    /// Move a live pane into an existing worktree, by station id. Behind
    /// `pane.move`: for correcting attribution when an agent works elsewhere.
    /// False when the pane or the worktree is unknown.
    @discardableResult
    func movePane(stationId: String, toWorktreePath: String) -> Bool {
        let canon = WorktreeDiscovery.canonicalPath(toWorktreePath)
        guard let entry = allWorktrees.first(where: {
            WorktreeDiscovery.canonicalPath($0.info.path) == canon
        }) else {
            NSLog("[TabCoordinator] pane.move: unknown worktree \(toWorktreePath)")
            return false
        }
        let repoRoot = worktreeRepoCache[entry.info.path] ?? ""
        let project = workspaceManager.tabs.first(where: { $0.repoPath == repoRoot })?.displayName
            ?? URL(fileURLWithPath: repoRoot).lastPathComponent
        return rehomePane(stationId: stationId, into: entry.info, repoRoot: repoRoot, project: project)
    }

    // MARK: - Pane fork

    /// What a fork of `stationId` would do: the session to copy and the worktree
    /// to open it in. Main thread. Side-effect free, so the header can ask it on
    /// every title refresh to decide whether to offer the button.
    func forkPlan(stationId: String, toWorktreePath explicit: String? = nil)
        -> Result<(ref: AgentSessionRef, destination: WorktreeInfo), PaneForkError> {
        guard let station = StationRegistry.shared.station(forId: stationId),
              let located = terminalCoordinator.stationManager.locate(stationId: stationId) else {
            return .failure(.unknownPane)
        }
        guard runtimeBackend == "seahelmd", let key = station.paneSessionKey, !key.isEmpty else {
            return .failure(.noPersistentBackend)
        }
        guard let ref = AgentSessionRef.forPane(key) else { return .failure(.noSession) }
        guard ref.supportsFork else { return .failure(.unsupportedAgent) }
        let filed = located.tree.worktreePath
        guard let target = PaneFork.target(explicit: explicit, filedWorktree: filed,
                                           hookWorktree: station.hookLocation?.worktreePath) else {
            return .failure(.noTarget)
        }
        let canon = WorktreeDiscovery.canonicalPath(target)
        guard let entry = allWorktrees.first(where: { WorktreeDiscovery.canonicalPath($0.info.path) == canon }) else {
            return .failure(.unknownWorktree(target))
        }
        guard WorktreeDiscovery.canonicalPath(filed) != canon else { return .failure(.sameWorktree) }
        return .success((ref, entry.info))
    }

    /// Fork a pane's conversation into another worktree: stop the original
    /// turn (Esc — the pane, its process and its session all stay), start
    /// `claude --resume <id> --fork-session` in a fresh seahelmd session in the
    /// destination, and file a new pane on that session there. The fork waits
    /// at its prompt, unless `continueTask` gives it a first message to carry
    /// on. `reveal` brings the fork on screen and focuses it.
    ///
    /// Main thread; `completion` runs on main with the new pane's station id.
    func forkPane(stationId: String, toWorktreePath explicit: String? = nil,
                  continueTask: Bool = false, reveal: Bool = true,
                  completion: @escaping (Result<String, PaneForkError>) -> Void) {
        let plan: (ref: AgentSessionRef, destination: WorktreeInfo)
        switch forkPlan(stationId: stationId, toWorktreePath: explicit) {
        case .failure(let error): completion(.failure(error)); return
        case .success(let p): plan = p
        }
        let destination = plan.destination
        let yolo = config.agentYolo ? AgentType.claudeCode.yoloFlag.map { [$0] } ?? [] : []
        let name = ["--name", PaneFork.sessionName(branch: destination.branch, worktreePath: destination.path)]
        let promptFile = continueTask
            ? PaneFork.writePromptFile(PaneFork.continuePrompt(destination: destination.path))
            : nil
        guard let commandLine = plan.ref.forkCommandLine(extraArgs: name + yolo, promptFile: promptFile) else {
            completion(.failure(.unsupportedAgent)); return
        }

        StationRegistry.shared.station(forId: stationId)?.interruptTurn()

        let manager = terminalCoordinator.stationManager
        let backend = runtimeBackend
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Thread.sleep(forTimeInterval: PaneFork.interruptSettleDelay)
            // A name no live tree claims *and* no seahelmd session holds: a session left
            // behind by a closed pane would otherwise be attached to as-is.
            var name = ""
            DispatchQueue.main.sync {
                name = manager.freeSessionName(for: destination.path) {
                    SessionManager.sessionExists(name: $0, backend: backend)
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                SessionManager.createDetachedSession(name: name, backend: backend,
                                                     cwd: destination.path, agentCommandLine: commandLine)
            }
            let started = SessionManager.waitUntilSessionExists(name: name, backend: backend, timeoutSeconds: 5)
            DispatchQueue.main.async {
                guard let self, started else { completion(.failure(.launchFailed)); return }
                NSLog("[TabCoordinator] Forked pane \(stationId) into \(destination.path) as \(name)")
                let forkId = self.installPane(sessionName: name, in: destination, reveal: reveal)
                self.recordFork(origin: stationId, forkStationId: forkId, sessionName: name, destination: destination)
                completion(.success(forkId))
            }
        }
    }

    /// Remember where `origin` went, refresh its header badge, and tell its
    /// agent: the Esc that made room for the fork reads to it as the user
    /// cutting it off, and nothing else would ever say the work moved.
    private func recordFork(origin: String, forkStationId: String, sessionName: String,
                            destination: WorktreeInfo) {
        let name = destination.branch.isEmpty
            ? URL(fileURLWithPath: destination.path).lastPathComponent : destination.branch
        forkRecords[origin] = PaneFork.Record(forkStationId: forkStationId,
                                              destinationPath: destination.path,
                                              destinationName: "@" + name)
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
        sendForkNotice(origin: origin, fork: forkStationId, forkSession: sessionName,
                       destinationName: "@" + name, destinationPath: destination.path, waited: 0)
    }

    /// Send the notice once the fork has started and the interrupted turn has
    /// ended (`PaneFork.noticeIsDue`). The fork's `#n` is read at send time:
    /// seahelm-core numbers a pane only once it has listed it. A pane closed in
    /// the meantime gets nothing.
    private func sendForkNotice(origin stationId: String, fork forkId: String, forkSession: String,
                                destinationName: String, destinationPath: String, waited: TimeInterval) {
        guard StationRegistry.shared.station(forId: stationId) != nil else { return }
        let handle = CoreLink.shared.handle(forSession: forkSession)
        let forkPane = Fleet.shared.pane(for: forkId)
        let forkReady = PaneFork.forkIsReady(agentType: forkPane?.agentType, status: forkPane?.status,
                                             handle: handle)
        if PaneFork.noticeIsDue(originStatus: Fleet.shared.pane(for: stationId)?.status,
                                forkReady: forkReady, waited: waited) {
            let notice = PaneFork.originNotice(handle: handle, destinationName: destinationName,
                                               destinationPath: destinationPath)
            PaneInput.shared.sendCommand(to: stationId, command: notice)
            delegate?.tabCoordinatorRequestUpdateTitleBar(self)
            return
        }
        let step = PaneFork.noticePollInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + step) { [weak self] in
            self?.sendForkNotice(origin: stationId, fork: forkId, forkSession: forkSession,
                                 destinationName: destinationName, destinationPath: destinationPath,
                                 waited: waited + step)
        }
    }

    /// Where `stationId` was last forked to, with the fork's `#n` (nil until
    /// seahelm-core has numbered it) — nil once that fork's pane is gone. Main thread.
    func forkRecord(forStationId stationId: String) -> (record: PaneFork.Record, handle: Int?)? {
        guard let record = forkRecords[stationId] else { return nil }
        guard let fork = StationRegistry.shared.station(forId: record.forkStationId),
              terminalCoordinator.stationManager.locate(stationId: record.forkStationId) != nil else {
            forkRecords.removeValue(forKey: stationId)
            return nil
        }
        return (record, CoreLink.shared.handle(forSession: fork.paneSessionKey))
    }

    /// Bring a pane on screen and focus it, wherever it is filed. Main thread.
    @discardableResult
    func revealPane(stationId: String) -> Bool {
        guard preparePaneControlTarget(stationId) else { return false }
        DispatchQueue.main.async { [weak self] in
            _ = self?.terminalCoordinator.focusPane(targetStationId: stationId)
        }
        return true
    }

    /// File a new pane on an already-running seahelmd session in `destination`, and
    /// bring it on screen when `reveal`. A placeholder the worktree was standing on
    /// is retired rather than split beside. Returns the new station id.
    @discardableResult
    private func installPane(sessionName: String, in destination: WorktreeInfo, reveal: Bool) -> String {
        let manager = terminalCoordinator.stationManager
        retirePlaceholderPane(at: destination.path)

        let station = Station()
        station.paneSessionKey = sessionName
        station.backend = runtimeBackend
        let tree = manager.insert(station: station, paneSessionKey: sessionName, intoPath: destination.path)

        let repoRoot = worktreeRepoCache[destination.path] ?? ""
        let project = workspaceManager.tabs.first(where: { $0.repoPath == repoRoot })?.displayName
            ?? URL(fileURLWithPath: repoRoot).lastPathComponent
        Fleet.shared.register(station: station, worktreePath: destination.path,
                                      branch: destination.branch, project: project, startedAt: Date(),
                                      paneSessionKey: sessionName, backend: runtimeBackend)
        if let idx = allWorktrees.firstIndex(where: { $0.info.path == destination.path }) {
            allWorktrees[idx] = (info: destination, tree: tree)
        } else {
            allWorktrees.append((info: destination, tree: tree))
        }
        terminalCoordinator.saveSplitLayout(tree)
        saveConfig()

        dashboardVC?.invalidateSplitContainer(forPath: destination.path)
        dashboardVC?.updatePanes(buildWorktreeRowInfos())
        statusAggregator.sync(trees: manager.all)

        // Selecting the worktree embeds its container, which creates the surface;
        // focus has to wait for that.
        if reveal, preparePaneControlTarget(station.id) {
            DispatchQueue.main.async { [weak self] in
                _ = self?.terminalCoordinator.focusPane(targetStationId: station.id)
            }
        }
        return station.id
    }

    /// Lift one pane out of its current worktree and into `destination`, keeping
    /// its Station, its seahelmd session and the agent inside it alive.
    ///
    /// Moves that one pane, never the whole tree: a worktree's other panes have
    /// their own agents doing their own work, and re-homing them because a sibling
    /// moved mis-attributes all of them.
    @discardableResult
    private func rehomePane(stationId: String, into destination: WorktreeInfo,
                            repoRoot: String, project: String) -> Bool {
        // A worktree standing on nothing but the placeholder pane seahelm gave it
        // has that pane retired rather than split: the card would otherwise show
        // the arriving agent beside an empty terminal nobody asked for. Runs
        // before `moveLeaf`, which builds a fresh single-leaf tree only when the
        // destination has none — and only once the move is known to be possible,
        // so a move that gets rejected cannot cost the destination its pane.
        if let located = terminalCoordinator.stationManager.locate(stationId: stationId),
           located.tree.worktreePath != destination.path {
            retirePlaceholderPane(at: destination.path)
        }
        guard let move = terminalCoordinator.stationManager.moveLeaf(stationId: stationId,
                                                                     toPath: destination.path) else {
            NSLog("[TabCoordinator] Rehome skipped — station \(stationId) is not in a movable tree")
            return false
        }
        let sourcePath = move.sourcePath
        NSLog("[TabCoordinator] Rehomed pane \(stationId) from \(sourcePath) to \(destination.path)")

        // Re-attribute rather than unregister+register: the agent in this pane is
        // still running, and rebuilding its entry would reset its status, timers
        // and event log to those of a freshly opened pane.
        _ = Fleet.shared.rehome(terminalID: stationId, to: destination.path,
                                        branch: destination.branch, project: project)

        if let idx = allWorktrees.firstIndex(where: { $0.info.path == destination.path }) {
            allWorktrees[idx] = (info: destination, tree: move.tree)
        } else {
            allWorktrees.append((info: destination, tree: move.tree))
        }
        worktreeRepoCache[destination.path] = repoRoot

        // A source that just lost its last pane gets a replacement, because the
        // dashboard builds its cards from live panes — leaving it with none would
        // remove the card outright, not show an empty one. `replacementTree`
        // claims a *free* session name: the departed pane kept the worktree's
        // canonical one, and reusing it would point both panes at one live seahelmd
        // session. The undo stays lossless either way, since moving the pane back
        // adopts it into whatever tree is there rather than replacing it.
        terminalCoordinator.config.splitLayouts.removeValue(forKey: sourcePath)
        if let idx = allWorktrees.firstIndex(where: { $0.info.path == sourcePath }) {
            let sourceInfo = allWorktrees[idx].info
            let sourceTree = move.sourceEmptied
                ? terminalCoordinator.stationManager.replacementTree(for: sourceInfo, backend: runtimeBackend)
                : terminalCoordinator.stationManager.tree(forPath: sourcePath)
            allWorktrees[idx] = (info: sourceInfo, tree: sourceTree)

            if move.sourceEmptied,
               let replacement = terminalCoordinator.stationManager.primaryStation(forPath: sourcePath) {
                let sourceRepo = worktreeRepoCache[sourcePath] ?? repoRoot
                let sourceProject = workspaceManager.tabs.first(where: { $0.repoPath == sourceRepo })?.displayName
                    ?? URL(fileURLWithPath: sourceRepo).lastPathComponent
                Fleet.shared.register(
                    station: replacement, worktreePath: sourcePath, branch: sourceInfo.branch,
                    project: sourceProject, startedAt: Date(),
                    paneSessionKey: replacement.paneSessionKey.flatMap { $0.isEmpty ? nil : $0 },
                    backend: runtimeBackend)
            }
            if let sourceTree { terminalCoordinator.saveSplitLayout(sourceTree) }
        }
        terminalCoordinator.saveSplitLayout(move.tree)
        saveConfig()

        dashboardVC?.invalidateSplitContainer(forPath: sourcePath)
        dashboardVC?.invalidateSplitContainer(forPath: destination.path)
        dashboardVC?.updatePanes(buildWorktreeRowInfos())
        // The surface set changed on both sides — and a retired placeholder is
        // gone from the registry, so the poller must stop holding on to it.
        statusAggregator.sync(trees: terminalCoordinator.stationManager.all)
        return true
    }

    /// Retire the placeholder a worktree is standing on, so an arriving pane takes
    /// its place instead of splitting the card in two. No-op unless the worktree's
    /// *only* pane is one seahelm created and nobody has used yet.
    @discardableResult
    private func retirePlaceholderPane(at worktreePath: String) -> Bool {
        let manager = terminalCoordinator.stationManager
        guard let leaf = manager.soleLeaf(atPath: worktreePath),
              let station = StationRegistry.shared.station(forId: leaf.stationId) else { return false }
        let pane = Fleet.shared.pane(for: leaf.stationId)
        guard Self.isPlaceholderPane(autoCreated: manager.wasAutoCreated(stationId: leaf.stationId),
                                     agentType: pane?.agentType ?? .unknown,
                                     status: pane?.status ?? .unknown,
                                     hasActivity: pane.map(Self.paneHasActivity) ?? false,
                                     showsOnlyPrompt: station.showsOnlyPrompt) else { return false }

        NSLog("[TabCoordinator] Retiring placeholder pane \(leaf.stationId) in \(worktreePath)")
        manager.removeTree(forPath: worktreePath)
        Fleet.shared.unregister(terminalID: leaf.stationId)
        if !leaf.paneSessionKey.isEmpty {
            SessionManager.killSession(leaf.paneSessionKey, backend: runtimeBackend)
            AgentSessionRef.forget(leaf.paneSessionKey)
        }
        terminalCoordinator.config.splitLayouts.removeValue(forKey: worktreePath)
        return true
    }

    /// Whether a worktree's only pane is still the placeholder seahelm stood up for
    /// it. Every clause is a reason not to throw a terminal away: `autoCreated`
    /// excludes panes restored from a saved layout (their seahelmd sessions may hold
    /// work, and an unpainted attach looks empty); `showsOnlyPrompt == true`
    /// excludes both a used pane and one whose contents we cannot read; the rest
    /// exclude a pane something has already happened in. Pure, because a rule that
    /// discards a pane is worth pinning down without a live terminal.
    static func isPlaceholderPane(autoCreated: Bool, agentType: AgentType, status: AgentStatus,
                                  hasActivity: Bool, showsOnlyPrompt: Bool?) -> Bool {
        guard autoCreated, showsOnlyPrompt == true, agentType == .unknown, !hasActivity else { return false }
        return status == .unknown || status == .idle
    }

    /// Anything that has happened in a pane beyond its existing.
    static func paneHasActivity(_ pane: PaneInfo) -> Bool {
        !pane.activityEvents.isEmpty || !pane.tasks.isEmpty
            || !pane.lastMessage.isEmpty || !pane.lastUserPrompt.isEmpty
            || !pane.lastAssistantMessage.isEmpty || !(pane.commandLine ?? "").isEmpty
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
        for terminalID in Fleet.shared.terminalIDs(forWorktree: info.path) {
            Fleet.shared.unregister(terminalID: terminalID)
        }
        WorktreeTitleCache.shared.evict(worktreePath: info.path)
        WorktreeGitStatsCache.shared.evict(worktreePath: info.path)
        WorktreeCleanupStore.shared.evict(worktreePath: info.path)
        dashboardVC?.invalidateSplitContainer(forPath: info.path)
        dashboardVC?.updatePanes(buildWorktreeRowInfos())
        statusAggregator.sync(trees: terminalCoordinator.stationManager.all)

        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
    }

    /// The worktree's last pane was closed — its session ended, but the
    /// worktree stays on disk and in `allWorktrees`. Drop the dead split
    /// container and repaint the row as session-less. The light counterpart of
    /// `worktreeDidDelete`, which also removes the row.
    func worktreeSessionDidEnd(_ path: String) {
        dashboardVC?.invalidateSplitContainer(forPath: path)
        dashboardVC?.updatePanes(buildWorktreeRowInfos())
        statusAggregator.sync(trees: terminalCoordinator.stationManager.all)
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
            let ids = Fleet.shared.terminalIDs(forWorktree: worktree.path)
            if ids.isEmpty, let primaryStation {
                Fleet.shared.unregister(terminalID: primaryStation.id)
            } else {
                for id in ids {
                    Fleet.shared.unregister(terminalID: id)
                }
            }
            WorktreeTitleCache.shared.evict(worktreePath: worktree.path)
            WorktreeGitStatsCache.shared.evict(worktreePath: worktree.path)
            WorktreeCleanupStore.shared.evict(worktreePath: worktree.path)
            if runtimeBackend != "local" {
                let paneSessionKey = SessionManager.persistentSessionName(for: worktree.path)
                SessionManager.killSession(paneSessionKey, backend: runtimeBackend)
            }
        }

        allWorktrees.removeAll { item in
            tab.worktrees.contains(where: { $0.path == item.info.path })
        }

        config.workspacePaths.removeAll { $0 == tab.repoPath }
        // The integration checkout goes with the repo. Nothing pruned these
        // before, so a repo removed and re-added came back with a checkout
        // pointing at a directory that had been deleted with it.
        IntegrationWorktreeStore.shared.forget(repoPath: tab.repoPath)
        saveConfig()

        workspaceManager.removeTab(at: tabIndex)

        activeTabIndex = -1
        delegate?.tabCoordinatorRequestClearContentContainer(self)

        dashboardVC?.updatePanes(buildWorktreeRowInfos())
        statusAggregator.sync(trees: terminalCoordinator.stationManager.all)
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
    /// advances the seconds-resolution elapsed labels (Fleet stopped fanning
    /// out on roundDuration ticks), so a slower cadence reads as a frozen
    /// counter. `buildWorktreeRowInfos` is cache-served and the render it
    /// feeds is now incremental, so the tick is cheap enough to keep at 10s.
    private static let elapsedRefreshEveryTicks = 2

    static func shouldRefreshDashboardElapsedTime(tick: Int) -> Bool {
        guard tick > 0 else { return false }
        return tick % elapsedRefreshEveryTicks == 0
    }

    /// Every 12th tick, i.e. once a minute, whether or not anything runs: a
    /// worktree becomes ready to clean up by time passing alone, and nothing
    /// else rebuilds the rows of a fleet that has gone quiet.
    private static let cleanupRefreshEveryTicks = 12

    static func shouldRefreshCleanupMarks(tick: Int) -> Bool {
        guard tick > 0 else { return false }
        return tick % cleanupRefreshEveryTicks == 0
    }

    func startBranchRefreshTimer() {
        branchRefreshTimer?.invalidate()
        branchRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.branchRefreshTick += 1
            self.refreshBranches()
            // Re-evaluate worktree-tab idle collapse even when nothing changed.
            self.delegate?.tabCoordinatorRequestUpdateTitleBar(self)
            // Fleet no longer fans out on roundDuration ticks (see
            // displayedStateUnchanged), so elapsed-time and activity-age labels
            // are advanced here at a gentle cadence while anything is running.
            let refreshElapsed = Self.shouldRefreshDashboardElapsedTime(tick: self.branchRefreshTick)
                && Fleet.shared.allPanes().contains(where: { $0.status == .running })
            if refreshElapsed || Self.shouldRefreshCleanupMarks(tick: self.branchRefreshTick) {
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
            // A fenced volume means every git invocation against it will sit out
            // its timeout and park ProcessRunner drain threads — that starvation
            // is how a single dead mount freezes the rest of the app.
            if VolumeFence.isFenced(tab.repoPath) { continue }
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
        statusAggregator.sync(trees: terminalCoordinator.stationManager.all)
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
        // (not selectPane) so the left fleet overview selection stays in
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

    func dashboardDidRequestDeleteWorktree(path: String, window: NSWindow?) {
        let wanted = WorktreeDiscovery.canonicalPath(path)
        guard let item = allWorktrees.first(where: { WorktreeDiscovery.canonicalPath($0.info.path) == wanted }) else {
            NSSound.beep()
            return
        }
        let worktreePath = item.info.path
        terminalCoordinator.confirmAndDeleteWorktree(item.info, window: window) { [weak self] pending in
            self?.dashboardVC?.setWorktreePending(path: worktreePath, pending: pending)
        }
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

    /// Worktrees whose status changed since the last repaint, and whether a
    /// repaint is already queued for the next turn of the runloop.
    ///
    /// Status edges arrive one pane at a time, and each one used to drive a full
    /// dashboard rebuild *plus* a title-bar refresh — every row's labels
    /// reassigned, every row's git summary re-attributed, synchronously on main.
    /// With a dozen panes polling every 2s that pinned the main thread at 100%,
    /// which is what made a Telegram command take 40s to answer: `handleInbound`
    /// hops to main and could not get a turn.
    ///
    /// The edges are already de-duplicated upstream — `Fleet` drops
    /// unchanged scans, `WorktreeStatusAggregator` drops unchanged rollups — so
    /// the fix is not more filtering but batching: note which worktrees changed
    /// and repaint once.
    private var pendingStatusWorktrees: Set<String> = []
    private var statusRepaintScheduled = false

    func handleWorktreeStatusUpdate(_ status: WorktreeStatus) {
        pendingStatusWorktrees.insert(status.worktreePath)
        guard !statusRepaintScheduled else { return }
        statusRepaintScheduled = true
        // Hopping through main rather than repainting inline is the whole point:
        // the sibling edges of this same poll are already queued behind us, so
        // they land in `pendingStatusWorktrees` before this runs.
        DispatchQueue.main.async { [weak self] in self?.flushStatusRepaint() }
    }

    /// Repaint for everything that changed since the last turn. A batch naming
    /// exactly one worktree passes it down; a wider batch passes nil, which both
    /// `buildWorktreeRowInfos` and the overview read as "refresh everything".
    private func flushStatusRepaint() {
        statusRepaintScheduled = false
        let changed = pendingStatusWorktrees
        pendingStatusWorktrees.removeAll()
        guard !changed.isEmpty else { return }
        let single = changed.count == 1 ? changed.first : nil
        dashboardVC?.updatePanes(buildWorktreeRowInfos(changedWorktreePath: single),
                                 changedWorktreePath: single)
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
    }

    /// Whether this worktree is the one currently shown in the dashboard (all its
    /// panes are on screen). Combined with app-frontmost in `NotificationManager`
    /// to decide whether a system banner would be redundant, and by the island /
    /// First Mate reveal to decide which of the two surfaces a suggestion belongs on.
    func isWorktreeVisible(_ worktreePath: String) -> Bool {
        dashboardVC?.activeSplitContainer?.tree?.worktreePath == worktreePath
    }

    /// Visible *and* in front of the user: what it takes for a finished turn to
    /// count as seen.
    private func isWorktreeOnScreen(_ worktreePath: String) -> Bool {
        NSApp.isActive && isWorktreeVisible(worktreePath)
    }

    /// Set a pane's unseen completion and redraw the fleet if it changed.
    func setUnseenCompletion(_ unseen: Bool, terminalID: String) {
        guard let pane = Fleet.shared.pane(for: terminalID), pane.unseenCompletion != unseen else { return }
        Fleet.shared.apply(terminalID: terminalID, info: ["unseen": unseen], isCompletion: false, seq: 0)
        dashboardVC?.updatePanes(buildWorktreeRowInfos())
    }

    /// The worktree on screen has been looked at: every pane of it is on show.
    /// Called when the selection changes and when the app comes to the front.
    func markVisiblePanesSeen() {
        reportVisibility()
    }

    /// Tell the core what is on screen (`client.visible`): it marks a pane's
    /// finished turn unseen only when its worktree is not, and clears the mark
    /// once it is shown in front.
    func reportVisibility() {
        let shown = dashboardVC?.activeSplitContainer?.tree?.worktreePath
        let params: [String: Any] = ["client": "macos", "worktrees": shown.map { [$0] } ?? [],
                                     "app_active": NSApp.isActive]
        DispatchQueue.global(qos: .userInitiated).async { _ = CoreSocketClient.call("client.visible", params) }
    }

    /// The core decided a pane's edge is worth telling the user
    /// (`pane.notice`, the notification policy in `core-registry`): show it.
    func handleCoreNotice(_ n: [String: Any], terminalID: String?) {
        let path = n["worktree_path"] as? String ?? ""
        let newStatus = CoreDecode.status(n["new_status"]) ?? .idle
        let id = terminalID ?? ""
        NSLog("[notify] core notice pane=\(id.suffix(8)) \(n["old_status"] as? String ?? "")→\(newStatus.rawValue) " +
              "worktree=\(URL(fileURLWithPath: path).lastPathComponent)")
        // A pending card for this pane already shows that it needs input.
        if newStatus == .waiting, !id.isEmpty,
           cards.cards.contains(where: { $0.terminalID == id }) {
            return
        }
        let repoPath = worktreeRepoCache[path] ?? path
        let workspaceName = workspaceManager.tabs.first(where: { $0.repoPath == repoPath })?.displayName
            ?? URL(fileURLWithPath: repoPath).lastPathComponent
        NotificationManager.shared.show(
            worktreePath: path,
            workspaceName: workspaceName,
            branch: allWorktrees.first(where: { $0.info.path == path })?.info.branch ?? "",
            paneIndex: n["pane_index"] as? Int ?? 1,
            paneCount: n["pane_count"] as? Int ?? 1,
            terminalID: id,
            newStatus: newStatus,
            lastMessage: n["last_message"] as? String ?? "",
            lastUserPrompt: n["last_user_prompt"] as? String ?? "",
            lastAssistantMessage: n["last_assistant_message"] as? String ?? "",
            isTargetVisible: id.isEmpty ? (n["is_target_visible"] as? Bool ?? false)
                : isPaneFocused(worktreePath: path, terminalID: id))
    }



    /// A remote client opened a pane: its finished turn has been seen there.
    /// Station id or the stable session key, as remote callers hold either.
    func markPaneSeen(paneId: String) -> Bool {
        let stationId = StationRegistry.shared.station(forSessionName: paneId)?.id ?? paneId
        guard let pane = Fleet.shared.pane(for: stationId), pane.unseenCompletion else { return false }
        // The core owns the mark; it clears it and says so (`pane.unseen_changed`).
        let key = pane.station?.paneSessionKey ?? paneId
        DispatchQueue.global(qos: .userInitiated).async { _ = CoreSocketClient.call("pane.seen", ["pane_id": key]) }
        return true
    }

    // MARK: - First Mate


    /// Start, stop, pause or resume First Mate from config. Safe to call again.
    func applyAutopilotConfig() {
        // The core reads First Mate's settings from config.json itself; the
        // app follows what it reports.
        firstMate.start()
    }

    /// Every PR-able worktree with its branch's PR as last fetched. Main and the
    /// integration checkout are not PR work.
    func prObservations() -> [PRObservation] {
        allWorktrees.compactMap { entry in
            let info = entry.info
            guard !info.isMainWorktree, !info.branch.isEmpty,
                  !IntegrationWorktreeStore.shared.isIntegrationWorktree(info.path) else { return nil }
            return PRObservation(worktreePath: info.path, repoPath: worktreeRepoCache[info.path] ?? info.path,
                                 branch: info.branch,
                                 pr: WorktreePRStore.shared.status(worktreePath: info.path, branch: info.branch))
        }
    }



    /// Register every pane of a worktree's tree with Fleet — not just the first.
    /// A pane missing here cannot be resolved from its hook's SEAHELM_PANE_ID
    /// (`Fleet.handleWebhookEvent` only accepts a station that is a known agent),
    /// so its events — and any suggestion chip tapped for it — silently fall back
    /// to the worktree's FIRST pane. Restored splits are the common case: every
    /// pane comes back through here on launch, not through the split path.
    /// Each leaf registers under its own `paneSessionKey`, which is exactly what that
    /// pane exports as SEAHELM_PANE_ID.
    private func registerPanes(of info: WorktreeInfo, project: String, startedAt: Date?) {
        guard let tree = terminalCoordinator.stationManager.tree(forPath: info.path) else { return }
        for leaf in tree.allLeaves {
            guard let station = StationRegistry.shared.station(forId: leaf.stationId) else { continue }
            Fleet.shared.register(
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

    /// Structural control commands arrive with a pane identity, while
    /// TerminalCoordinator intentionally mutates only the dashboard's active
    /// split container. The Web client can mirror any worktree, so make that
    /// pane's worktree active before forwarding the command. Keeping
    /// `focusTerminal` false avoids stealing keyboard focus merely because a
    /// remote client requested a background split.
    private func preparePaneControlTarget(_ stationId: String?) -> Bool {
        guard let stationId else { return dashboardVC?.activeSplitContainer != nil }
        if dashboardVC?.activeSplitContainer?.tree?.allLeaves
            .contains(where: { $0.stationId == stationId }) == true {
            return true
        }
        guard let worktreePath = Fleet.shared.pane(for: stationId)?.worktreePath else {
            return false
        }
        dashboardVC?.selectPane(byWorktreePath: worktreePath, focusTerminal: false)
        saveSelectedWorktree()
        delegate?.tabCoordinatorRequestUpdateTitleBar(self)
        return dashboardVC?.activeSplitContainer?.tree?.allLeaves
            .contains(where: { $0.stationId == stationId }) == true
    }

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
    /// trees. Cleanup code uses this as the source of truth: if a seahelmd session is
    /// not in this set, no pane is using it right now.
    func livePaneSessionNames() -> Set<String> {
        guard runtimeBackend == "seahelmd" else { return [] }
        guard allConfiguredReposAreRepresented() else {
            NSLog("[TabCoordinator] Withholding live pane sessions — a configured repo has no worktrees")
            return []
        }
        var names = allWorktrees.flatMap { entry in
            entry.tree?.allLeaves.map(\.paneSessionKey) ?? []
        }
        // First Mate's session is the core's: never the app's to sweep.
        names.append(FirstMatePane.sessionName)
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

// MARK: - Panes the core starts and ends

extension TabCoordinator {
    /// seahelm-core registered a pane. One the app synced itself is already
    /// here and is ignored; a session the core started (`pane.new`, the web's
    /// "new pane") in a worktree the app shows joins that worktree's tree as a
    /// new split leaf attached to the running session — the same path a fork
    /// takes — without taking focus. A worktree with no tree yet takes the
    /// session as its first pane when it is opened (`CoreLink`'s adoptable
    /// sessions), so it is left alone here.
    func adoptCoreSession(_ paneSessionKey: String, worktreePath: String) {
        guard runtimeBackend != "local", !paneSessionKey.isEmpty,
              paneSessionKey != FirstMatePane.sessionName,
              StationRegistry.shared.station(forSessionName: paneSessionKey) == nil else { return }
        let manager = terminalCoordinator.stationManager
        guard !manager.claimedSessionNames.contains(paneSessionKey) else { return }
        let wanted = WorktreeDiscovery.canonicalPath(worktreePath)
        guard let info = allWorktrees.first(where: { WorktreeDiscovery.canonicalPath($0.info.path) == wanted })?.info,
              let tree = manager.tree(forPath: info.path) else { return }
        let focused = tree.focusedId
        installPane(sessionName: paneSessionKey, in: info, reveal: false)
        // `adopt` points the tree at the new leaf; the user was looking at
        // another one, and stays there.
        if let after = manager.tree(forPath: info.path), after.root.findLeaf(id: focused) != nil {
            after.focusedId = focused
            terminalCoordinator.saveSplitLayout(after)
        }
        NSLog("[TabCoordinator] Adopted core session \(paneSessionKey) into \(info.path)")
    }

    /// seahelm-core ended a pane because a client asked (`pane.close`): take
    /// its leaf down without the close-last-pane prompt and without killing
    /// anything — the session is already gone. The station is marked first so
    /// its health check cannot read the dead session as one to recreate.
    func removePaneEndedByRequest(paneSessionKey: String) {
        guard !paneSessionKey.isEmpty,
              let station = StationRegistry.shared.station(forSessionName: paneSessionKey) else { return }
        station.sessionEndedElsewhere = true
        let manager = terminalCoordinator.stationManager
        guard let (tree, leafId) = manager.locate(stationId: station.id) else { return }
        let path = tree.worktreePath
        AgentSessionRef.forget(paneSessionKey)
        Fleet.shared.unregister(terminalID: station.id)
        if tree.leafCount > 1 {
            _ = tree.removeLeaf(id: leafId)
            station.view?.removeFromSuperview()
            station.destroy()
            StationRegistry.shared.unregister(station.id)
            terminalCoordinator.saveSplitLayout(tree)
            dashboardVC?.invalidateSplitContainer(forPath: path)
            dashboardVC?.updatePanes(buildWorktreeRowInfos())
            statusAggregator.sync(trees: manager.all)
            delegate?.tabCoordinatorRequestUpdateTitleBar(self)
        } else {
            terminalCoordinator.config.splitLayouts.removeValue(forKey: path)
            terminalCoordinator.config.focusedPaneIds.removeValue(forKey: path)
            terminalCoordinator.config.save()
            manager.removeTree(forPath: path)
            delegate?.tabCoordinatorRequestUpdateTitleBar(self)
            worktreeSessionDidEnd(path)
        }
        NSLog("[TabCoordinator] Pane \(paneSessionKey) closed by request; leaf removed")
    }
}

extension TabCoordinator {
    /// Deadline for one FirstMate inspection command (a test suite, a build, a
    /// lint pass). Generous, but bounded — a hung command must not park a
    /// background thread for the rest of the session.
    static let inspectionCommandTimeout: TimeInterval = 15 * 60

    /// Deadline for the auto-commit pair. Wide enough for a big `add -A` plus
    /// whatever pre-commit hooks the repo installs.
    static let autoCommitTimeout: TimeInterval = 5 * 60

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
        let rows = buildWorktreeRowInfos()
        let items = rows.map {
            $0.groupingItem(
                creationDate: DashboardOverviewView.creationDate($0.worktreePath),
                isIntegration: IntegrationWorktreeStore.shared.isIntegrationWorktree($0.worktreePath)
            )
        }
        // The row's words, as the dashboard draws them — kept out of the
        // grouping item itself, whose equality decides when the dashboard
        // regroups, and a title changes far more often than a group does.
        var words: [String: (title: String, subtitle: String)] = [:]
        var prs: [String: WorktreePRStatus] = [:]
        for row in rows {
            words[row.worktreePath] = (row.rowTitle ?? PaneTitleResolver.shortenPath(row.worktreePath),
                                       row.rowSubtitle)
            prs[row.worktreePath] = row.prStatus
        }
        return WorktreeGrouping
            .groups(items, mode: WorktreeGroupingMode(wire: mode), now: Date())
            .map { group in
                var dict = group.dict
                dict["items"] = (dict["items"] as? [[String: Any]] ?? []).map { item in
                    var item = item
                    if let path = item["worktree_path"] as? String, let row = words[path] {
                        item["title"] = row.title
                        item["subtitle"] = row.subtitle
                    }
                    if let path = item["worktree_path"] as? String, let pr = prs[path] {
                        item["pr"] = pr.dict
                    }
                    return item
                }
                return dict
            }
    }
}
