import AppKit

enum WindowStyling {
    struct GlassBackgroundConfig {
        let enabled: Bool
        let material: NSVisualEffectView.Material
        let blendingMode: NSVisualEffectView.BlendingMode
    }

    static func glassBackgroundConfig(isDark: Bool) -> GlassBackgroundConfig {
        if isDark {
            return GlassBackgroundConfig(enabled: true, material: .hudWindow, blendingMode: .behindWindow)
        }
        return GlassBackgroundConfig(enabled: true, material: .underWindowBackground, blendingMode: .behindWindow)
    }

    static func shouldUseWindowFrameAutosave(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
        if arguments.contains("-SeahelmUITesting") {
            return false
        }
        if let idx = arguments.firstIndex(of: "-ApplePersistenceIgnoreState"),
           arguments.indices.contains(idx + 1),
           arguments[idx + 1].caseInsensitiveCompare("YES") == .orderedSame {
            return false
        }
        return true
    }

    static func shouldHandleEscShortcut() -> Bool {
        false
    }

    static func trafficLightButtonOriginY(containerHeight: CGFloat, buttonHeight: CGFloat) -> CGFloat {
        (containerHeight / 2) + TitleBarView.Layout.arcVerticalOffset - (buttonHeight / 2)
    }
}

class MainWindowController: NSWindowController {
    private static let primaryCapsuleDisplayDuration: TimeInterval = 8.0

    private let titleBar = TitleBarView()
    private let backgroundEffectView = NSVisualEffectView()
    private let contentContainer = NSView()
    private let statusBar = StatusBarView()
    let keyboardMode = KeyboardModeController()
    private var windowTrackingArea: NSTrackingArea?
    private lazy var panelCoordinator: PanelCoordinator = {
        let pc = PanelCoordinator()
        pc.delegate = self
        pc.titleBar = titleBar
        return pc
    }()
    private let titleBarAccessory = NSTitlebarAccessoryViewController()

    private var dashboardVC: DashboardViewController?
    private var config = Config.load()
    private var runtimeBackend: String = "zmx"
    private var primaryCapsuleNotification: NotificationEntry?
    private var dismissedPrimaryCapsuleNotificationIDs: Set<UUID> = []
    private var primaryCapsuleDismissWorkItem: DispatchWorkItem?
    private var capsuleToken = 0
    private lazy var usageSummaryStore = UsageSummaryStore()

    // Terminal management
    private lazy var terminalCoordinator: TerminalCoordinator = {
        let tc = TerminalCoordinator(config: config, activeSplitContainer: { [weak self] in
            self?.tabCoordinator.dashboardVC?.activeSplitContainer
        })
        tc.delegate = self
        return tc
    }()

    // Tab/workspace management
    lazy var tabCoordinator: TabCoordinator = {
        let tc = TabCoordinator(config: config)
        tc.delegate = self
        tc.terminalCoordinator = terminalCoordinator
        tc.statusPublisher = statusPublisher
        tc.statusAggregator = statusAggregator
        tc.runtimeBackend = runtimeBackend
        tc.panelCoordinator = panelCoordinator
        return tc
    }()

    // Dialog presentation
    private lazy var dialogPresenter: DialogPresenter = {
        DialogPresenter(
            tabCoordinator: tabCoordinator,
            terminalCoordinator: terminalCoordinator,
            statusPublisher: statusPublisher
        )
    }()

    // Auto-update
    private lazy var updateCoordinator: UpdateCoordinator = {
        let uc = UpdateCoordinator(config: config)
        uc.delegate = self
        uc.banner.delegate = uc
        return uc
    }()

    // Status detection
    private let statusAggregator = WorktreeStatusAggregator()
    private lazy var statusPublisher: StatusPublisher = {
        let pub = StatusPublisher(agentConfig: config.agentDetect)
        pub.aggregator = statusAggregator
        statusAggregator.delegate = self
        statusAggregator.seedLastActivity(persistedActivityMap())
        statusAggregator.onActivity = { [weak self] path, date in
            self?.recordWorktreeActivity(path, date)
        }
        return pub
    }()

    private static let activityISO8601 = ISO8601DateFormatter()

    /// Persisted per-worktree last-activity times, parsed from config.
    private func persistedActivityMap() -> [String: Date] {
        var map: [String: Date] = [:]
        for (path, iso) in config.worktreeLastActivityAt {
            if let date = Self.activityISO8601.date(from: iso) { map[path] = date }
        }
        return map
    }

    /// Persist a worktree's advanced last-activity time (debounced via Config.save()).
    private func recordWorktreeActivity(_ path: String, _ date: Date) {
        let iso = Self.activityISO8601.string(from: date)
        config.worktreeLastActivityAt[path] = iso
        tabCoordinator.config.worktreeLastActivityAt[path] = iso
        config.save()
    }

    convenience init() {
        let window = SeahelmWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "seahelm"
        window.minSize = NSSize(width: 600, height: 400)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear

        // Set window appearance from config (already applied globally in main.swift)
        window.appearance = NSApp.appearance

        self.init(window: window)

        // Prevent macOS from creating duplicate windows via state restoration
        window.isRestorable = false

        if WindowStyling.shouldUseWindowFrameAutosave() {
            window.setFrameAutosaveName("SeahelmMainWindow")
        } else if let visibleFrame = NSScreen.main?.visibleFrame {
            let width = min(1200, visibleFrame.width * 0.9)
            let height = min(800, visibleFrame.height * 0.9)
            let x = visibleFrame.midX - (width / 2)
            let y = visibleFrame.midY - (height / 2)
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        }
        window.delegate = self

        setupMenuShortcuts()
        setupLayout()
        updateCoordinator.setup(config: config)
        normalizeBackendAvailabilityIfNeeded()
        tabCoordinator.loadWorkspaces()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleNavigateToWorktree(_:)),
            name: .navigateToWorktree, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleNotificationHistoryDidChange(_:)),
            name: .notificationHistoryDidChange, object: nil
        )
        handleNotificationHistoryDidChange(nil)
        usageSummaryStore.onUpdate = { [weak self] frames in
            let usageText = frames
                .filter { $0.kind == .usage }
                .map { frame in
                    [frame.leadingText, frame.bodyText, frame.trailingText]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                }
                .filter { !$0.isEmpty }
                .joined(separator: "  \u{00B7}  ")
            self?.statusBar.updateUsage(text: usageText)
        }
        usageSummaryStore.start()
    }

    /// Sync split layouts from TerminalCoordinator before saving config.
    /// Config is a value type — without syncing, saves here overwrite
    /// splitLayouts written by TerminalCoordinator with stale data.
    private func saveConfig() {
        // Sync fields that TabCoordinator may have updated independently
        config.workspacePaths = tabCoordinator.config.workspacePaths
        config.cardOrder = tabCoordinator.config.cardOrder
        config.worktreeStartedAt = tabCoordinator.config.worktreeStartedAt
        config.selectedWorktreePath = tabCoordinator.config.selectedWorktreePath
        config.splitLayouts = terminalCoordinator.config.splitLayouts
        config.save()
    }

    // MARK: - Menu Shortcuts

    private func setupMenuShortcuts() {
        NSApp.mainMenu = MenuBuilder.buildMainMenu(target: self)
    }

    private func normalizeBackendAvailabilityIfNeeded() {
        BackendResolver.resolveAsync(preferred: config.backend) { [weak self] resolution in
            guard let self else { return }
            self.runtimeBackend = resolution.backend
            self.tabCoordinator.runtimeBackend = resolution.backend
            if resolution.warningMessage == nil, resolution.backend != self.config.backend {
                self.config.backend = resolution.backend
                self.saveConfig()
            }
            BackendResolver.showWarningIfNeeded(resolution, configBackend: self.config.backend)
        }
    }

    @objc func switchToDashboard() {
        switchToTab(0)
    }

    @objc func showQuickSwitcher() {
        let switcher = dialogPresenter.makeQuickSwitcher(quickSwitcherDelegate: self)
        dialogPresenter.presentSheetOnActiveVC(switcher, tabCoordinator: tabCoordinator, dashboardVC: dashboardVC)
    }

    @objc func showSettings() {
        let settingsVC = dialogPresenter.makeSettings(config: config, settingsDelegate: self)
        dialogPresenter.presentSheetOnActiveVC(settingsVC, tabCoordinator: tabCoordinator, dashboardVC: dashboardVC)
    }

    @objc func showNewBranchDialog() {
        // Cmd+N now focuses the inline worktree creator in the sidebar instead of
        // presenting the modal dialog. The modal builder (makeNewBranchDialog) and
        // NewBranchDialog remain available but are no longer triggered here.
        tabCoordinator.switchToTab(0)
        dashboardVC?.focusInlineCreate()
    }

    @objc func closeCurrentTab() {
        // No-op: dashboard is always the only tab; individual project close is handled via dashboard UI.
    }

    /// Cmd+W: close focused pane if multiple panes, otherwise close tab.
    @objc func closePaneOrTab() {
        if let tree = tabCoordinator.dashboardVC?.activeSplitContainer?.tree,
           tree.leafCount > 1 {
            closeFocusedPane()
        } else {
            closeCurrentTab()
        }
    }

    @objc func selectNextTab() {
        // No-op: only the dashboard tab exists.
    }

    @objc func selectPreviousTab() {
        // No-op: only the dashboard tab exists.
    }

    @objc func showKeyboardShortcuts() {
        DialogPresenter.showKeyboardShortcuts()
    }

    @objc func openDocumentation() {
        let repositoryURL = URL(string: "https://github.com/\(UpdateChecker.repositoryOwner)/\(UpdateChecker.repositoryName)")!
        NSWorkspace.shared.open(repositoryURL)
    }

    @objc func cleanOrphanSessions() {
        let configSnapshot = config
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard ZmxLocator.isAvailable else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "zmx is not available"
                    alert.informativeText = "Install zmx first to clean orphan sessions."
                    alert.runModal()
                }
                return
            }

            let worktreePaths = configSnapshot.workspacePaths.flatMap { repoPath in
                WorktreeDiscovery.discover(repoPath: repoPath).map(\.path)
            }
            let activeSessionNames = SessionManager.expectedSessionNames(
                config: configSnapshot,
                discoveredWorktreePaths: worktreePaths
            )
            let cleaned = SessionManager.cleanupOrphanZmxSessions(activeSessionNames: activeSessionNames)

            DispatchQueue.main.async {
                guard let self else { return }
                let alert = NSAlert()
                alert.messageText = cleaned.isEmpty
                    ? "No orphan sessions found"
                    : "Cleaned \(cleaned.count) orphan session(s)"
                if cleaned.isEmpty {
                    alert.informativeText = "All seahelm zmx sessions are still referenced by the current config and worktrees."
                } else {
                    alert.informativeText = cleaned.joined(separator: "\n")
                }
                alert.runModal()
                self.handleNotificationHistoryDidChange(nil)
            }
        }
    }

    // MARK: - Layout

    private func setupLayout() {
        guard let contentView = window?.contentView else { return }

        setupNativeTitleBar()

        // Update banner (above title bar, hidden by default)
        updateCoordinator.banner.translatesAutoresizingMaskIntoConstraints = false
        updateCoordinator.banner.isHidden = true
        contentView.addSubview(updateCoordinator.banner)

        backgroundEffectView.translatesAutoresizingMaskIntoConstraints = false
        backgroundEffectView.state = .followsWindowActiveState
        contentView.addSubview(backgroundEffectView, positioned: .below, relativeTo: nil)

        // Content container (fills middle)
        contentContainer.wantsLayer = true
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentContainer)

        // Fixed-height bottom status bar
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusBar)
        keyboardMode.delegate = self
        statusBar.updateMode(keyboardMode.mode, hint: keyboardMode.hintText)

        NSLayoutConstraint.activate([
            backgroundEffectView.topAnchor.constraint(equalTo: contentView.topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            updateCoordinator.banner.topAnchor.constraint(equalTo: contentView.topAnchor),
            updateCoordinator.banner.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            updateCoordinator.banner.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            contentContainer.topAnchor.constraint(equalTo: updateCoordinator.banner.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.height),
        ])

        // Window hover tracking for arc block styling
        setupWindowHoverTracking(contentView: contentView)

        // Create dashboard — single permanent LeftRight layout
        let dashboard = DashboardViewController()
        dashboard.dashboardDelegate = self
dashboard.stationManager = terminalCoordinator.stationManager
        dashboard.splitContainerDelegate = self
        dashboardVC = dashboard
        tabCoordinator.dashboardVC = dashboard

        dashboard.sidePanelVC.pendingOrdersQueue = tabCoordinator.pendingOrders
        dashboard.sidePanelVC.watchFeed = tabCoordinator.watchFeed
        dashboard.sidePanelVC.onSuggestionTapped = { [weak self] order, optionText in
            self?.handleSuggestionTapped(order: order, optionText: optionText)
        }
        dashboard.sidePanelVC.onBridgeNavigate = { [weak self] path in
            self?.tabCoordinator.selectTab(forWorktree: path)
        }
        dashboard.sidePanelVC.onBridgeApprove = { [weak self] order in
            self?.handleBridgeApprove(order)
        }

        // Helm cockpit (WP-2) shares the same queue/feed/handlers as the sidebar.
        dashboard.helmCockpit.pendingOrdersQueue = tabCoordinator.pendingOrders
        dashboard.helmCockpit.watchFeed = tabCoordinator.watchFeed
        dashboard.helmCockpit.onSuggestionTapped = { [weak self] order, optionText in
            self?.handleSuggestionTapped(order: order, optionText: optionText)
        }
        dashboard.helmCockpit.onNavigate = { [weak self] path in
            self?.tabCoordinator.selectTab(forWorktree: path)
        }
        dashboard.helmCockpit.onApprove = { [weak self] order in
            self?.handleBridgeApprove(order)
        }
        // Install the cockpit into the window content view spanning the content
        // container AND the status bar, so the radar orb bottom-aligns with the
        // status bar. (force-load dashboard.view first so its child VC is ready.)
        _ = dashboard.view
        if let host = contentContainer.superview {
            dashboard.installCockpit(in: host, top: contentContainer.topAnchor)
        }
        dashboard.helmCockpit.onSubmitCommand = { [weak self] text, onWorktreeCreated in
            self?.submitBridgeCommand(text, onWorktreeCreated: onWorktreeCreated) ?? false
        }
        dashboard.helmCockpit.commandMenuProvider = { [weak self] trigger, query in
            self?.helmMenuItems(trigger: trigger, query: query) ?? []
        }

        dashboard.onEnterTerminal = { [weak self] in self?.keyboardMode.enterInsert() }
        dashboard.onRequestNewWorktree = { [weak self] in
            // Opens the Helm cockpit with `/new ` prefilled (the inline creator and
            // its createForm keyboard substate were removed).
            self?.tabCoordinator.dashboardVC?.focusInlineCreate()
        }
        dashboard.onInlineCreateFormEnd = { [weak self] in
            self?.keyboardMode.endCreateForm()
            self?.tabCoordinator.dashboardVC?.enterDashboardNavigation()
        }

        dashboard.setupInlineCreate(
            repoPaths: config.workspacePaths,
            repoPathsProvider: { [weak self] in self?.tabCoordinator.config.workspacePaths ?? [] },
            onAddRepo: { [weak self] in self?.tabCoordinator.addRepoViaOpenPanel(window: self?.window) },
            onSubmitCommand: { [weak self] text in self?.submitBridgeCommand(text) }
        ) { [weak self] taskDescription, repoPath, agentType, reuseEnv in
            self?.performWorktreeCreate(task: taskDescription, repoPath: repoPath, agentType: agentType, reuseEnv: reuseEnv)
        }

        embedViewController(dashboard)
        updateTitleBar()

        applyWindowBackgroundStyle()
        positionStandardWindowButtons()
    }

    /// Creates a worktree off the main thread. `onComplete` fires on the main
    /// thread with the new worktree's path on success, or nil on failure —
    /// lets the caller (e.g. the Helm cockpit) drop its loading state and
    /// dismiss once the new tab is ready.
    private func performWorktreeCreate(task: String, repoPath: String, agentType: SailorType, reuseEnv: Bool,
                                       onComplete: ((String?) -> Void)? = nil) {
        let currentPath = tabCoordinator.selectedSailor?.worktreePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let branches = WorktreeCreator.listBranches(repoPath: repoPath)
            let base = branches.contains("main") ? "main" : (branches.contains("master") ? "master" : (branches.first ?? "main"))
            do {
                let branchName = WorktreeCreator.branchName(fromTaskDescription: task, existingBranches: branches)
                let info = try WorktreeCreator.createWorktree(repoPath: repoPath, branchName: branchName, baseBranch: base)
                WorktreeSailorTypeStore.shared.set(agentType, forWorktree: info.path)
                WorktreeTaskStore.shared.set(task, forWorktree: info.path)
                if reuseEnv, let currentPath { WorktreeCreator.copyEnvironmentFiles(from: currentPath, to: info.path) }
                if let agentCommandLine = agentType.launchCommand(withTask: task) {
                    SessionManager.createDetachedSession(
                        name: SessionManager.persistentSessionName(for: info.path),
                        backend: self.runtimeBackend,
                        cwd: info.path,
                        agentCommandLine: agentCommandLine
                    )
                }
                DispatchQueue.main.async {
                    self.tabCoordinator.handleNewBranch(info: info, repoPath: repoPath)
                    self.dashboardVC?.inlineCreateReportSuccess()
                    onComplete?(info.path)
                }
            } catch {
                DispatchQueue.main.async {
                    NSSound.beep()
                    self.dashboardVC?.inlineCreateReportFailure(error.localizedDescription)
                    onComplete?(nil)
                }
            }
        }
    }

    private func currentWorktreeRefs() -> [WorktreeRef] {
        ShipLog.shared.allSailors().map { WorktreeRef(branch: $0.branch, path: $0.worktreePath) }
    }

    /// Autocomplete data for the Helm command line.
    /// `/` commands · `@` worktrees/branches · `#` agent types.
    private func helmMenuItems(trigger: Character, query: String) -> [(name: String, desc: String)] {
        let pool: [(name: String, desc: String)]
        switch trigger {
        case "/":
            pool = [
                ("new", "开启一个新任务会话"),
                ("order", "向 agent 下达指令"),
                ("commit", "提交并推送当前改动"),
                ("return", "召回 agent · 结束会话"),
                ("broadcast", "向全员广播通知"),
            ]
        case "@":
            let repos = tabCoordinator.config.workspacePaths.map {
                (URL(fileURLWithPath: $0).lastPathComponent, "repo · \($0)")
            }
            let worktrees = ShipLog.shared.allSailors().map { ($0.branch, "worktree · \($0.project)") }
            pool = repos + worktrees
        case "#":
            pool = [
                ("claude", "Claude Code"),
                ("codex", "codex-cli"),
                ("opencode", "opencode"),
            ]
        default:
            pool = []
        }
        guard !query.isEmpty else { return pool }
        return pool.filter { $0.name.lowercased().contains(query) }
    }

    private func makeBridgeRouter() -> BridgeCommandRouter {
        BridgeCommandRouter(
            queue: tabCoordinator.pendingOrders,
            createWorktree: { [weak self] task, repoHint in
                guard let self else { return }
                let paths = self.tabCoordinator.config.workspacePaths
                let repoPath = repoHint ?? paths.first ?? ""
                self.performWorktreeCreate(task: task, repoPath: repoPath, agentType: .claudeCode, reuseEnv: false)
            },
            orderExisting: { path, task in
                guard let tid = ShipLog.shared.sailor(forWorktree: path)?.id else { return }
                ShipLog.shared.sendCommand(to: tid, command: task)
            },
            commit: { path in
                guard let tid = ShipLog.shared.sailor(forWorktree: path)?.id else { return }
                ShipLog.shared.sendCommand(to: tid, command: "git add -A && git commit -m 'wip'")
            },
            returnWorktree: { [weak self] path in
                self?.enqueueReturnCard(forPath: path)
            },
            returnAll: { [weak self] in
                guard let self else { return }
                let worktrees = self.tabCoordinator.allWorktrees
                    .map(\.info)
                    .filter { !$0.isMainWorktree }
                for info in worktrees {
                    self.enqueueReturnCard(forPath: info.path)
                }
            },
            activeSailorCount: { ShipLog.shared.allSailors().count },
            branchForPath: { path in ShipLog.shared.sailor(forWorktree: path)?.branch ?? "" },
            projectForPath: { path in ShipLog.shared.sailor(forWorktree: path)?.project ?? "" }
        )
    }

    /// Run a merge check for `path` on a background thread and enqueue a
    /// return-to-port card with appropriate options once the check completes.
    private func enqueueReturnCard(forPath path: String) {
        let repoCache = tabCoordinator.worktreeRepoCache
        let queue = tabCoordinator.pendingOrders
        let sailor = ShipLog.shared.sailor(forWorktree: path)
        let branch = sailor?.branch
            ?? tabCoordinator.allWorktrees.first(where: { $0.info.path == path })?.info.branch
            ?? URL(fileURLWithPath: path).lastPathComponent
        let project = sailor?.project
            ?? tabCoordinator.allWorktrees.first(where: { $0.info.path == path })?.info.branch
            ?? ""

        DispatchQueue.global(qos: .userInitiated).async {
            let repoPath = repoCache[path] ?? WorktreeDiscovery.findRepoRoot(from: path) ?? path
            let check = WorktreeDeleter.mergeCheckForOnlineMainOrMaster(
                worktreePath: path, repoPath: repoPath)

            let options: [String]
            let zone: FirstMateZone
            if check.canDelete {
                options = ["Remove", "Remove + Branch"]
                zone = .green
            } else {
                options = ["Force remove"]
                zone = .red
            }

            let action = FirstMateAction(
                kind: .returnToPort, zone: zone,
                worktreePath: path, branch: branch, project: project,
                terminalID: "",
                message: check.reason,
                options: options)

            DispatchQueue.main.async { queue.enqueue(action) }
        }
    }

    /// Submit a Helm command. Returns `true` if it kicked off asynchronous
    /// worktree creation (so the caller can show a loading state); `onWorktreeCreated`
    /// then fires with success/failure when the new tab is ready. Non-creation
    /// commands route synchronously and return `false`.
    @discardableResult
    func submitBridgeCommand(_ text: String, onWorktreeCreated: ((Bool) -> Void)? = nil) -> Bool {
        switch BridgeCommandParser.parse(text, worktrees: currentWorktreeRefs(),
                                         repoPaths: tabCoordinator.config.workspacePaths) {
        case .success(let command):
            if case .newWorktree(let task, let repoHint) = command {
                let repoPath = repoHint ?? tabCoordinator.config.workspacePaths.first ?? ""
                performWorktreeCreate(task: task, repoPath: repoPath, agentType: .claudeCode,
                                      reuseEnv: false) { path in
                    onWorktreeCreated?(path != nil)
                }
                return true
            }
            makeBridgeRouter().route(command)
            return false
        case .failure:
            NSSound.beep()
            return false
        }
    }

    private func applyWindowBackgroundStyle() {
        guard let window else { return }
        let isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let config = WindowStyling.glassBackgroundConfig(isDark: isDark)

        backgroundEffectView.material = config.material
        backgroundEffectView.blendingMode = config.blendingMode
        backgroundEffectView.isHidden = !config.enabled

        window.isOpaque = !config.enabled
        window.backgroundColor = config.enabled ? .clear : Theme.background
    }

    private func setupNativeTitleBar() {
        guard let window else { return }

        let toolbar = NSToolbar(identifier: "seahelm.mainToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact

        titleBar.delegate = self
        titleBar.translatesAutoresizingMaskIntoConstraints = false

        let accessoryContainer = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: TitleBarView.Layout.barHeight))
        accessoryContainer.translatesAutoresizingMaskIntoConstraints = false
        accessoryContainer.addSubview(titleBar)
        NSLayoutConstraint.activate([
            titleBar.leadingAnchor.constraint(equalTo: accessoryContainer.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: accessoryContainer.trailingAnchor),
            titleBar.topAnchor.constraint(equalTo: accessoryContainer.topAnchor),
            titleBar.bottomAnchor.constraint(equalTo: accessoryContainer.bottomAnchor),
            accessoryContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 860),
        ])

        titleBarAccessory.view = accessoryContainer
        titleBarAccessory.fullScreenMinHeight = TitleBarView.Layout.barHeight
        titleBarAccessory.layoutAttribute = .top
        if !window.titlebarAccessoryViewControllers.contains(where: { $0 === titleBarAccessory }) {
            window.addTitlebarAccessoryViewController(titleBarAccessory)
        }

        DispatchQueue.main.async { [weak self] in
            self?.positionStandardWindowButtons()
        }
    }

    private func positionStandardWindowButtons() {
        guard let window else { return }
        guard let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let container = close.superview
        else {
            return
        }

        let xOffset: CGFloat = 12
        let spacing: CGFloat = 6

        let y = WindowStyling.trafficLightButtonOriginY(containerHeight: container.bounds.height, buttonHeight: close.frame.height)
        close.setFrameOrigin(NSPoint(x: xOffset, y: y))
        mini.setFrameOrigin(NSPoint(x: xOffset + close.frame.width + spacing, y: y))
        zoom.setFrameOrigin(NSPoint(x: xOffset + (close.frame.width + spacing) * 2, y: y))
    }

    private func setupWindowHoverTracking(contentView: NSView) {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(area)
        windowTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        titleBar.setWindowHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        titleBar.setWindowHovered(false)
    }

    private func embedViewController(_ vc: NSViewController) {
        for child in contentContainer.subviews {
            child.removeFromSuperview()
        }

        vc.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            vc.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func updateTitleBar() {
        titleBar.updateChromeState(
            isGridLayout: false,
            hasWorkspaces: !tabCoordinator.workspaceManager.tabs.isEmpty,
            canCleanWorktrees: tabCoordinator.allWorktrees.contains { !$0.info.isMainWorktree }
        )
        refreshWorktreeTabs()
        updatePrimaryCapsuleNotification()
        refreshFocusedWorktreeCapsule()
    }

    /// Worktrees with no agent interaction for longer than this collapse into
    /// the title-bar overflow menu instead of occupying a tab slot.
    private static let tabIdleCollapseInterval: TimeInterval = 8 * 3600

    private func refreshWorktreeTabs() {
        let selectedPath = tabCoordinator.selectedSailor?.worktreePath
        let now = Date()
        let tabs = tabCoordinator.allWorktrees.map { entry -> (path: String, title: String, agentGlyph: String?, agentColor: NSColor, statusColor: NSColor, paneCount: Int, isSelected: Bool, collapsed: Bool) in
            let path = entry.info.path
            let paneCount = terminalCoordinator.stationManager.tree(forPath: path)?.leafCount ?? 1
            let repo = tabCoordinator.repoName(forWorktree: path)
            let name = entry.info.branch.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : entry.info.branch
            // Keep more text than the inline tab needs — the overflow menu wraps it to 2 lines.
            let title = TitleBarView.clampTitle("\(repo) · \(name)", limit: 56)

            let agent = ShipLog.shared.sailor(forWorktree: path)
            let statusColor = agent?.status.color ?? NSColor(hex: 0x555555)
            let agentGlyph = agent?.agentType.tabGlyph
            let agentColor: NSColor
            switch agent?.agentType {
            case .claudeCode: agentColor = NSColor(hex: 0xff8a3d)  // orange
            case .codex:      agentColor = NSColor(hex: 0x5b93f0)  // cornflower
            default:          agentColor = Theme.accent
            }
            let isSelected = path == selectedPath

            // Idle = the most recent pane status/message change (a signal that
            // only advances on real activity, not background polling) is older
            // than the collapse interval. The selected worktree stays visible.
            // The main worktree (base repo / main branch) is never collapsed —
            // it always stays pinned at the top of the list.
            let lastActivity = statusAggregator.lastActivity(for: path) ?? agent?.startedAt
            let isIdle = lastActivity.map { now.timeIntervalSince($0) > Self.tabIdleCollapseInterval } ?? false
            let collapsed = isIdle && !isSelected && !entry.info.isMainWorktree

            return (path: path, title: title, agentGlyph: agentGlyph, agentColor: agentColor, statusColor: statusColor, paneCount: paneCount, isSelected: isSelected, collapsed: collapsed)
        }
        titleBar.setWorktreeTabs(tabs)

        // Radar animates only while some agent is actively running or waiting.
        let radarActive = ShipLog.shared.allSailors().contains {
            $0.status == .running || $0.status == .waiting
        }
        dashboardVC?.helmCockpit.setRadarActive(radarActive)

        tabCoordinator.dashboardVC?.updateFleetSummary(
            repos: tabCoordinator.workspaceManager.tabs.count,
            worktrees: tabs.count,
            hidden: tabs.filter(\.collapsed).count
        )
        tabCoordinator.dashboardVC?.idleWorktreePaths = Set(tabs.filter(\.collapsed).map(\.path))
    }

    private func refreshFocusedWorktreeCapsule() {
        guard let agent = tabCoordinator.selectedSailor else {
            titleBar.updateFocusedWorktree(title: "", path: "")
            return
        }
        let path = agent.worktreePath
        // Prefer prompt/branch already on the display info; fall back to ShipLog.
        let info = ShipLog.shared.sailor(forWorktree: path)
        let prompt = info?.lastUserPrompt ?? ""
        let branch = info?.branch ?? ""
        capsuleToken += 1
        let token = capsuleToken
        WorktreeTitleCache.shared.title(worktreePath: path, lastUserPrompt: prompt, branch: branch) { [weak self] title in
            guard let self, token == self.capsuleToken else { return }
            self.titleBar.updateFocusedWorktree(title: title, path: path)
        }
    }



    // MARK: - Forwarding to TabCoordinator

    @discardableResult
    func integrateDiscoveredRepoForTesting(repoPath: String, worktrees: [WorktreeInfo], activateTab: Bool = true) -> Int {
        tabCoordinator.integrateDiscoveredRepo(repoPath: repoPath, worktrees: worktrees, activateTab: activateTab)
    }

    private func switchToTab(_ index: Int) {
        tabCoordinator.switchToTab(index)
    }

    private func confirmAndDeleteWorktree(_ info: WorktreeInfo) {
        terminalCoordinator.confirmAndDeleteWorktree(info, window: window)
    }

    private func worktreeDidDelete(_ info: WorktreeInfo) {
        tabCoordinator.worktreeDidDelete(info)
    }

    deinit {
        primaryCapsuleDismissWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self, name: .navigateToWorktree, object: nil)
        NotificationCenter.default.removeObserver(self, name: .notificationHistoryDidChange, object: nil)
    }

    // MARK: - Split Pane Actions (forwarded to TerminalCoordinator)

    func splitFocusedPane(axis: SplitAxis) {
        terminalCoordinator.splitFocusedPane(axis: axis)
    }

    func closeFocusedPane() {
        terminalCoordinator.closeFocusedPane()
    }

    func moveFocus(_ axis: SplitAxis, positive: Bool) {
        terminalCoordinator.moveFocus(axis, positive: positive)
    }

    func resizeSplit(_ axis: SplitAxis, delta: CGFloat) {
        terminalCoordinator.resizeSplit(axis, delta: delta)
    }

    func resetSplitRatio() {
        terminalCoordinator.resetSplitRatio()
    }

}

class SeahelmWindow: NSWindow {

    // performKeyEquivalent runs BEFORE menu item key equivalents,
    // so split pane shortcuts here take priority over menu bindings.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let mwc = windowController as? MainWindowController else {
            return super.performKeyEquivalent(with: event)
        }

        // Only handle split keybindings when dashboard has an active split container
        let hasSplitContext = mwc.tabCoordinator.dashboardVC?.activeSplitContainer != nil

        // Arrow keys carry .numericPad and .function flags on macOS; strip them
        // so modifier comparisons match what the user actually pressed.
        let baseFlags = flags.subtracting([.numericPad, .function])

        if hasSplitContext {
            // Cmd+D: horizontal split
            if flags == .command && event.charactersIgnoringModifiers == "d" {
                mwc.splitFocusedPane(axis: .horizontal)
                return true
            }

            // Cmd+Shift+D: vertical split
            if flags == [.command, .shift] && event.charactersIgnoringModifiers?.lowercased() == "d" {
                mwc.splitFocusedPane(axis: .vertical)
                return true
            }

            // Cmd+Option+Arrows: focus navigation
            if baseFlags == [.command, .option] {
                switch event.keyCode {
                case 123: mwc.moveFocus(.horizontal, positive: false); return true
                case 124: mwc.moveFocus(.horizontal, positive: true); return true
                case 125: mwc.moveFocus(.vertical, positive: true); return true
                case 126: mwc.moveFocus(.vertical, positive: false); return true
                default: break
                }
            }

            // Cmd+Ctrl+Arrows: resize
            if baseFlags == [.command, .control] {
                switch event.keyCode {
                case 123: mwc.resizeSplit(.horizontal, delta: -0.05); return true
                case 124: mwc.resizeSplit(.horizontal, delta: 0.05); return true
                case 125: mwc.resizeSplit(.vertical, delta: 0.05); return true
                case 126: mwc.resizeSplit(.vertical, delta: -0.05); return true
                default: break
                }
            }

            // Cmd+Ctrl+=: reset ratio
            if flags == [.command, .control] && event.charactersIgnoringModifiers == "=" {
                mwc.resetSplitRatio()
                return true
            }
        }

        // Cmd+B: toggle left column collapse
        if flags == .command && event.charactersIgnoringModifiers == "b" {
            mwc.tabCoordinator.dashboardVC?.toggleLeftColumnCollapse()
            return true
        }

        // Cmd+Esc: exit insert mode → normal (Cmd is intercepted before terminal)
        if flags == .command && event.keyCode == 53 {
            if mwc.keyboardMode.handleEsc(hasCommand: true, now: ProcessInfo.processInfo.systemUptime) {
                mwc.tabCoordinator.dashboardVC?.enterDashboardNavigation()
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // Escape: exit spotlight (existing)
            if event.keyCode == 53, WindowStyling.shouldHandleEscShortcut() {
                return
            }
            // Cmd+Esc in insert mode → normal.
            // macOS does not route Cmd+Esc through performKeyEquivalent the way it
            // does Cmd+<letter>, so it lands here. Read the real Command flag instead
            // of assuming a plain Esc — otherwise Cmd+Esc gets mis-handled as a single
            // Esc and passes through to the terminal (interrupting the agent).
            if event.keyCode == 53,
               let mwc = windowController as? MainWindowController,
               mwc.keyboardMode.mode == .insert {
                let hasCommand = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .contains(.command)
                let consumed = mwc.keyboardMode.handleEsc(
                    hasCommand: hasCommand,
                    now: ProcessInfo.processInfo.systemUptime
                )
                if consumed {
                    mwc.tabCoordinator.dashboardVC?.enterDashboardNavigation()
                    return
                }
                // first plain Esc: fall through to terminal
            }
        }
        super.sendEvent(event)
    }
}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        positionStandardWindowButtons()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        applyWindowBackgroundStyle()
        positionStandardWindowButtons()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        positionStandardWindowButtons()
    }

    func windowDidChangeEffectiveAppearance(_ notification: Notification) {
        applyWindowBackgroundStyle()
    }


    func windowWillClose(_ notification: Notification) {
        usageSummaryStore.stop()
        statusPublisher.stop()
        tabCoordinator.branchRefreshTimer?.invalidate()
        tabCoordinator.branchRefreshTimer = nil
        terminalCoordinator.cleanup()
    }

    func cleanupBeforeTermination() {
        usageSummaryStore.stop()
        statusPublisher.stop()
        tabCoordinator.branchRefreshTimer?.invalidate()
        tabCoordinator.branchRefreshTimer = nil
        terminalCoordinator.cleanup()
    }
}

// MARK: - TitleBarDelegate

extension MainWindowController: TitleBarDelegate {
    func titleBarDidToggleTheme() {
        let isDark = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let next: ThemeMode = isDark ? .light : .dark
        config.themeMode = next.rawValue
        tabCoordinator.config.themeMode = next.rawValue
        terminalCoordinator.config.themeMode = next.rawValue
        updateCoordinator.config.themeMode = next.rawValue
        saveConfig()
        ThemeMode.applyAppearance(next)
        // Window appearance must also be updated since it was set explicitly in init
        switch next {
        case .dark:
            window?.appearance = NSAppearance(named: .darkAqua)
        case .light:
            window?.appearance = NSAppearance(named: .aqua)
        case .system:
            window?.appearance = nil
        }
        // Update NSAppearance.current so .cgColor resolves correctly outside drawing cycles
        NSAppearance.current = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        applyWindowBackgroundStyle()
    }

    func titleBarDidRequestCollapseLeftColumn() {
        guard let collapsed = tabCoordinator.dashboardVC?.toggleLeftColumnCollapse() else { return }
        titleBar.setLeftColumnCollapsed(collapsed)
    }

    func titleBarDidSelectLeftPane(_ pane: LeftPane) {
        tabCoordinator.dashboardVC?.selectLeftPane(pane)
    }

    func titleBarDidToggleWorktreeList(from sourceView: NSView) {
        tabCoordinator.dashboardVC?.toggleWorktreePopover(from: sourceView)
    }

    func titleBarDidSelectWorktree(_ path: String) {
        tabCoordinator.selectTab(forWorktree: path)
    }
}

private extension MainWindowController {
    func cleanMergedWorktrees() {
        let candidates = tabCoordinator.allWorktrees.map(\.info)
        let repoCache = tabCoordinator.worktreeRepoCache
        guard candidates.contains(where: { !$0.isMainWorktree }) else {
            showWorktreeCleanupAlert(title: "No worktrees to clean", message: "There are no linked worktrees in the current workspace list.")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let summary = WorktreeDeleter.cleanMergedWorktrees(worktrees: candidates) { info in
                repoCache[info.path]
                    ?? WorktreeDiscovery.findRepoRoot(from: info.path)
            }

            DispatchQueue.main.async {
                for path in summary.deletedPaths {
                    guard let item = self.tabCoordinator.allWorktrees.first(where: { $0.info.path == path }) else { continue }
                    self.terminalCoordinator.stationManager.removeTree(forPath: path)
                    self.tabCoordinator.worktreeDidDelete(item.info)
                }
                self.tabCoordinator.saveSelectedWorktree()
                self.updateTitleBar()
                self.showWorktreeCleanupSummary(summary)
            }
        }
    }

    func showWorktreeCleanupSummary(_ summary: WorktreeCleanupSummary) {
        if summary.deletedPaths.isEmpty {
            let message = summary.skipped.isEmpty
                ? "No linked worktrees were found."
                : summary.skipped.map { URL(fileURLWithPath: $0.path).lastPathComponent + ": " + $0.reason }.joined(separator: "\n")
            showWorktreeCleanupAlert(title: "No merged worktrees cleaned", message: message)
            return
        }

        let deletedNames = summary.deletedPaths
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .joined(separator: "\n")
        showWorktreeCleanupAlert(
            title: "Cleaned \(summary.deletedPaths.count) merged worktree\(summary.deletedPaths.count == 1 ? "" : "s")",
            message: deletedNames
        )
    }

    func showWorktreeCleanupAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - DashboardDelegate

extension MainWindowController: DashboardDelegate {
    func dashboardDidSelectProject(_ project: String, thread: String) {
        tabCoordinator.dashboardDidSelectProject(project, thread: thread)
    }

    func dashboardDidRequestEnterProject(_ project: String) {
        tabCoordinator.dashboardDidRequestEnterProject(project)
    }

    func dashboardDidReorderCards(order: [String]) {
        config.cardOrder = order
        tabCoordinator.config.cardOrder = order
        saveConfig()
    }

    func dashboardDidRequestCloseRepo(_ project: String) {
        tabCoordinator.showCloseProjectModal(project, window: window)
    }

    func dashboardDidRequestDelete(_ terminalID: String) {
        tabCoordinator.dashboardDidRequestDelete(terminalID, window: window)
    }

    func dashboardDidRequestAddProject() {
        tabCoordinator.addRepoViaOpenPanel(window: window)
    }

    func dashboardDidChangeSelection(_ dashboard: DashboardViewController) {
        updateTitleBar()
        tabCoordinator.saveSelectedWorktree()
        config.selectedWorktreePath = tabCoordinator.config.selectedWorktreePath
        saveConfig()
    }

    func dashboardDidRequestBrowseFiles(worktreePath: String) {
        tabCoordinator.dashboardVC?.selectLeftPane(.file)
    }

    func dashboardDidRequestShowChanges(worktreePath: String) {
        tabCoordinator.dashboardVC?.selectLeftPane(.change)
    }

}

// MARK: - SplitContainerDelegate

extension MainWindowController: SplitContainerDelegate {
    func splitContainer(_ view: SplitContainerView, didChangeFocus leafId: String) {
        guard let tree = view.tree else { return }
        let worktreePath = tree.worktreePath
        NotificationCenter.default.post(
            name: .repoViewDidChangeFocusedPane,
            object: self,
            userInfo: ["worktreePath": worktreePath, "focusedLeafId": leafId]
        )
    }

    func splitContainer(_ view: SplitContainerView, didRequestSplit axis: SplitAxis) {
        splitFocusedPane(axis: axis)
    }

    func splitContainer(_ view: SplitContainerView, didRequestClosePane leafId: String) {
        closeFocusedPane()
    }

    func splitContainerDidChangeLayout(_ view: SplitContainerView) {
        guard let tree = view.tree else { return }
        terminalCoordinator.saveSplitLayout(tree)
    }
}

// MARK: - PanelCoordinatorDelegate

extension MainWindowController: PanelCoordinatorDelegate {
    func panelCoordinator(_ coordinator: PanelCoordinator, navigateToWorktreePath path: String, paneIndex: Int?) {
        tabCoordinator.handleNavigateToWorktree(worktreePath: path, paneIndex: paneIndex)
    }
}

// MARK: - NewBranchDialogDelegate

extension MainWindowController: NewBranchDialogDelegate {
    func newBranchDialog(_ dialog: NewBranchDialog, didCreateWorktree info: WorktreeInfo, inRepo repoPath: String) {
        tabCoordinator.handleNewBranch(info: info, repoPath: repoPath)
    }
}

// MARK: - WorktreeStatusDelegate

extension MainWindowController: WorktreeStatusDelegate {
    func worktreeStatusDidUpdate(_ status: WorktreeStatus) {
        tabCoordinator.handleWorktreeStatusUpdate(status)
    }

    func paneStatusDidChange(worktreePath: String, paneIndex: Int, oldStatus: SailorStatus, newStatus: SailorStatus, lastMessage: String) {
        tabCoordinator.handlePaneStatusChange(worktreePath: worktreePath, paneIndex: paneIndex, oldStatus: oldStatus, newStatus: newStatus, lastMessage: lastMessage)
    }
}

// MARK: - Notification Navigation

extension MainWindowController {
    @objc private func handleNavigateToWorktree(_ notification: Notification) {
        guard let worktreePath = notification.userInfo?["worktreePath"] as? String else { return }
        let paneIndex = notification.userInfo?["paneIndex"] as? Int
        tabCoordinator.handleNavigateToWorktree(worktreePath: worktreePath, paneIndex: paneIndex)
    }

    @objc private func handleNotificationHistoryDidChange(_ notification: Notification?) {
        updatePrimaryCapsuleNotification()
    }

    private func updatePrimaryCapsuleNotification() {
        pruneDismissedPrimaryCapsuleNotificationIDs()
        let entry = Self.selectPrimaryCapsuleNotification(
            from: NotificationHistory.shared.entries,
            excluding: dismissedPrimaryCapsuleNotificationIDs
        )
        let previousID = primaryCapsuleNotification?.id
        primaryCapsuleNotification = entry
        if let entry, entry.id != previousID {
            schedulePrimaryCapsuleAutoDismiss(for: entry)
        } else if entry == nil {
            primaryCapsuleDismissWorkItem?.cancel()
            primaryCapsuleDismissWorkItem = nil
        }
        let unreadCount = NotificationHistory.shared.unreadCount
        titleBar.updateNotificationSummary(
            entry: entry,
            unreadCount: unreadCount
        )
        statusBar.updateNotification(text: unreadCount > 0 ? "\(unreadCount) unread" : "")
    }

    static func selectPrimaryCapsuleNotification(
        from entries: [NotificationEntry],
        excluding excludedIDs: Set<UUID> = []
    ) -> NotificationEntry? {
        let unreadEntries = entries.filter { !$0.isRead }
        let visibleEntries = unreadEntries.filter { !excludedIDs.contains($0.id) }
        guard !visibleEntries.isEmpty else { return nil }
        return highestPriorityNotification(in: visibleEntries)
    }

    private static func highestPriorityNotification(in entries: [NotificationEntry]) -> NotificationEntry? {
        entries.max { lhs, rhs in
            let left = notificationPriorityScore(for: lhs)
            let right = notificationPriorityScore(for: rhs)
            if left == right {
                return lhs.timestamp < rhs.timestamp
            }
            return left < right
        }
    }

    private static func notificationPriorityScore(for entry: NotificationEntry) -> Int {
        switch entry.status {
        case .error, .exited:
            return 4
        case .waiting:
            return 3
        case .idle:
            return entry.isRead ? 1 : 2
        default:
            return entry.isRead ? 0 : 1
        }
    }

    private func schedulePrimaryCapsuleAutoDismiss(for entry: NotificationEntry) {
        primaryCapsuleDismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dismissedPrimaryCapsuleNotificationIDs.insert(entry.id)
            if self.primaryCapsuleNotification?.id == entry.id {
                self.primaryCapsuleNotification = nil
                let unreadCount = NotificationHistory.shared.unreadCount
                self.titleBar.updateNotificationSummary(
                    entry: nil,
                    unreadCount: unreadCount
                )
                self.statusBar.updateNotification(text: unreadCount > 0 ? "\(unreadCount) unread" : "")
            }
        }
        primaryCapsuleDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.primaryCapsuleDisplayDuration,
            execute: workItem
        )
    }

    private func pruneDismissedPrimaryCapsuleNotificationIDs() {
        let validIDs = Set(NotificationHistory.shared.entries.map(\.id))
        dismissedPrimaryCapsuleNotificationIDs.formIntersection(validIDs)
    }
}

// MARK: - SettingsDelegate

extension MainWindowController: SettingsDelegate {
    func settingsDidUpdateConfig(_ settings: SettingsViewController, config: Config) {
        let oldPaths = Set(self.config.workspacePaths)
        let oldWecomBot = self.config.wecomBot
        let oldWechat = self.config.wechat
        // Preserve split layouts — SettingsVC doesn't track them
        var merged = config
        merged.splitLayouts = terminalCoordinator.config.splitLayouts
        self.config = merged
        tabCoordinator.config = merged
        terminalCoordinator.config = merged
        updateCoordinator.config = merged
        normalizeBackendAvailabilityIfNeeded()

        let newPaths = Set(config.workspacePaths)
        if oldPaths != newPaths {
            tabCoordinator.loadWorkspaces()
        }

        // Hot-reload external channels on config change
        if oldWecomBot != config.wecomBot || oldWechat != config.wechat {
            ShipLog.shared.unregisterAllExternalChannels()

            if let wecomConfig = config.wecomBot, wecomConfig.resolvedAutoConnect {
                let channel = WeComBotChannel(config: wecomConfig)
                ShipLog.shared.registerChannel(channel)
                channel.connect()
                NSLog("[Settings] WeCom bot reconnecting: \(wecomConfig.resolvedName)")
            }

            if let wechatConfig = config.wechat, wechatConfig.resolvedAutoConnect {
                let channel = WeChatChannel(config: wechatConfig)
                ShipLog.shared.registerChannel(channel)
                channel.connect()
                NSLog("[Settings] WeChat reconnecting")
            }
        }
    }
}

// MARK: - QuickSwitcherDelegate

extension MainWindowController: QuickSwitcherDelegate {
    func quickSwitcher(_ vc: QuickSwitcherViewController, didSelect worktree: WorktreeInfo) {
        // Navigate to dashboard — quick switcher now selects the agent card
        tabCoordinator.switchToTab(0)
    }
}

// MARK: - Auto-Update

extension MainWindowController {
    @objc func checkForUpdates() {
        updateCoordinator.checkForUpdates()
    }
}

// MARK: - UpdateCoordinatorDelegate

extension MainWindowController: UpdateCoordinatorDelegate {
    func updateCoordinator(_ coordinator: UpdateCoordinator, showBanner banner: UpdateBanner) {
        // Banner display handled by coordinator's banner property
    }
}


// MARK: - TabCoordinatorDelegate

extension MainWindowController: TabCoordinatorDelegate {
    func tabCoordinator(_ coordinator: TabCoordinator, embedViewController vc: NSViewController) {
        embedViewController(vc)
    }
    func tabCoordinatorDidSwitchTab(_ coordinator: TabCoordinator) {
    }
    func tabCoordinatorRequestUpdateTitleBar(_ coordinator: TabCoordinator) {
        updateTitleBar()
    }
    func tabCoordinatorRequestShowNewBranchDialog(_ coordinator: TabCoordinator) {
        showNewBranchDialog()
    }
    func tabCoordinatorRequestClearContentContainer(_ coordinator: TabCoordinator) {
        for child in contentContainer.subviews {
            child.removeFromSuperview()
        }
    }
}

// MARK: - TerminalCoordinatorDelegate

extension MainWindowController: TerminalCoordinatorDelegate {
    func terminalCoordinatorDidUpdateSurfaces(_ coordinator: TerminalCoordinator) {
        statusPublisher.updateSurfaces(coordinator.stationManager.all)
    }

    func terminalCoordinator(_ coordinator: TerminalCoordinator, didDeleteWorktree info: WorktreeInfo) {
        worktreeDidDelete(info)
    }
}

// MARK: - KeyboardModeDelegate

extension MainWindowController: KeyboardModeDelegate {
    func keyboardModeDidChange(_ mode: KeyboardMode, substate: KeyboardSubstate) {
        statusBar.updateMode(mode, hint: keyboardMode.hintText)
    }
    func keyboardHintDidChange(_ hint: String) {
        statusBar.updateMode(keyboardMode.mode, hint: hint)
    }
}

// MARK: - Bridge Actions

extension MainWindowController {
    /// Routes a suggestion chip tap. `returnToPort` chips trigger actual deletion;
    /// all other kinds forward the option text to the agent terminal.
    func handleSuggestionTapped(order: PendingOrder, optionText: String) {
        if order.action.kind == .returnToPort {
            let deleteBranch = optionText.contains("Branch")
            let force = optionText.lowercased().contains("force")
            terminalCoordinator.deleteWorktreeForReturnToPort(
                path: order.action.worktreePath,
                branch: order.action.branch,
                deleteBranch: deleteBranch,
                force: force)
        } else {
            ShipLog.shared.sendCommand(to: order.action.terminalID, command: optionText)
        }
        tabCoordinator.pendingOrders.resolve(id: order.id)
    }

    func handleBridgeApprove(_ order: PendingOrder) {
        switch order.action.kind {
        case .suggestNextOrder:
            let worktreePath = order.action.worktreePath
            guard let task = WorktreeTaskStore.shared.task(forWorktree: worktreePath),
                  let terminalID = ShipLog.shared.sailor(forWorktree: worktreePath)?.id else { return }
            ShipLog.shared.sendCommand(to: terminalID, command: task)
        case .returnToPort:
            terminalCoordinator.deleteWorktreeForReturnToPort(
                path: order.action.worktreePath,
                branch: order.action.branch
            )
        case .broadcastOrder:
            guard let task = order.action.payload else { return }
            for agent in ShipLog.shared.allSailors() {
                ShipLog.shared.sendCommand(to: agent.id, command: task)
            }
        default:
            break
        }
    }
}
