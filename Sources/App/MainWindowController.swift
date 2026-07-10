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
        tc.runtimeBackend = runtimeBackend
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
        NotificationManager.shared.stabilityDelay = config.notifications.stabilityDelay
        NotificationManager.shared.cooldown = config.notifications.cooldown
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
        installFnDoubleTapMonitor()
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

    /// Resolve the runtime backend (zmx, else local fallback) off the main thread
    /// — the version probe spawns a process — then push it to the coordinators.
    /// `runtimeBackend` starts optimistically at "zmx" so any restore that races
    /// this resolution attaches persistent sessions; the async pass only ever
    /// downgrades to "local" when zmx is genuinely unavailable/unsupported.
    private func normalizeBackendAvailabilityIfNeeded() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resolution = ZmxLocator.resolveBackend()
            DispatchQueue.main.async {
                guard let self else { return }
                self.runtimeBackend = resolution.backend
                self.tabCoordinator.runtimeBackend = resolution.backend
                self.terminalCoordinator.runtimeBackend = resolution.backend
                if let warning = resolution.warning {
                    let alert = NSAlert()
                    alert.messageText = "Backend Fallback Activated"
                    alert.informativeText = "\(warning)\nCurrent backend: \(resolution.backend)."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
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
        // Cmd+N returns to the Dashboard overview and starts a `/new` command in
        // its command input.
        tabCoordinator.switchToTab(0)
        dashboardVC?.startNewCommand()
    }

    // MARK: - First Mate command shortcuts

    /// Switch to the dashboard overview and prefill its composer with a slash
    /// command (the floating cockpit was removed; the composer lives in overview).
    private func openHelmCockpit(prefill: String) {
        tabCoordinator.switchToTab(0)
        dashboardVC?.startNewCommand(prefill: prefill)
    }

    @objc func helmReturnCommand() { openHelmCockpit(prefill: "/return ") }
    @objc func helmOrderCommand() { openHelmCockpit(prefill: "/order ") }
    @objc func helmCommitCommand() { openHelmCockpit(prefill: "/commit ") }
    @objc func helmBroadcastCommand() { openHelmCockpit(prefill: "/broadcast ") }
    @objc func helmAddRepoCommand() { openHelmCockpit(prefill: "/add") }

    /// Double-tap fn: toggle between the Dashboard overview (spread First Mate)
    /// and the current worktree's working view.
    func toggleFirstMatePanel() {
        tabCoordinator.switchToTab(0)
        guard let dashboard = dashboardVC else { return }
        dashboard.setDisplayMode(dashboard.displayMode == .overview ? .worktree : .overview)
    }

    // MARK: - Ctrl double-tap detection

    private static let ctrlDoubleTapWindow: TimeInterval = 0.35
    private static let leftControlKeyCode: UInt16 = 59

    /// Detect a bare left-Ctrl double-tap (JetBrains-style) via a local event
    /// monitor. A monitor sees flagsChanged before window dispatch, so it works
    /// regardless of which view is first responder (terminal, cockpit text
    /// field, …). Any keyDown between the two taps breaks the sequence so
    /// Ctrl+C-style chords don't trigger it.
    /// (fn was the original choice, but many third-party keyboards handle Fn in
    /// firmware and never report it to macOS.)
    private func installFnDoubleTapMonitor() {
        fnTapMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                self.lastFnPressAt = 0
                return event
            }
            guard event.keyCode == Self.leftControlKeyCode else { return event }
            let isPress = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .contains(.control)
            self.fnTapLog("flagsChanged keyCode=\(event.keyCode) isPress=\(isPress)")
            guard isPress else { return event }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastFnPressAt < Self.ctrlDoubleTapWindow {
                self.lastFnPressAt = 0
                self.fnTapLog("double-tap → toggleFirstMatePanel")
                self.toggleFirstMatePanel()
            } else {
                self.lastFnPressAt = now
            }
            return event
        }
    }

    private var fnTapMonitor: Any?
    /// Timestamp of the last bare fn press; 0 when broken by another key.
    private var lastFnPressAt: TimeInterval = 0

    /// Temporary fn-double-tap diagnostics — appends to /tmp/seahelm-fntap.log.
    private func fnTapLog(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/seahelm-fntap.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
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

        // Feed the full-width overview's ORDERS carousel + composer with the live
        // queue and command handlers.
        dashboard.configureOverview(
            pendingOrders: tabCoordinator.pendingOrders,
            onSubmitCommand: { [weak self] text in _ = self?.submitBridgeCommand(text) },
            onOrderAction: { [weak self] order, optionText in
                self?.handleSuggestionTapped(order: order, optionText: optionText)
            },
            commandMenuProvider: { [weak self] trigger, query in
                self?.helmMenuItems(trigger: trigger, query: query) ?? []
            }
        )

        dashboard.onEnterTerminal = { [weak self] in
            // Drilling into a terminal = entering the worktree working view.
            self?.dashboardVC?.setDisplayMode(.worktree)
            self?.keyboardMode.enterInsert()
        }
        // Keep the title-bar left cluster in sync: only the theme toggle in the
        // Dashboard overview; collapse + file/change once inside a worktree.
        dashboard.onDisplayModeChanged = { [weak self] mode in
            self?.titleBar.setChromeMode(overview: mode == .overview)
        }
        // Light exactly one toolbar icon for the active view; dim the rest.
        dashboard.onActiveToolChanged = { [weak self] tool in
            self?.titleBar.setActiveTool(tool)
        }
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
        // Launch in the overview: hide the worktree-only chrome up front so the
        // collapse/file/change/back icons don't flash before the async activation.
        titleBar.setChromeMode(overview: true)

        applyWindowBackgroundStyle()
        positionStandardWindowButtons()

        // Land in the Dashboard overview (spread First Mate). Deferred so the
        // window/first-responder are settled before the cockpit opens.
        DispatchQueue.main.async { [weak self] in
            self?.dashboardVC?.activateInitialOverview()
        }
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
                    let sessionName = SessionManager.persistentSessionName(for: info.path)
                    let backend = self.runtimeBackend
                    // `zmx run` blocks until the (long-lived) agent exits, so spawn the
                    // session on a detached thread and wait only until it exists —
                    // otherwise handleNewBranch + onComplete below would never run and
                    // the cockpit would spin forever.
                    DispatchQueue.global(qos: .userInitiated).async {
                        SessionManager.createDetachedSession(
                            name: sessionName, backend: backend,
                            cwd: info.path, agentCommandLine: agentCommandLine
                        )
                    }
                    _ = SessionManager.waitUntilSessionExists(
                        name: sessionName, backend: backend, timeoutSeconds: 5.0)
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
                ("new", "Start a new task session"),
                ("order", "Give an order to the agent"),
                ("commit", "Commit and push current changes"),
                ("return", "Recall agent · end session"),
                ("broadcast", "Broadcast to everyone"),
                ("add", "Add a repo to the workspace"),
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
            addRepo: { [weak self] in
                self?.tabCoordinator.addRepoViaOpenPanel(window: self?.window)
            },
            activeSailorCount: { ShipLog.shared.allSailors().count },
            branchForPath: { path in ShipLog.shared.sailor(forWorktree: path)?.branch ?? "" },
            projectForPath: { path in ShipLog.shared.sailor(forWorktree: path)?.project ?? "" }
        )
    }

    /// Run a merge check for `path` on a background thread and enqueue a
    /// return-to-port card with appropriate options once the check completes.
    /// Resolve a `/return` for one worktree. If it is clean AND fully merged,
    /// remove it immediately (no confirmation). Otherwise enqueue a red
    /// "Force remove" card requiring explicit confirmation. `onDone` fires on the
    /// main thread once resolved (deleted or carded).
    private func enqueueReturnCard(forPath path: String, onDone: (() -> Void)? = nil) {
        let repoCache = tabCoordinator.worktreeRepoCache
        let queue = tabCoordinator.pendingOrders
        let coordinator = terminalCoordinator
        let sailor = ShipLog.shared.sailor(forWorktree: path)

        // A worktree with a live agent must never be reaped by /return: neither
        // deleted outright nor carded for "Force remove". Leave it untouched.
        if sailor?.status == .running {
            onDone?()
            return
        }

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

            DispatchQueue.main.async {
                if check.canDelete {
                    // Clean + fully merged → safe to remove directly, no confirm.
                    coordinator.deleteWorktreeForReturnToPort(
                        path: path, branch: branch, deleteBranch: false, force: false)
                } else {
                    // Dirty or unmerged → require explicit "Force remove" confirmation.
                    queue.enqueue(FirstMateAction(
                        kind: .returnToPort, zone: .red,
                        worktreePath: path, branch: branch, project: project,
                        terminalID: "",
                        message: check.reason,
                        options: ["Force remove"]))
                }
                onDone?()
            }
        }
    }

    /// Outcome of an async Helm command, reported back so the caller can drop its
    /// loading spinner and react.
    enum HelmCommandOutcome {
        case navigated   // moved to a new tab (e.g. /new)
        case presented   // dropped an order card (e.g. /return)
        case failed      // error
    }

    /// Submit a Helm command. Returns `true` if it kicked off async work (so the
    /// caller shows a loading spinner); `onOutcome` then fires when the work
    /// completes — `.navigated` for a new tab, `.presented` for an order card,
    /// `.failed` on error. Synchronous commands route immediately and return `false`.
    @discardableResult
    func submitBridgeCommand(_ text: String, onOutcome: ((HelmCommandOutcome) -> Void)? = nil) -> Bool {
        switch BridgeCommandParser.parse(text, worktrees: currentWorktreeRefs(),
                                         repoPaths: tabCoordinator.config.workspacePaths) {
        case .success(let command):
            switch command {
            case .newWorktree(let task, let repoHint):
                let repoPath = repoHint ?? tabCoordinator.config.workspacePaths.first ?? ""
                performWorktreeCreate(task: task, repoPath: repoPath, agentType: .claudeCode,
                                      reuseEnv: false) { path in
                    onOutcome?(path != nil ? .navigated : .failed)
                }
                return true

            case .returnToPort(let path):
                enqueueReturnCard(forPath: path) { onOutcome?(.presented) }
                return true

            case .returnAll:
                let worktrees = tabCoordinator.allWorktrees.map(\.info).filter { !$0.isMainWorktree }
                guard !worktrees.isEmpty else { NSSound.beep(); return false }
                let group = DispatchGroup()
                for info in worktrees {
                    group.enter()
                    enqueueReturnCard(forPath: info.path) { group.leave() }
                }
                group.notify(queue: .main) { onOutcome?(.presented) }
                return true

            default:
                makeBridgeRouter().route(command)
                return false
            }
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
        let info = ShipLog.shared.sailor(forWorktree: path)
        let branch = info?.branch ?? ""
        // Title leads with the repo name (emphasized), then the branch.
        let repo = (info?.project).flatMap { $0.isEmpty ? nil : $0 } ?? (path as NSString).lastPathComponent
        let title = branch.isEmpty ? repo : "\(repo) · \(branch)"
        titleBar.updateFocusedWorktree(title: title, path: path)
    }



    // MARK: - Forwarding to TabCoordinator

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

    /// Keyboard cycle through worktree tabs (Ctrl+Tab / Ctrl+Shift+Tab), filling the
    /// previously mouse-only titlebar gap (docs/keyboard-redesign.md §7).
    func selectAdjacentWorktree(forward: Bool) {
        titleBar.selectAdjacentWorktree(forward: forward)
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

        // Single source of truth for the window-level chord map (see GlobalKeymap).
        guard let shortcut = GlobalKeymap.resolve(
            chars: event.charactersIgnoringModifiers,
            keyCode: event.keyCode,
            flags: flags,
            hasSplitContext: hasSplitContext
        ) else {
            return super.performKeyEquivalent(with: event)
        }

        switch shortcut {
        case .splitHorizontal:
            mwc.splitFocusedPane(axis: .horizontal); return true
        case .splitVertical:
            mwc.splitFocusedPane(axis: .vertical); return true
        case .moveFocus(let dir):
            let (axis, positive) = Self.axisPositive(dir)
            mwc.moveFocus(axis, positive: positive); return true
        case .resize(let dir):
            let (axis, delta) = Self.axisDelta(dir)
            mwc.resizeSplit(axis, delta: delta); return true
        case .resetRatio:
            mwc.resetSplitRatio(); return true
        case .nextWorktree:
            mwc.selectAdjacentWorktree(forward: true); return true
        case .prevWorktree:
            mwc.selectAdjacentWorktree(forward: false); return true
        case .toggleSidebar:
            mwc.tabCoordinator.dashboardVC?.toggleSidebarDefaultDashboard(); return true
        case .exitInsert:
            if mwc.keyboardMode.handleEsc(hasCommand: true, now: ProcessInfo.processInfo.systemUptime) {
                mwc.tabCoordinator.dashboardVC?.enterDashboardNavigation()
                return true
            }
            return super.performKeyEquivalent(with: event)
        case .toggleOverview:
            mwc.toggleFirstMatePanel(); return true   // overview ⇄ worktree
        case .firstMatePane:
            mwc.tabCoordinator.dashboardVC?.toggleFirstMateSide(); return true
        case .filesPane:
            mwc.tabCoordinator.dashboardVC?.selectLeftPane(.file); return true
        case .changesPane:
            mwc.tabCoordinator.dashboardVC?.selectLeftPane(.change); return true
        }
    }

    /// Map a directional focus move to the (axis, positive) pair `moveFocus` expects.
    static func axisPositive(_ dir: FocusDirection) -> (SplitAxis, Bool) {
        switch dir {
        case .left:  return (.horizontal, false)
        case .right: return (.horizontal, true)
        case .down:  return (.vertical, true)
        case .up:    return (.vertical, false)
        }
    }

    /// Map a directional resize to the (axis, delta) pair `resizeSplit` expects.
    static func axisDelta(_ dir: FocusDirection) -> (SplitAxis, CGFloat) {
        switch dir {
        case .left:  return (.horizontal, -0.05)
        case .right: return (.horizontal, 0.05)
        case .down:  return (.vertical, 0.05)
        case .up:    return (.vertical, -0.05)
        }
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
        tabCoordinator.dashboardVC?.openWorktreesTab()
    }

    func titleBarDidSelectWorktree(_ path: String) {
        // Picking a worktree from the popover drills into its working view.
        tabCoordinator.selectTab(forWorktree: path)
        dashboardVC?.setDisplayMode(.worktree)
    }

    func titleBarDidRequestOverview() {
        tabCoordinator.switchToTab(0)
        dashboardVC?.enterOverview()
    }

    func titleBarDidToggleFirstMate() {
        dashboardVC?.toggleFirstMateSide()
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
            // Guard against a stale card: if the agent started running after the
            // card was enqueued, refuse the reap and drop the card.
            if ShipLog.shared.sailor(forWorktree: order.action.worktreePath)?.status == .running {
                NSSound.beep()
                tabCoordinator.pendingOrders.resolve(id: order.id)
                return
            }
            let deleteBranch = optionText.contains("Branch")
            let force = optionText.lowercased().contains("force")
            terminalCoordinator.deleteWorktreeForReturnToPort(
                path: order.action.worktreePath,
                branch: order.action.branch,
                deleteBranch: deleteBranch,
                force: force)
        } else if order.action.payload == "ask-user-question" {
            // AskUserQuestion TUI selects by digit; typing the label text would
            // land in the free-form field instead. Send the option's number —
            // sendCommand follows with a Return that confirms the selection.
            if let idx = order.action.options?.firstIndex(of: optionText) {
                ShipLog.shared.sendCommand(to: order.action.terminalID, command: "\(idx + 1)")
            }
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
            // Never reap a worktree whose agent is now running.
            if ShipLog.shared.sailor(forWorktree: order.action.worktreePath)?.status == .running {
                NSSound.beep()
                break
            }
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
