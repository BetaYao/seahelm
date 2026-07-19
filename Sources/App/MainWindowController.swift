import AppKit
import ApplicationServices

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
        (containerHeight / 2) + 1 - (buttonHeight / 2)
    }
}

class MainWindowController: NSWindowController {
    private static let primaryCapsuleDisplayDuration: TimeInterval = 8.0

    private let backgroundEffectView = NSVisualEffectView()
    private let contentContainer = NSView()
    let keyboardMode = KeyboardModeController()
    /// Outer Tab-cycle focus among panes / sidebar / chrome header / helm.
    let regionFocus = RegionFocusController()
    private var windowTrackingArea: NSTrackingArea?
    /// The system titlebar view the traffic lights originally live in. They are
    /// reparented into the sidebar header while windowed; fullscreen hands them
    /// back here so macOS drives the native hide/reveal + exit-fullscreen zoom.
    private weak var nativeTrafficLightHome: NSView?
    private var isWindowFullscreen = false
    private lazy var panelCoordinator: PanelCoordinator = {
        let pc = PanelCoordinator()
        pc.delegate = self
        return pc
    }()

    private var windowChrome: WindowChromeController?
    private var chromeState = ChromeLayoutState(
        width: ChromeLayoutMetrics.defaultSidebarWidth,
        collapsed: false,
        activePane: .firstMate
    )

    private var dashboardVC: DashboardViewController?
    private var config = Config.load()
    private var runtimeBackend: String = "zmx"
    private var primaryCapsuleNotification: NotificationEntry?
    private var dismissedPrimaryCapsuleNotificationIDs: Set<UUID> = []
    private var primaryCapsuleDismissWorkItem: DispatchWorkItem?
    private var capsuleToken = 0
    private lazy var usageSummaryStore = UsageSummaryStore()

    // Vibe-island notch overlay
    private let islandController = IslandPanelController()
    private var islandRefreshTimer: Timer?
    private var historyChangeObserver: NSObjectProtocol?
    private var islandKnownOrderIDs: Set<String> = []
    private var islandKnownUnread = 0

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
        // Every desktop banner also goes to whatever chat channels are registered,
        // so a phone hears "agent finished" without seahelm owning a transport or
        // push certificate. No-op until a channel is registered.
        NotificationManager.shared.onDeliverExternal = { status, title, subtitle, body in
            ShipLog.shared.broadcast(
                "\(status.icon) **\(title)**\n\(subtitle)\n\n\(body)",
                format: .markdown
            )
        }
        ShipLog.shared.chatCommandRoute = makeChatCommandRoute()
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
        setupIsland()
        usageSummaryStore.onUpdate = { _ in }
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

    /// The WeChat bot token stopped being accepted. Point the user at the QR
    /// flow rather than leaving the channel silently dead.
    func promptWeChatReauth() {
        guard let window else { return }

        let alert = NSAlert()
        alert.messageText = "WeChat sign-in expired"
        alert.informativeText = "Seahelm has stopped receiving WeChat messages. Scan the QR code again to reconnect."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.showSettings()
        }
    }

    @objc func showNewBranchDialog() {
        // Cmd+N opens the island with `/new ` prefilled in its command field.
        // Fall back to the overview composer when the island is disabled.
        if config.islandEnabled {
            islandController.openCommandBar(prefill: "/new ")
        } else {
            tabCoordinator.switchToTab(0)
            dashboardVC?.startNewCommand()
        }
    }

    // MARK: - First Mate command shortcuts

    /// Switch to the dashboard overview and prefill its composer with a slash
    /// command (the floating cockpit was removed; the composer lives in overview).
    private func openHelmCockpit(prefill: String) {
        tabCoordinator.switchToTab(0)
        dashboardVC?.startNewCommand(prefill: prefill)
    }

    @objc func helmTaskCommand() { openHelmCockpit(prefill: "/task ") }
    @objc func helmAgentsCommand() { openHelmCockpit(prefill: "/agents") }
    @objc func helmRepoCommand() { openHelmCockpit(prefill: "/repo") }
    @objc func helmOrderCommand() { openHelmCockpit(prefill: "/order ") }
    @objc func helmBroadcastCommand() { openHelmCockpit(prefill: "/broadcast ") }
    @objc func helmReturnCommand() { openHelmCockpit(prefill: "/return ") }
    @objc func helmAddRepoCommand() { openHelmCockpit(prefill: "/add") }

    @objc func splitHorizontal() { splitFocusedPane(axis: .horizontal) }
    @objc func splitVertical() { splitFocusedPane(axis: .vertical) }

    /// Cmd+Esc / Cmd+E: toggle chrome sidebar collapse.
    func navigateBack() {
        tabCoordinator.switchToTab(0)
        toggleChromeCollapsed()
    }

    /// ⌘B / navigateBack — chrome collapse is the only layout collapse signal.
    @objc func toggleChromeCollapsed() {
        chromeState.toggleCollapsed()
        applyChromeState(animated: true)
    }

    func setChromeCollapsed(_ collapsed: Bool) {
        guard chromeState.isCollapsed != collapsed else {
            // Still refresh dashboard content / keyboard when already in sync.
            dashboardVC?.adoptChromeCollapse(collapsed, activePane: chromeState.activePane)
            syncKeyboardToChromeCollapse()
            return
        }
        chromeState.setCollapsed(collapsed)
        applyChromeState(animated: true)
    }

    /// Header / keymap pane icons — uses `selectPane` (re-click collapses).
    func selectChromePane(_ pane: ChromeLeftPane) {
        chromeState.selectPane(pane)
        applyChromeState(animated: true)
    }

    private func applyChromeState(animated: Bool) {
        windowChrome?.applyState(chromeState, animated: animated)
        positionStandardWindowButtons()
        dashboardVC?.adoptChromeCollapse(chromeState.isCollapsed, activePane: chromeState.activePane)
        syncKeyboardToChromeCollapse()
        refreshChromeWorktreeContextEnabled()
        refreshRegionAvailability()
        // Collapse swaps which header owns `Region.titlebar` — re-apply if focused.
        if regionFocus.current == .titlebar {
            applyRegionFocus()
        }
    }

    private func syncKeyboardToChromeCollapse() {
        if chromeState.isCollapsed {
            keyboardMode.enterInsert()
        } else {
            keyboardMode.enterNormal()
        }
    }

    private func refreshChromeWorktreeContextEnabled() {
        let hasSelection = tabCoordinator.selectedSailor != nil
            || !(dashboardVC?.selectedSailorId.isEmpty ?? true)
        windowChrome?.setWorktreeContextEnabled(hasSelection)
    }

    // MARK: - Region focus (Tab cycle)

    /// Refresh which keyboard regions exist for the current chrome / split layout.
    /// Order is canonical: panes → dashboard → sidebar → titlebar(header) → helm.
    func refreshRegionAvailability() {
        var regions: [Region] = []
        let hasSplit = tabCoordinator.dashboardVC?.activeSplitContainer != nil
        if hasSplit {
            regions.append(.panes)
        } else {
            regions.append(.dashboard)
        }
        if !chromeState.isCollapsed {
            regions.append(.sidebar)
        }
        // Chrome headers always present — `titlebar` maps to header icon strip.
        regions.append(.titlebar)
        regions.append(.helm)
        regionFocus.setAvailable(regions)
    }

    /// Translate `regionFocus.current` into first-responder + highlights.
    func applyRegionFocus() {
        let current = regionFocus.current
        windowChrome?.setTitlebarRegionFocused(current == .titlebar)

        guard let current else { return }
        switch current {
        case .titlebar:
            // Header focus handled above.
            break
        case .sidebar, .dashboard:
            dashboardVC?.enterDashboardNavigation()
        case .panes:
            dashboardVC?.activateInitialSplit()
        case .helm:
            dashboardVC?.focusOverviewCommand()
        }
    }

    /// Advance / reverse the outer region Tab cycle and apply focus.
    func cycleKeyboardRegion(forward: Bool) {
        refreshRegionAvailability()
        if forward { regionFocus.next() } else { regionFocus.prev() }
        applyRegionFocus()
    }

    // MARK: - Ctrl double-tap (summon island)

    private static let ctrlDoubleTapWindow: TimeInterval = 0.35
    private static let leftControlKeyCode: UInt16 = 59

    /// Bare left-Ctrl double-tap (JetBrains-style) opens the island command bar.
    /// Local monitor: works app-wide regardless of first responder.
    /// Global monitor: works while Seahelm is in the background (needs
    /// Accessibility permission). Any keyDown between taps breaks the sequence
    /// so Ctrl+C chords don't trigger it.
    private func installFnDoubleTapMonitor() {
        let handle: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self else { return event }
            self.handleCtrlDoubleTapEvent(event)
            return event
        }
        // Local: when Seahelm is frontmost. Global: when another app is active.
        ctrlDoubleTapLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown], handler: handle)
        ctrlDoubleTapGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]) { [weak self] event in
                self?.handleCtrlDoubleTapEvent(event)
            }
        if config.islandEnabled {
            _ = NotificationManager.requestAccessibilityPermission()
        }
    }

    private func handleCtrlDoubleTapEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            lastCtrlPressAt = 0
            return
        }
        guard event.type == .flagsChanged,
              event.keyCode == Self.leftControlKeyCode else { return }
        let isPress = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.control)
        guard isPress else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCtrlPressAt < Self.ctrlDoubleTapWindow {
            lastCtrlPressAt = 0
            openIslandCommandFromHotkey()
        } else {
            lastCtrlPressAt = now
        }
    }

    private func openIslandCommandFromHotkey() {
        guard config.islandEnabled else { return }
        islandController.openCommandBarFocused()
    }

    /// Global key monitors require Accessibility trust; prompt once if missing.
    private var ctrlDoubleTapLocalMonitor: Any?
    private var ctrlDoubleTapGlobalMonitor: Any?
    /// Timestamp of the last bare left-Ctrl press; 0 when broken by another key.
    private var lastCtrlPressAt: TimeInterval = 0

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

        // Content container fills the window (status bar removed for immersive chrome).
        contentContainer.wantsLayer = true
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentContainer)

        keyboardMode.delegate = self

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
            contentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Window hover tracking for arc block styling
        setupWindowHoverTracking(contentView: contentView)

        // Create dashboard — single permanent LeftRight layout
        let dashboard = DashboardViewController()
        dashboard.dashboardDelegate = self
        dashboard.hasWorkspaces = { [weak self] in
            !(self?.tabCoordinator.config.workspacePaths.isEmpty ?? true)
        }
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
            // Drilling into a terminal collapses the chrome sidebar (INSERT).
            self?.setChromeCollapsed(true)
        }
        // ViewMode is a deprecated alias of chrome collapse; keyboard follows chrome.
        dashboard.onViewModeChanged = { [weak self] mode in
            guard let self else { return }
            // Prefer chrome SSOT; ViewMode should already match after adoptChromeCollapse.
            if mode == .terminal || self.chromeState.isCollapsed {
                self.keyboardMode.enterInsert()
            } else {
                self.keyboardMode.enterNormal()
            }
        }
        dashboard.onRequestToggleChromeCollapse = { [weak self] in
            self?.toggleChromeCollapsed()
        }
        dashboard.onRequestSetChromeCollapsed = { [weak self] collapsed in
            self?.setChromeCollapsed(collapsed)
        }
        dashboard.onRequestSelectChromePane = { [weak self] pane in
            self?.selectChromePane(pane)
        }
        // File / changelog overlays reuse the chrome terminal title (no second header).
        dashboard.onCenterOverlayTitleChange = { [weak self] title in
            self?.windowChrome?.setOverlayTitle(title)
        }
        // Keep chrome header icon tint in sync when dashboard changes side.
        dashboard.onActiveToolChanged = { [weak self] pane in
            guard let self else { return }
            if let pane {
                self.chromeState.setActivePane(pane)
            }
            self.windowChrome?.applyState(self.chromeState, animated: false)
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

        embedChromeShell(dashboard: dashboard)
        updateTitleBar()

        applyWindowBackgroundStyle()
        positionStandardWindowButtons()

        // Land in the First Mate split view. Deferred so the window/first-
        // responder are settled before the cockpit opens.
        DispatchQueue.main.async { [weak self] in
            self?.dashboardVC?.activateInitialSplit()
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

    /// What `/task` lists and `/task #x` / `/return @branch` resolve against —
    /// every worktree, not just the staffed ones, so an idle tree is still
    /// reachable and still sweepable. Both surfaces read this, which is what
    /// keeps their numbering identical.
    private func currentWorktreeRefs() -> [WorktreeRef] {
        tabCoordinator.allWorktrees.map {
            WorktreeRef(repo: tabCoordinator.repoName(forWorktree: $0.info.path),
                        branch: $0.info.branch,
                        path: $0.info.path)
        }
    }

    /// Autocomplete data for the Helm command line.
    /// `/` commands · `@` repos/branches · `#` task and agent codes.
    private func helmMenuItems(trigger: Character, query: String) -> [(name: String, desc: String)] {
        let pool: [(name: String, desc: String)]
        switch trigger {
        case "/":
            pool = [
                ("task", "bare lists tasks · <description> starts one · #code switches"),
                ("agents", "bare lists this task's agents · #code steers one"),
                ("repo", "List repos"),
                ("order", "#code <task> — send to one agent without switching"),
                ("broadcast", "Broadcast to everyone"),
                ("add", "Add a repo to the workspace"),
                // Both kinds of `@` name are valid — the kind picks the verb,
                // and no name at all sweeps every worktree.
                ("return", "bare sweeps all · @worktree deletes it · @repo drops the repo"),
            ]
        case "@":
            let repos = tabCoordinator.config.workspacePaths.map {
                (URL(fileURLWithPath: $0).lastPathComponent, "repo · \($0)")
            }
            let worktrees = ShipLog.shared.allSailors().map { ($0.branch, "worktree · \($0.project)") }
            pool = repos + worktrees
        case "#":
            // The codes `/task #x` and `/agents #x` take, in the order the
            // listings print them, so the menu and the reply always agree.
            let tasks = currentWorktreeRefs().enumerated().map { index, wt in
                ("\(index + 1)", "task · \(wt.repo) / \(wt.branch)")
            }
            let agents = currentWorktreeAgentRefs().enumerated().map { index, agent in
                (agent.branch, "agent \(index + 1) · \(agent.project)")
            }
            pool = tasks + agents
        default:
            pool = []
        }
        guard !query.isEmpty else { return pool }
        return pool.filter { $0.name.lowercased().contains(query) }
    }

    /// Routes a chat message through the cockpit's own verbs, so the phone and the
    /// desktop share one command language.
    ///
    /// Deliberately not the cockpit's `BridgeCommandRouter` wiring: those handlers
    /// open file panels and raise confirmation sheets. A phone can neither see nor
    /// answer a sheet, so routing chat through them would park a dialog on the
    /// desktop and read as a hang. These execute and report back in the reply.
    ///
    /// Returns false for verbs it doesn't own, so ShipLog's chat-only ones still run.
    private func makeChatCommandRoute() -> (String, @escaping (String) -> Void) -> Bool {
        { [weak self] text, reply in
            guard let self else { return false }

            // Bare prose steers the worktree you last worked in. NOT the cockpit's
            // meaning (create a worktree and staff it) — see ShipLog.handleInbound.
            guard text.hasPrefix("/") else {
                guard let path = self.dashboardVC?.lastCommittedWorktreePath,
                      let sailor = ShipLog.shared.sailor(forWorktree: path) else { return false }
                ShipLog.shared.sendCommand(to: sailor.id, command: text)
                reply("→ **\(sailor.project)** [\(sailor.branch)]")
                return true
            }

            // `force` suffix is chat-only: on the desktop the sheet asks instead.
            var body = text
            var force = false
            if body.hasSuffix(" force") {
                body = String(body.dropLast(" force".count))
                force = true
            }

            switch BridgeCommandParser.parse(body, worktrees: self.currentWorktreeRefs(),
                                             agents: self.currentWorktreeAgentRefs(),
                                             repoPaths: self.tabCoordinator.config.workspacePaths) {
            case .failure(.unknownCommand):
                return false   // not ours — let /status, /idea, /help try
            case .failure(let err):
                reply(Self.describeChatError(err))
                return true
            case .success(let cmd):
                self.routeChatCommand(cmd, force: force, reply: reply)
                return true
            }
        }
    }

    /// The agents `/agents` and `/order #x` select from: the current worktree's
    /// panes. Empty when nothing is current.
    private func currentWorktreeAgentRefs() -> [AgentRef] {
        guard let path = dashboardVC?.lastCommittedWorktreePath else { return [] }
        return ShipLog.shared.sailors(forWorktree: path).map {
            AgentRef(id: $0.id,
                     project: $0.project,
                     branch: $0.branch,
                     type: $0.agentType.displayName,
                     title: Self.agentTitle(for: $0))
        }
    }

    /// Title for one agent/pane — see `PaneTitleResolver`.
    private static func agentTitle(for sailor: SailorInfo) -> String {
        PaneTitleResolver.title(for: sailor)
    }

    private static func describeChatError(_ err: BridgeCommandError) -> String {
        switch err {
        case .emptyTask:              return "Nothing to do — add a task."
        case .unknownCommand(let c):  return "Unknown command: `\(c)`"
        case .unknownBranch(let b):   return "No worktree on branch `\(b)`"
        case .unknownTarget(let t):   return "No worktree or repo named `\(t)`"
        case .missingArgument(let a): return "`\(a)` needs an argument."
        }
    }

    private func routeChatCommand(_ cmd: BridgeCommand, force: Bool, reply: @escaping (String) -> Void) {
        switch cmd {
        case .newWorktree(let task, let repoHint):
            let repoPath = repoHint ?? tabCoordinator.config.workspacePaths.first ?? ""
            guard !repoPath.isEmpty else { reply("No repo configured."); return }
            // Starting a task is also moving to it — the phone has no dashboard to
            // click, so a create that left `current` behind would strand the reply.
            performWorktreeCreate(task: task, repoPath: repoPath, agentType: .claudeCode,
                                  reuseEnv: false) { [weak self] path in
                guard let path else { return }
                self?.dashboardVC?.commitWorktreeSelection(path: path)
            }
            reply("Starting **\(URL(fileURLWithPath: repoPath).lastPathComponent)** — \(task)")

        case .listWorktrees:
            reply(BridgeCommandFormatter.worktreeList(
                currentWorktreeRefs(), currentPath: dashboardVC?.lastCommittedWorktreePath))

        case .selectWorktree(let path):
            dashboardVC?.commitWorktreeSelection(path: path)
            let branch = currentWorktreeRefs().first { $0.path == path }?.branch ?? path
            if let s = ShipLog.shared.sailor(forWorktree: path) {
                reply("Now on **\(s.project)** [\(branch)]")
            } else {
                reply("Now on [\(branch)] — no agent there yet. `/task <description>` to start one.")
            }

        case .listAgents:
            guard dashboardVC?.lastCommittedWorktreePath != nil else {
                reply("No current task. `/task` to pick one.")
                return
            }
            reply(BridgeCommandFormatter.agentList(
                currentWorktreeAgentRefs(),
                currentId: dashboardVC?.lastCommittedWorktreePath
                    .flatMap { ShipLog.shared.sailor(forWorktree: $0)?.id }))

        case .selectAgent(let id):
            guard let s = ShipLog.shared.sailor(for: id) else {
                reply("That agent is gone. `/agents` to see what's left.")
                return
            }
            dashboardVC?.commitWorktreeSelection(path: s.worktreePath)
            reply("Now steering **\(s.project)** [\(s.branch)]")

        case .listRepos:
            reply(BridgeCommandFormatter.repoList(tabCoordinator.config.workspacePaths))

        case .orderAgent(let id, let task):
            guard let s = ShipLog.shared.sailor(for: id) else { reply("No such agent."); return }
            ShipLog.shared.sendCommand(to: s.id, command: task)
            reply("→ **\(s.project)** [\(s.branch)]")

        case .broadcast(let task):
            let all = ShipLog.shared.allSailors()
            guard !all.isEmpty else { reply("No agents running."); return }
            for s in all { ShipLog.shared.sendCommand(to: s.id, command: task) }
            reply("Sent to \(all.count) agent\(all.count == 1 ? "" : "s").")

        case .addRepo:
            reply("`/add` is desktop only — it needs a file picker.")

        case .removeAll:
            // Cards, exactly as on the desktop. A blind sweep is the one place
            // direct execution could delete several worktrees from one stray line.
            let targets = tabCoordinator.allWorktrees.map(\.info).filter { !$0.isMainWorktree }
            for info in targets { enqueueReturnCard(forPath: info.path) }
            reply("Reviewing \(targets.count) worktree\(targets.count == 1 ? "" : "s") — approve on the desktop.")

        case .removeRepo(let path):
            // lastPathComponent is what the parser matched to resolve `path`, so it
            // is also the tab's displayName. Executed rather than confirmed: this
            // only kills sessions and leaves every worktree on disk, so nothing
            // unrecoverable rides on it.
            let name = URL(fileURLWithPath: path).lastPathComponent
            tabCoordinator.performCloseRepo(projectName: name)
            reply("Dropped **\(name)**. Its worktrees are still on disk.")

        case .removeWorktree(let path):
            let branch = tabCoordinator.allWorktrees.first { $0.info.path == path }?.info.branch ?? ""
            if ShipLog.shared.sailor(forWorktree: path)?.status == .running {
                reply("**\(branch)** has an agent running — leaving it alone.")
                return
            }
            // The desktop's sheet exists to stop uncommitted work being lost, not
            // as ceremony. Chat keeps that guard and moves it into the reply.
            // The dirty check is a synchronous git subprocess — run it off-thread.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let dirty = !force && WorktreeDeleter.hasUncommittedChanges(worktreePath: path)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if dirty {
                        reply("**\(branch)** has uncommitted changes — they'd be lost.\nSend `/remove @\(branch) force` if you mean it.")
                        return
                    }
                    self.terminalCoordinator.deleteWorktreeForReturnToPort(path: path, branch: branch, force: force)
                    reply("Deleted **\(branch)**.")
                }
            }
        }
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
            selectWorktree: { [weak self] path in
                self?.dashboardVC?.commitWorktreeSelection(path: path)
            },
            selectAgent: { [weak self] id in
                guard let path = ShipLog.shared.sailor(for: id)?.worktreePath else { return }
                self?.dashboardVC?.commitWorktreeSelection(path: path)
            },
            showOverview: { [weak self] in
                // The dashboard IS the listing; the chat reply is its text stand-in.
                self?.tabCoordinator.switchToTab(0)
            },
            orderAgent: { id, task in
                ShipLog.shared.sendCommand(to: id, command: task)
            },
            removeAll: { [weak self] in
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
            removeRepo: { [weak self] path in
                guard let self else { return }
                // Reuse the same confirmation the "Close Repo" context menu shows —
                // this kills the repo's persisted sessions, so it must not be a
                // silent one-liner. displayName is the repo's directory name, which
                // is exactly what the parser matched to resolve `path`.
                self.tabCoordinator.showCloseProjectModal(
                    URL(fileURLWithPath: path).lastPathComponent, window: self.window)
            },
            removeWorktree: { [weak self] path in
                guard let self,
                      let item = self.tabCoordinator.allWorktrees.first(where: { $0.info.path == path })
                else { return }
                // Same confirm sheet as the sidebar's Delete: typing a branch name is
                // easy to get wrong, and the work in that tree is unrecoverable.
                self.terminalCoordinator.confirmAndDeleteWorktree(item.info, window: self.window)
            },
            activeSailorCount: { ShipLog.shared.allSailors().count },
            branchForPath: { path in ShipLog.shared.sailor(forWorktree: path)?.branch ?? "" },
            projectForPath: { path in ShipLog.shared.sailor(forWorktree: path)?.project ?? "" }
        )
    }

    /// Run a merge check for `path` on a background thread and enqueue a
    /// return-to-port card with appropriate options once the check completes.
    /// Resolve a `/remove` sweep for one worktree. If it is clean AND fully merged,
    /// remove it immediately (no confirmation). Otherwise enqueue a red
    /// "Force remove" card requiring explicit confirmation. `onDone` fires on the
    /// main thread once resolved (deleted or carded).
    private func enqueueReturnCard(forPath path: String, onDone: (() -> Void)? = nil) {
        let repoCache = tabCoordinator.worktreeRepoCache
        let queue = tabCoordinator.pendingOrders
        let coordinator = terminalCoordinator
        let sailor = ShipLog.shared.sailor(forWorktree: path)

        // A worktree with a live agent must never be reaped by /remove: neither
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
        case presented   // dropped an order card (e.g. /remove)
        case failed      // error
    }

    /// Submit a Helm command. Returns `true` if it kicked off async work (so the
    /// caller shows a loading spinner); `onOutcome` then fires when the work
    /// completes — `.navigated` for a new tab, `.presented` for an order card,
    /// `.failed` on error. Synchronous commands route immediately and return `false`.
    @discardableResult
    func submitBridgeCommand(_ text: String, onOutcome: ((HelmCommandOutcome) -> Void)? = nil) -> Bool {
        switch BridgeCommandParser.parse(text, worktrees: currentWorktreeRefs(),
                                         agents: currentWorktreeAgentRefs(),
                                         repoPaths: tabCoordinator.config.workspacePaths) {
        case .success(let command):
            switch command {
            case .newWorktree(let task, let repoHint):
                let repoPath = repoHint ?? tabCoordinator.config.workspacePaths.first ?? ""
                performWorktreeCreate(task: task, repoPath: repoPath, agentType: .claudeCode,
                                      reuseEnv: false) { [weak self] path in
                    if let path { self?.dashboardVC?.commitWorktreeSelection(path: path) }
                    onOutcome?(path != nil ? .navigated : .failed)
                }
                return true

            case .removeAll:
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

        // Spanning NSTitlebarAccessoryViewController removed — column headers
        // live in WindowChromeController. Keep transparent fullSizeContentView
        // titlebar so traffic lights can be reparented.
        window.toolbar = nil

        DispatchQueue.main.async { [weak self] in
            self?.positionStandardWindowButtons()
        }
    }

    // Fullscreen must hand the traffic lights back to the system titlebar,
    // otherwise they stay pinned in the sidebar header and lose the native
    // auto-hide / top-edge reveal / exit-fullscreen zoom behaviors.
    // (NSWindowDelegate — this controller is the window's delegate.)
    func windowWillEnterFullScreen(_ notification: Notification) {
        isWindowFullscreen = true
        restoreNativeWindowButtons()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isWindowFullscreen = false
        positionStandardWindowButtons()
    }

    /// Return the traffic lights to the system titlebar so macOS manages them.
    private func restoreNativeWindowButtons() {
        guard let window, let home = nativeTrafficLightHome else { return }
        let buttons: [NSButton] = [.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        for button in buttons where button.superview !== home {
            button.removeFromSuperview()
            home.addSubview(button)
        }
        // The titlebar view owns standard-button layout; poke it once.
        home.needsLayout = true
    }

    private func positionStandardWindowButtons() {
        guard let window, let chrome = windowChrome else { return }
        // Fullscreen: buttons belong to the system titlebar (native auto-hide
        // and top-edge reveal) — never steal them while fullscreen.
        guard !isWindowFullscreen else { return }
        guard let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton)
        else {
            return
        }

        // Remember where the system put them before the first reparent.
        if nativeTrafficLightHome == nil, let home = close.superview,
           home.isDescendant(of: chrome.view) == false {
            nativeTrafficLightHome = home
        }

        let host = chrome.trafficLightHostView(collapsed: chromeState.isCollapsed)
        host.layoutSubtreeIfNeeded()

        let buttons = [close, mini, zoom]
        for button in buttons where button.superview !== host {
            button.removeFromSuperview()
            host.addSubview(button)
        }

        let spacing: CGFloat = 6
        var x: CGFloat = 0
        let hostHeight = host.bounds.height > 0 ? host.bounds.height : 14
        for button in buttons {
            let y = (hostHeight - button.frame.height) / 2
            button.setFrameOrigin(NSPoint(x: x, y: max(0, y)))
            x += button.frame.width + spacing
        }
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

    override func mouseEntered(with event: NSEvent) {}

    override func mouseExited(with event: NSEvent) {}

    /// Embed `WindowChromeController` in `contentContainer` and slot dashboard hosts.
    private func embedChromeShell(dashboard: DashboardViewController) {
        if windowChrome == nil {
            let chrome = WindowChromeController()
            windowChrome = chrome
            chrome.view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(chrome.view)
            NSLayoutConstraint.activate([
                chrome.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                chrome.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                chrome.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                chrome.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])

            chromeState = ChromeLayoutState(
                width: config.sidebarWidth,
                collapsed: false,
                activePane: .firstMate
            )
            chrome.applyState(chromeState, animated: false)
            chrome.headerDelegate = self
            chrome.onStateChange = { [weak self] state in
                self?.handleChromeStateChange(state)
            }
        }

        // Keep dashboard.view in the window (below chrome) for first-responder
        // association and overlays (help). Content hosts live in chrome slots.
        if let chrome = windowChrome, dashboard.view.superview !== contentContainer {
            dashboard.view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(dashboard.view, positioned: .below, relativeTo: chrome.view)
            NSLayoutConstraint.activate([
                dashboard.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                dashboard.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                dashboard.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                dashboard.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        }

        guard let chrome = windowChrome else { return }
        chrome.headerDelegate = self
        chrome.setSidebarContent(dashboard.navigatorHostView)
        chrome.setTerminalContent(dashboard.terminalHostView)
        positionStandardWindowButtons()
        refreshChromeWorktreeContextEnabled()
        refreshRegionAvailability()
    }

    private func handleChromeStateChange(_ state: ChromeLayoutState) {
        let widthChanged = abs(state.width - config.sidebarWidth) > 0.5
        let collapseChanged = state.isCollapsed != chromeState.isCollapsed
        chromeState = state
        if widthChanged {
            // Persist width only — never write 0 for a collapsed sidebar.
            config.sidebarWidth = state.width
            tabCoordinator.config.sidebarWidth = state.width
            saveConfig()
        }
        positionStandardWindowButtons()
        if collapseChanged {
            dashboardVC?.adoptChromeCollapse(state.isCollapsed, activePane: state.activePane)
            syncKeyboardToChromeCollapse()
        }
    }

    private func embedViewController(_ vc: NSViewController) {
        if let dashboard = vc as? DashboardViewController {
            embedChromeShell(dashboard: dashboard)
            return
        }

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
        refreshIdleWorktreePaths()
        updateChromeTitle()
        updatePrimaryCapsuleNotification()
        // Sailors load / auto-select land here — keep Files/Changes enablement in sync.
        refreshChromeWorktreeContextEnabled()
        refreshRegionAvailability()
    }

    /// Worktrees with no agent interaction for longer than this are treated as
    /// idle for the card-grid expander (overview navigator does not collapse them).
    private static let tabIdleCollapseInterval: TimeInterval = 8 * 3600

    private func refreshIdleWorktreePaths() {
        let selectedPath = tabCoordinator.selectedSailor?.worktreePath
        let now = Date()
        var idle: Set<String> = []
        for entry in tabCoordinator.allWorktrees {
            let path = entry.info.path
            let isSelected = path == selectedPath
            let agent = ShipLog.shared.sailor(forWorktree: path)
            let lastActivity = statusAggregator.lastActivity(for: path) ?? agent?.startedAt
            let isIdle = lastActivity.map { now.timeIntervalSince($0) > Self.tabIdleCollapseInterval } ?? false
            if isIdle && !isSelected && !entry.info.isMainWorktree {
                idle.insert(path)
            }
        }
        tabCoordinator.dashboardVC?.updateFleetSummary(
            repos: tabCoordinator.workspaceManager.tabs.count,
            worktrees: tabCoordinator.allWorktrees.count,
            hidden: idle.count
        )
        tabCoordinator.dashboardVC?.idleWorktreePaths = idle
    }

    /// Drive the terminal chrome header: `Repo · pane title`.
    private func updateChromeTitle() {
        guard let agent = tabCoordinator.selectedSailor else {
            windowChrome?.updateTerminalTitle(repo: "", pane: "")
            return
        }
        let path = agent.worktreePath
        let info = ShipLog.shared.sailor(forWorktree: path)
        let repo = (info?.project).flatMap { $0.isEmpty ? nil : $0 }
            ?? tabCoordinator.repoName(forWorktree: path)

        let paneTitle: String
        if let tree = terminalCoordinator.stationManager.tree(forPath: path),
           let stationId = PaneTitleResolver.focusedStationId(in: tree),
           let focusedSailor = ShipLog.shared.sailors(forWorktree: path)
            .first(where: { $0.id == stationId }) {
            paneTitle = PaneTitleResolver.title(for: focusedSailor)
        } else if let info {
            paneTitle = PaneTitleResolver.title(for: info)
        } else {
            paneTitle = WorktreeTitleResolver.resolve(
                worktreePath: path,
                lastUserPrompt: "",
                branch: ""
            )
        }
        windowChrome?.updateTerminalTitle(repo: repo, pane: paneTitle)
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
        if let historyChangeObserver {
            NotificationCenter.default.removeObserver(historyChangeObserver)
        }
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

    /// Keyboard cycle through worktrees (Ctrl+Tab / Ctrl+Shift+Tab).
    func selectAdjacentWorktree(forward: Bool) {
        let paths = tabCoordinator.allWorktrees.map(\.info.path)
        let current = tabCoordinator.selectedSailor?.worktreePath
        guard let path = WorktreePathNavigation.adjacentPath(
            paths: paths, from: current, forward: forward
        ) else { return }
        tabCoordinator.selectTab(forWorktree: path)
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
            mwc.toggleChromeCollapsed(); return true
        case .exitInsert:
            mwc.navigateBack(); return true
        case .toggleOverview:
            mwc.navigateBack(); return true   // Cmd+E: mouse-discoverable back alias
        case .firstMatePane:
            mwc.selectChromePane(.firstMate); return true
        case .filesPane:
            mwc.selectChromePane(.files); return true
        case .changesPane:
            mwc.selectChromePane(.changes); return true
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
            // Cmd+Esc = unified back key (mode 3 → 2 → 1, and 1 ⇄ 2 toggle).
            // macOS does not route Cmd+Esc through performKeyEquivalent the way it
            // does Cmd+<letter>, so it lands here. Read the real Command flag —
            // a plain Esc must keep passing through to the terminal (interrupting
            // the agent otherwise).
            if event.keyCode == 53,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
               let mwc = windowController as? MainWindowController {
                mwc.navigateBack()
                return
            }
            // Tab / Shift+Tab while the chrome header owns region focus: cycle
            // regions (dashboard's keyDown won't see these — icons are first responder).
            if event.keyCode == 48,
               let mwc = windowController as? MainWindowController,
               mwc.keyboardMode.mode == .normal,
               mwc.keyboardMode.substate == .none,
               mwc.regionFocus.current == .titlebar {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.isDisjoint(with: [.command, .control, .option]) {
                    mwc.cycleKeyboardRegion(forward: !flags.contains(.shift))
                    return
                }
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

    func windowWillStartLiveResize(_ notification: Notification) {
        // Clears chrome-drag suppression so the grid can match the new window.
        GhosttyBridge.shared.beginLiveResize(pinHeight: false)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        GhosttyBridge.shared.endLiveResize()
        // Force a real grid sync now that suppression is cleared.
        for station in StationRegistry.shared.allStations() {
            station.syncSize()
        }
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

// MARK: - ChromeHeaderDelegate

extension MainWindowController: ChromeHeaderDelegate {
    func chromeDidToggleTheme() {
        toggleThemeAppearance()
    }

    func chromeDidSelectPane(_ pane: ChromeLeftPane) {
        selectChromePane(pane)
    }

    func chromeDidToggleSidebar() {
        toggleChromeCollapsed()
    }
}

// MARK: - Theme

extension MainWindowController {
    fileprivate func toggleThemeAppearance() {
        let isDark = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let next: ThemeMode = isDark ? .light : .dark
        config.themeMode = next.rawValue
        tabCoordinator.config.themeMode = next.rawValue
        terminalCoordinator.config.themeMode = next.rawValue
        updateCoordinator.config.themeMode = next.rawValue
        saveConfig()
        ThemeMode.applyAppearance(next)
        switch next {
        case .dark:
            window?.appearance = NSAppearance(named: .darkAqua)
        case .light:
            window?.appearance = NSAppearance(named: .aqua)
        case .system:
            window?.appearance = nil
        }
        NSAppearance.current = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        applyWindowBackgroundStyle()
        // libghostty only learns about appearance when the host pushes it; the
        // KVO observer can race window.appearance, so sync explicitly after toggle.
        GhosttyBridge.shared.refreshColorScheme()
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
        refreshChromeWorktreeContextEnabled()
    }

    func dashboardDidRequestBrowseFiles(worktreePath: String) {
        selectChromePane(.files)
    }

    func dashboardDidRequestShowChanges(worktreePath: String) {
        selectChromePane(.changes)
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
        // Spec: pane focus change drives `Repo · pane` in the terminal header.
        updateChromeTitle()
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

// MARK: - Island Overlay

extension MainWindowController {
    private func setupIsland() {
        guard config.islandEnabled else { return }
        // Live test hosts must not float an overlay over the desktop.
        guard NSClassFromString("XCTestCase") == nil else { return }

        let model = islandController.model
        model.onNavigate = { [weak self] worktreePath, paneIndex in
            self?.tabCoordinator.handleNavigateToWorktree(worktreePath: worktreePath, paneIndex: paneIndex)
            self?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        model.onOptionTapped = { [weak self] order, optionText in
            self?.handleSuggestionTapped(order: order, optionText: optionText)
        }
        model.onDismissOrder = { [weak self] order in
            self?.tabCoordinator.pendingOrders.resolve(id: order.id)
        }
        model.onMarkAllRead = {
            NotificationHistory.shared.markAllRead()
        }
        model.onSubmitCommand = { [weak self] text in
            _ = self?.submitBridgeCommand(text)
        }
        model.commandMenuProvider = { [weak self] trigger, query in
            self?.helmMenuItems(trigger: trigger, query: query) ?? []
        }
        islandController.install()

        tabCoordinator.pendingOrders.addObserver { [weak self] in
            self?.refreshIsland()
        }
        // Push-driven: worktree status changes arrive via
        // tabCoordinatorRequestUpdateTitleBar, notification changes via the
        // history's NotificationCenter post. The timer is only a slow fallback
        // for async stragglers (e.g. title resolution finishing later).
        historyChangeObserver = NotificationCenter.default.addObserver(
            forName: .notificationHistoryDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshIsland()
        }
        islandRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refreshIsland()
        }
        refreshIsland()
    }

    fileprivate func refreshIsland() {
        guard config.islandEnabled else { return }
        let model = islandController.model

        // Aggregate per-worktree: the highest-urgency pane wins the row.
        // The island only shows worktrees with activity in the last 24 hours —
        // it is a "what's happening now" surface, not the full fleet list.
        let activityCutoff = Date().addingTimeInterval(-24 * 60 * 60)
        var byWorktree: [String: IslandAgentRow] = [:]
        for sailor in ShipLog.shared.allSailors() {
            let lastActivity = statusAggregator.lastActivity(for: sailor.worktreePath) ?? sailor.startedAt
            guard let lastActivity, lastActivity >= activityCutoff else { continue }
            // Same resolver as the dashboard cards, but via the shared TTL
            // cache — a direct resolve() reads session JSONL from disk, and
            // this runs on main for every sailor on every island refresh.
            // Warm the cache off-main; the next tick picks up the result.
            WorktreeTitleCache.shared.title(
                worktreePath: sailor.worktreePath,
                lastUserPrompt: sailor.lastUserPrompt,
                branch: sailor.branch
            ) { _ in }
            let cachedTitle = WorktreeTitleCache.shared.cachedTitle(worktreePath: sailor.worktreePath)
            let row = IslandAgentRow(
                id: sailor.worktreePath,
                project: sailor.project,
                branch: sailor.branch,
                status: sailor.status,
                message: sailor.lastAssistantMessage.isEmpty ? sailor.lastMessage : sailor.lastAssistantMessage,
                // The island row already renders the branch separately — drop a
                // title that is just the branch fallback.
                title: (cachedTitle == sailor.branch ? "" : cachedTitle) ?? sailor.lastUserPrompt
            )
            if let existing = byWorktree[sailor.worktreePath] {
                if Self.notificationPriorityScoreForIsland(row.status) > Self.notificationPriorityScoreForIsland(existing.status) {
                    byWorktree[sailor.worktreePath] = row
                }
            } else {
                byWorktree[sailor.worktreePath] = row
            }
        }
        // Branch alone ties for every "main" worktree, and dictionary order plus
        // Swift's unstable sort made those rows shuffle on each refresh. Break
        // ties deterministically: project, then path (unique).
        let rows = byWorktree.values.sorted {
            ($0.branch, $0.project, $0.id) < ($1.branch, $1.project, $1.id)
        }
        if model.rows != rows { model.rows = rows }

        // Equality-gate every assignment: this runs on a 2s timer, and an
        // ungated @Observable set re-evaluates the SwiftUI island every tick
        // even when nothing changed.
        let primary = primaryCapsuleNotification
        if model.primaryEntry != primary { model.primaryEntry = primary }
        let unread = NotificationHistory.shared.unreadCount
        if model.unreadCount != unread { model.unreadCount = unread }
        let recent = Array(
            NotificationHistory.shared.entries
                .filter { !$0.isRead }
                .prefix(IslandModel.maxRecentNotifications)
        )
        if model.recentNotifications != recent { model.recentNotifications = recent }

        let orders = tabCoordinator.pendingOrders.all()
            .filter { $0.action.kind == .suggestNextOrder }
        if model.orders != orders { model.orders = orders }

        // Pop the pill when something new needs attention while closed.
        let orderIDs = Set(orders.map(\.id))
        let hasNewOrder = !orderIDs.subtracting(islandKnownOrderIDs).isEmpty
        let hasNewUnread = model.unreadCount > islandKnownUnread
        islandKnownOrderIDs = orderIDs
        islandKnownUnread = model.unreadCount
        if hasNewOrder && !model.isOpened {
            // A suggestion is actionable — expand so the card is visible
            // without hovering. Plain notifications just pop the pill.
            islandController.openForEvent()
        } else if hasNewUnread && !model.isOpened {
            if let entry = primaryCapsuleNotification ?? NotificationHistory.shared.entries.first {
                let name = entry.workspaceName.isEmpty ? entry.branch : entry.workspaceName
                model.flashTransient("\(name) · \(entry.message)")
            } else {
                model.pop()
            }
        }
        islandController.updateVisibility()
    }

    private static func notificationPriorityScoreForIsland(_ status: SailorStatus) -> Int {
        switch status {
        case .error, .exited: return 4
        case .waiting: return 3
        case .running: return 2
        case .idle: return 1
        case .unknown: return 0
        }
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
        refreshIsland()
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
                channel.onAuthExpired = { [weak self] in
                    self?.promptWeChatReauth()
                }
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
        // Fires on every worktree status change — the island's push channel
        // for agent rows (replaces the old 2s full-rebuild poll).
        refreshIsland()
    }
    func tabCoordinatorRequestShowNewBranchDialog(_ coordinator: TabCoordinator) {
        showNewBranchDialog()
    }
    func tabCoordinatorRequestClearContentContainer(_ coordinator: TabCoordinator) {
        // Keep the chrome shell mounted; switchToTab(0) re-slots dashboard hosts.
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
        // Status bar removed — mode still drives keyboard routing.
    }
    func keyboardHintDidChange(_ hint: String) {
        // Status bar removed — hints unused in chrome.
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
            // opencode's question TUI has no digit shortcuts (a digit would land
            // in the custom-answer field), so drive it with arrow keys instead.
            if let idx = order.action.options?.firstIndex(of: optionText) {
                if ShipLog.shared.sailor(for: order.action.terminalID)?.agentType == .openCode {
                    ShipLog.shared.answerChoiceByArrows(to: order.action.terminalID, index: idx)
                } else {
                    ShipLog.shared.sendCommand(to: order.action.terminalID, command: "\(idx + 1)")
                }
            }
            // Multi-question call: the TUI advances to the next question, so the
            // card follows instead of vanishing with N-1 questions unanswered.
            if let next = order.action.followups?.first {
                let a = order.action
                tabCoordinator.pendingOrders.resolve(id: order.id)
                tabCoordinator.pendingOrders.enqueue(FirstMateAction(
                    kind: a.kind, zone: a.zone, worktreePath: a.worktreePath,
                    branch: a.branch, project: a.project, terminalID: a.terminalID,
                    message: next.prompt, payload: a.payload, options: next.options,
                    followups: (a.followups?.count ?? 0) > 1 ? Array(a.followups!.dropFirst()) : nil))
                return
            }
        } else {
            ShipLog.shared.sendCommand(to: order.action.terminalID, command: optionText)
        }
        tabCoordinator.pendingOrders.resolve(id: order.id)
    }

    func handleBridgeApprove(_ order: PendingOrder) {
        switch order.action.kind {
        case .suggestNextOrder:
            // Send to the pane that raised the suggestion. Re-resolving the
            // worktree here would pick its *first* pane, so a suggestion from a
            // split pane got answered in a sibling.
            let worktreePath = order.action.worktreePath
            guard let task = WorktreeTaskStore.shared.task(forWorktree: worktreePath) else { return }
            let terminalID = order.action.terminalID.isEmpty
                ? ShipLog.shared.sailor(forWorktree: worktreePath)?.id
                : order.action.terminalID
            guard let terminalID else { return }
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
