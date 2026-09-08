import AppKit
import ApplicationServices

enum WindowStyling {
    struct GlassBackgroundConfig {
        let enabled: Bool
        let material: NSVisualEffectView.Material
        let blendingMode: NSVisualEffectView.BlendingMode
    }

    static func glassBackgroundConfig(isDark: Bool) -> GlassBackgroundConfig {
        // One material for both themes. Dark used `.hudWindow`, which is so
        // translucent the wallpaper tinted the whole chrome; the preferred dark
        // look is `.underWindowBackground` (deeper, near-opaque) — previously
        // only reachable by accident via a light→dark toggle race.
        GlassBackgroundConfig(enabled: true, material: .underWindowBackground, blendingMode: .behindWindow)
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
    private var pairingWindowController: PairingWindowController?
    private var settingsWindowController: SettingsWindowController?
    /// Live Telegram bridge, held so a Settings save can tear the old one down.
    /// Nil when the bridge is unconfigured or was started by AppDelegate and
    /// never reconfigured — `unregisterChannel("telegram")` covers that case.
    private var telegramChannel: TelegramChannel?
    /// The throwaway bridge the setup wizard runs on. Held apart from
    /// `telegramChannel` so ending pairing restores the configured bridge
    /// rather than leaving the wizard's token in place.
    private var telegramPairingChannel: TelegramChannel?
    /// Fleet row lit while a context-menu `/return` is assessing. Cleared when
    /// a sheet appears, the command fails, or the tear-down finishes.
    private var pendingReturnPath: String?
    /// One executor for every surface: the Helm line, Telegram and mail all
    /// run their lines through it, so a command means one thing everywhere.
    private lazy var commandExecutor = CommandExecutor(host: self, sessions: tabCoordinator.commandSessions)
    private var gmailOAuthCoordinator: GmailOAuthCoordinator?
    private var gmailMailPoller: GmailMailPoller?
    /// Suppresses repeat alerts while the same failure persists.
    private var lastTelegramError: String?
    private var runtimeBackend: String = "zmx"
    private var primaryCapsuleNotification: NotificationEntry?
    private var dismissedPrimaryCapsuleNotificationIDs: Set<UUID> = []
    private var primaryCapsuleDismissWorkItem: DispatchWorkItem?
    private lazy var usageSummaryStore = UsageSummaryStore()

    // Vibe-island notch overlay
    private let islandController = IslandPanelController()
    private var islandRefreshTimer: Timer?
    private var islandSeenSuggestions = SuggestionSeenSet()
    /// Suggestion orders already surfaced through the First Mate sidebar. Tracked
    /// separately from `islandSeenSuggestions`: the island's set is also advanced by
    /// its 10s fallback timer, which would eat the "new order" edge this needs.
    private var revealedSuggestions = SuggestionSeenSet()
    /// Cards already mirrored to chat. Its own set: a card the island has shown
    /// still has to reach the phone, and the phone must not be sent the same
    /// question twice because the desktop happened to re-pop it.
    private var chatSeenCards = SuggestionSeenSet()
    /// Where each card's buttons are drawn right now, so they can be taken down
    /// when the card goes — answered on the Mac, or the agent moved past it.
    private var cardButtonMessages: [String: [ChatNoticeBook.Ref]] = [:]
    /// The last thing said about a pane in each chat. An agent's suggested next
    /// steps are added to that message as buttons rather than arriving as a
    /// second message repeating the words it already carries.
    private var noticeBook = ChatNoticeBook()

    // Terminal management
    /// GitHub token 解析，来源优先级：
    /// 1. 环境变量 GITHUB_TOKEN / GH_TOKEN
    /// 2. gh CLI (无需 project context)
    /// 3. 系统钥匙串 (无需 project context)
    /// 4. 项目根目录的 .env / .env.local（需要选中 worktree）
    /// 5. 项目根目录的 git config --local github.token（需要选中 worktree）
    private var resolvedGitHubToken: String {
        Self.resolveGitHubToken(repoPath: tabCoordinator.config.selectedWorktreePath)
    }

    /// Static so a background queue can call it with the path read on main;
    /// two of the sources are subprocesses with a deadline.
    static func resolveGitHubToken(repoPath selectedRepoPath: String?) -> String {
        // 1. 环境变量
        if let env = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ??
            ProcessInfo.processInfo.environment["GH_TOKEN"], !env.isEmpty {
            return env
        }

        // 2. gh CLI — 不需要 project context，只要 gh 装好登录了就能拿到
        if let ghToken = Self.ghAuthToken() {
            return ghToken
        }

        // 3. 系统钥匙串 — 也不需要 project context
        if let helperToken = Self.gitCredentialToken() {
            return helperToken
        }

        // 4-5. 需要 project 目录的来源，有 worktree path 才尝试
        guard let repoPath = selectedRepoPath else { return "" }

        for envFile in [".env", ".env.local"] {
            let url = URL(fileURLWithPath: repoPath).appendingPathComponent(envFile)
            if let token = Self.readEnvFileToken(at: url.path) {
                return token
            }
        }

        if let localToken = Self.gitLocalConfigToken(in: repoPath) {
            return localToken
        }

        return ""
    }

    /// 解析 .env 文件的 GITHUB_TOKEN 或 GH_TOKEN 行。
    private static func readEnvFileToken(at path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }          // 跳过注释
            if trimmed.hasPrefix("GITHUB_TOKEN=") {
                return String(trimmed.dropFirst("GITHUB_TOKEN=".count))
            }
            if trimmed.hasPrefix("GH_TOKEN=") {
                return String(trimmed.dropFirst("GH_TOKEN=".count))
            }
        }
        return nil
    }

    /// 从项目级 git config 读 github.token。
    /// 用户只需在项目目录执行：`git config github.token ghp_xxx`
    private static func gitLocalConfigToken(in repoPath: String) -> String? {
        guard let raw = GitProcess.run(["config", "--local", "github.token"], in: repoPath) else {
            return nil
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// 通过 `gh auth token` 拿 gh CLI 缓存的 token。
    /// 先查 PATH，再查常见安装路径，兼容 Intel 和 Apple Silicon。
    private static func ghAuthToken() -> String? {
        let candidates: [String] = {
            // 1. PATH 中找到的 gh
            if let fromPath = Self.findInPATH("gh") { return [fromPath] }
            // 2. 常见安装路径
            return [
                "/opt/homebrew/bin/gh",
                "/usr/local/bin/gh",
                "\(NSHomeDirectory())/.local/bin/gh",
            ]
        }()

        for ghPath in candidates {
            let url = URL(fileURLWithPath: ghPath)
            guard FileManager.default.isExecutableFile(atPath: ghPath) else { continue }
            let result = ProcessRunner.capture(
                executable: url,
                arguments: ["auth", "token"],
                timeout: ProcessRunner.lookupTimeout
            )
            guard result.succeeded else { continue }
            let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        return nil
    }

    /// 从 PATH 环境变量中找可执行文件。
    private static func findInPATH(_ name: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.components(separatedBy: ":") where !dir.isEmpty {
            let full = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return nil
    }

    /// 通过 `git credential fill` 从系统钥匙串获取 github.com 的 token。
    private static func gitCredentialToken() -> String? {
        // A credential helper can sit waiting on a prompt that never comes, so
        // this needs a deadline as much as it needs its pipes drained.
        let result = ProcessRunner.capture(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["credential", "fill"],
            standardInput: "protocol=https\nhost=github.com\n\n",
            timeout: ProcessRunner.lookupTimeout
        )
        guard result.succeeded else { return nil }
        for line in result.stdout.components(separatedBy: .newlines) where line.hasPrefix("password=") {
            return String(line.dropFirst("password=".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

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
        // The island popping open with this pane's suggestion card already told
        // the user, better than a banner can — it carries the buttons. Only
        // while it is actually expanded: a collapsed pill has said nothing.
        NotificationManager.shared.isCardOnScreen = { [weak self] terminalID in
            guard let self, self.islandController.model.isOpened else { return false }
            return self.islandController.model.orders.contains { $0.action.terminalID == terminalID }
        }
        // Pane-status banners go to Telegram with binding awareness: after
        // `/go #n` that chat only hears #n, not the rest of the fleet. Other
        // external channels still get every event.
        //
        // `bannerSuppressed` means the user is looking at this very pane, so
        // the audiences that hear the whole fleet stay quiet — a phone ping for
        // something already on screen is noise. It does not silence a chat
        // bound to the pane: that conversation is happening away from this
        // desk, and its own order's answer must reach it.
        NotificationManager.shared.onDeliverExternal = { [weak self] status, title, subtitle, body, terminalID, bannerSuppressed in
            let text = "\(status.icon) **\(title)**\n\(subtitle)\n\n\(body)"
            if !bannerSuppressed {
                AgentRegistry.shared.broadcast(text, format: .markdown, excluding: ["telegram"])
            }
            self?.notifyTelegramSessions(terminalID: terminalID, text: text,
                                         fleetSilenced: bannerSuppressed)
        }
        // Not `tabCoordinator.commandRoute` here: that coordinator's own
        // initializer reads `statusPublisher`, and two lazy vars that reach
        // for each other recurse until the stack goes. Mail is wired in
        // `startGmailMailChannel`, after both exist.
        AgentRegistry.shared.commandRoute = { [weak self] text, surface, reply in
            self?.commandExecutor.run(text, surface: surface, reply: reply)
        }
        AgentRegistry.shared.ruleTriggerRoute = { [weak self] prompt, target in
            self?.dispatchRuleTrigger(prompt: prompt, target: target) ?? false
        }
        AgentRegistry.shared.callbackRoute = { [weak self] callback in
            self?.handleChatCallback(callback)
        }
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
        // This fires on nearly every status change across every worktree, so a
        // raw `config.save()` here — Config is a value type, and `config` is a
        // snapshot from launch — reliably clobbered fields owned elsewhere
        // (agentSessions chief among them: a resume ref recorded via
        // TerminalCoordinator moments earlier never survived to disk). Route
        // through the shared sync instead of saving this stale copy directly.
        saveConfig()
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePaneDidAcquireFocus(_:)),
            name: .paneDidAcquireFocus, object: nil
        )
        handleNotificationHistoryDidChange(nil)
        setupIsland()
        setupSuggestionReveal()
        // Claude only reports rate limits through its statusline payload, so
        // the bridge that captures it has to be in place before the first poll.
        DispatchQueue.global(qos: .utility).async {
            ClaudeStatuslineBridgeInstaller.ensureInstalled()
        }
        usageSummaryStore.onUpdate = { [weak self] claude, codex in
            self?.islandController.model.setUsageReadouts(
                UsageSummaryFormatter.readouts(claude: claude, codex: codex)
            )
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
        config.agentSessions = terminalCoordinator.config.agentSessions
        // Chrome layout is owned here — push into TabCoordinator so its saves
        // don't clobber sidebar_collapsed / sidebar_active_pane with defaults.
        tabCoordinator.config.sidebarWidth = config.sidebarWidth
        tabCoordinator.config.sidebarCollapsed = config.sidebarCollapsed
        tabCoordinator.config.sidebarActivePane = config.sidebarActivePane
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

    /// Held strongly so the window survives this call, and reused so ⌘, twice
    /// raises the existing one instead of stacking a second copy with stale
    /// config.
    @objc func showSettings() {
        if let existing = settingsWindowController {
            // Reused windows still hold the SettingsVC's private Config copy from
            // first open — refresh so a telegram token written after that open
            // (or restored from disk via merge-on-write) shows up.
            existing.reload(config: config)
            existing.show()
            return
        }
        let wc = dialogPresenter.makeSettings(config: config, settingsDelegate: self)
        settingsWindowController = wc
        wc.show()
    }

    /// Browser pairing window (8-digit code). Held strongly so it survives
    /// past this call. See `PairingWindowController`.
    @objc func showPairing() {
        _ = mintPairingContext()
        let accessURL = (config.hostGateway ?? HostGatewayConfig()).resolvedPageURL
        let code = currentPairingCode()
        let wc = PairingWindowController(
            accessURL: accessURL,
            code: code,
            onRefresh: { [weak self] in self?.refreshPairingCode() ?? "" },
            onRevokeAll: { [weak self] in self?.revokeAllRemotes() })
        wc.showWindow(nil)
        wc.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        pairingWindowController = wc
    }

    /// Type a rule-matched prompt into the pane its target names.
    ///
    /// Goes through `sendText(enter: true)` — the same write channel the control
    /// socket uses — so a triggered prompt is indistinguishable from one typed
    /// by hand, and lands whatever agent already owns that pane.
    private func dispatchRuleTrigger(prompt: String, target: TelegramRuleTarget) -> Bool {
        guard let dataSource = tabCoordinator.mqttDataSource else { return false }
        guard let pane = TelegramRuleEngine.resolvePane(target,
                                                        panes: dataSource.snapshotPanes())
        else { return false }
        return dataSource.sendText(paneId: pane.paneId, text: prompt, enter: true)
    }

    /// Mint + persist the root secret on the LIVE config (a throwaway
    /// `Config.load()` copy is clobbered by the app's own config saves), then
    /// reload Host Gateway so auth picks up the secret — no restart needed.
    ///
    /// Shared by the pairing window and the Settings pairing page: both render
    /// the same payload, and neither may mint its own.
    private func mintPairingContext() -> (secret: Data, mqtt: PairingIdentity) {
        if config.pairing == nil { config.pairing = PairingIdentity() }
        if config.pairing?.rootSecret == nil {
            config.pairing?.rootSecret = PairingCrypto.base64url(PairingCrypto.newRootSecret())
        }
        config.saveNow()
        let mqtt = config.pairing!
        tabCoordinator.applyMqttRootSecret(mqtt.rootSecret ?? "")
        let secret = PairingCrypto.rootSecret(fromBase64url: mqtt.rootSecret ?? "") ?? PairingCrypto.newRootSecret()
        return (secret, mqtt)
    }

    /// The Telegram bridge could not start. What reaches here is final — a
    /// token Telegram rejects, a bot already polled elsewhere — and only the
    /// user can fix it, so say it in a sheet rather than a log line the
    /// channel would otherwise sit silently dead behind.
    private func presentTelegramError(_ message: String) {
        guard let window, lastTelegramError != message else { return }
        lastTelegramError = message

        let alert = NSAlert()
        alert.messageText = "Telegram bridge unavailable"
        alert.informativeText = "\(message)\n\nCheck the bot token and allowed users under Settings › Telegram."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.showSettings()
        }
    }

    @objc func showNewBranchDialog() {
        // Cmd+N opens the island with `/new ` prefilled in its command field.
        islandController.openCommandBar(prefill: "/new ")
    }

    // MARK: - First Mate command shortcuts

    /// Open the island's command bar with a slash command prefilled. The island
    /// is the only command surface — the overview composer was removed, so these
    /// menu items and Cmd+N/Cmd+P all land in the same place.
    private func openHelmCockpit(prefill: String) {
        islandController.openCommandBar(prefill: prefill)
    }

    @objc func helmTaskCommand() { openHelmCockpit(prefill: "/new ") }
    @objc func helmAgentsCommand() { openHelmCockpit(prefill: "/status") }
    @objc func helmOrderCommand() { openHelmCockpit(prefill: "/order ") }
    @objc func helmBroadcastCommand() { openHelmCockpit(prefill: "/broadcast ") }
    @objc func helmReturnCommand() { openHelmCockpit(prefill: "/return ") }
    @objc func helmAddRepoCommand() { openHelmCockpit(prefill: "/add") }
    @objc func helmFlagCommand() { openHelmCockpit(prefill: "/feedback ") }

    @objc func splitHorizontal() { splitFocusedPane(axis: .horizontal) }
    @objc func splitVertical() { splitFocusedPane(axis: .vertical) }

    /// ⌘B — chrome collapse is the only layout collapse signal.
    @objc func toggleChromeCollapsed() {
        chromeState.toggleCollapsed()
        applyChromeState(animated: true)
    }

    /// Cmd+Esc / Cmd+E: leave the focused terminal chrome for the fleet list.
    func navigateBack() {
        tabCoordinator.switchToTab(0)
        toggleChromeCollapsed()
    }

    func setChromeCollapsed(_ collapsed: Bool) {
        guard chromeState.isCollapsed != collapsed else {
            // Still refresh dashboard content / keyboard when already in sync.
            dashboardVC?.adoptChromeCollapse(collapsed, activePane: chromeState.activePane)
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
        dashboardVC?.adoptChromeCollapse(chromeState.isCollapsed,
                                         activePane: chromeState.activePane,
                                         animated: animated)
        refreshChromeWorktreeContextEnabled()
        refreshRegionAvailability()
        persistChromeLayout()
        // Collapse swaps which header owns `Region.titlebar` — re-apply if focused.
        if regionFocus.current == .titlebar {
            applyRegionFocus()
        }
    }

    /// Write sidebar width / collapse / active pane into config.
    private func persistChromeLayout() {
        var changed = false
        if abs(chromeState.width - config.sidebarWidth) > 0.5 {
            config.sidebarWidth = chromeState.width
            changed = true
        }
        if config.sidebarCollapsed != chromeState.isCollapsed {
            config.sidebarCollapsed = chromeState.isCollapsed
            changed = true
        }
        if let pane = chromeState.activePane, config.sidebarActivePane != pane.rawValue {
            config.sidebarActivePane = pane.rawValue
            changed = true
        }
        guard changed else { return }
        saveConfig()
    }

    private func refreshChromeWorktreeContextEnabled() {
        let hasSelection = tabCoordinator.selectedPane != nil
            || !(dashboardVC?.selectedWorktreeId.isEmpty ?? true)
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
            islandController.openCommandBarFocused()
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
        islandController.openCommandBarFocused()
    }

    /// Cmd+P — the command palette. The island already *is* a focusable overlay
    /// panel with a command field, so this opens that rather than introducing a
    /// second floating surface. Pressing it again closes it.
    func toggleCommandPalette() {
        if islandController.isCommandBarOpen {
            islandController.closeCommandBar()
        } else {
            islandController.openCommandBarFocused()
        }
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
        let repositoryURL = URL(string: "https://github.com/\(UpdateCoordinator.repositoryOwner)/\(UpdateCoordinator.repositoryName)")!
        NSWorkspace.shared.open(repositoryURL)
    }

    private func openGitHubIssue(title: String) {
        let encodedTitle = title.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? title
        let urlString = "https://github.com/\(UpdateCoordinator.repositoryOwner)/\(UpdateCoordinator.repositoryName)/issues/new?title=\(encodedTitle)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func cleanOrphanSessions() {
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

            guard let self else { return }
            let activeSessionNames = self.activePaneSessionNamesForCleanup()
            let cleaned = SessionManager.cleanupOrphanZmxSessions(activeSessionNames: activeSessionNames)

            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = cleaned.isEmpty
                    ? "No orphan sessions found"
                    : "Cleaned \(cleaned.count) orphan session(s)"
                if cleaned.isEmpty {
                    alert.informativeText = "All seahelm zmx sessions are attached to currently open panes."
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

        // Update banner (pinned to the window bottom, hidden by default)
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

        NSLayoutConstraint.activate([
            backgroundEffectView.topAnchor.constraint(equalTo: contentView.topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            updateCoordinator.banner.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            updateCoordinator.banner.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            updateCoordinator.banner.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            contentContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: updateCoordinator.banner.topAnchor),
        ])

        // Window hover tracking for arc block styling
        setupWindowHoverTracking(contentView: contentView)

        // Create dashboard — single permanent LeftRight layout
        let dashboard = DashboardViewController()
        dashboard.integrationEnabled = config.integrationEnabled
        dashboard.dashboardDelegate = self
        dashboard.hasWorkspaces = { [weak self] in
            !(self?.tabCoordinator.config.workspacePaths.isEmpty ?? true)
        }
dashboard.stationManager = terminalCoordinator.stationManager
        dashboard.splitContainerDelegate = self
        dashboardVC = dashboard
        tabCoordinator.dashboardVC = dashboard

        // Every command entry point in the dashboard (n, `/ @ #`, Cmd+N) opens the
        // island's command bar — the fleet column has no composer of its own.
        dashboard.onRequestCommandBar = { [weak self] prefill in
            guard let self else { return }
            if prefill.isEmpty {
                self.islandController.openCommandBarFocused()
            } else {
                self.islandController.openCommandBar(prefill: prefill)
            }
        }

        dashboard.onEnterTerminal = { [weak self] in
            // Drilling into a terminal collapses the chrome sidebar (INSERT).
            self?.setChromeCollapsed(true)
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
        // Edit-mode toggle availability + on-state drive the chrome header icon.
        dashboard.onEditModeStateChange = { [weak self] available, isOn in
            self?.windowChrome?.setEditMode(available: available, isOn: isOn)
        }
        // Edit mode's column tab strips live on the chrome header row: the two
        // columns then cost one row of chrome instead of two.
        dashboard.editStripsProvider = { [weak self] in self?.windowChrome?.editStrips }
        dashboard.onEditModeStripsActive = { [weak self] active, ratio in
            self?.windowChrome?.setEditStripsActive(active, ratio: ratio)
        }
        dashboard.onEditStripRatioChange = { [weak self] ratio in
            self?.windowChrome?.setEditStripRatio(ratio)
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
            // Opens the Island's command line with `/new ` prefilled.
            self?.tabCoordinator.dashboardVC?.startNewCommand()
        }
        dashboard.onIntegrateProject = { [weak self] project in
            guard let self, let repoPath = self.tabCoordinator.repoPath(forProject: project) else {
                NSSound.beep()
                return
            }
            self.runIntegration(repoPath: repoPath, mode: .excludeConflicting, force: false)
        }
        dashboard.onResetIntegration = { [weak self] checkoutPath in
            self?.resetIntegration(checkoutPath: checkoutPath, force: false)
        }
        dashboard.onAddWorktreeToProject = { [weak self] project, rect, anchor in
            self?.presentAddWorktreePopover(project: project, rect: rect, anchor: anchor)
        }
        dashboard.onRequestAddRepo = { [weak self] in
            self?.tabCoordinator.addRepoViaOpenPanel(window: self?.window)
        }
        embedChromeShell(dashboard: dashboard)
        updateTitleBar()

        applyWindowBackgroundStyle()
        positionStandardWindowButtons()

        // Land in the restored chrome layout (sidebar collapse + active pane).
        // Deferred so hosts are mounted before First Mate / files / changes open.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyChromeState(animated: false)
            if !self.chromeState.isCollapsed,
               self.chromeState.activePane == .firstMate || self.chromeState.activePane == nil {
                self.dashboardVC?.activateInitialSplit()
            }
        }
    }

    /// The "+" on a fleet project header: an anchored create form for that project.
    /// Same landing as the helm's `/worktree` — create, staff, enter the worktree.
    private func presentAddWorktreePopover(project: String, rect: NSRect, anchor: NSView) {
        guard let repoPath = tabCoordinator.repoPath(forProject: project) else { NSSound.beep(); return }
        let popover = NSPopover()
        let creator = AddWorktreePopoverController(project: project)
        // No base picker: worktrees always branch off the repo's main line, which
        // is what `performWorktreeCreate` picks when no base is passed.
        creator.onCreate = { [weak self, weak popover, weak creator] task, agentType in
            self?.performWorktreeCreate(
                task: task, repoPath: repoPath, agentType: agentType, reuseEnv: false,
                onError: { message in creator?.reportFailure(message) }
            ) { path in
                guard let path else { return }
                popover?.performClose(nil)
                self?.dashboardVC?.commitWorktreeSelection(path: path)
            }
        }
        popover.contentViewController = creator
        popover.behavior = .transient
        popover.delegate = self
        dashboardVC?.setFleetRenderPaused(true)
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
    }

    /// Creates a worktree off the main thread. `onComplete` fires on the main
    /// thread with the new worktree's path on success, or nil on failure —
    /// lets the caller (e.g. the Helm cockpit) drop its loading state and
    /// dismiss once the new tab is ready.
    private func performWorktreeCreate(task: String, repoPath: String, agentType: AgentType, reuseEnv: Bool,
                                       onError: ((String) -> Void)? = nil,
                                       onComplete: ((String?) -> Void)? = nil) {
        let currentPath = tabCoordinator.selectedPane?.worktreePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let branches = WorktreeCreator.listBranches(repoPath: repoPath)
            let base = branches.contains("main") ? "main" : (branches.contains("master") ? "master" : (branches.first ?? "main"))
            do {
                let branchName = WorktreeCreator.branchName(fromTaskDescription: task, existingBranches: branches)
                let info = try WorktreeCreator.createWorktree(repoPath: repoPath, branchName: branchName, baseBranch: base)
                WorktreeAgentTypeStore.shared.set(agentType, forWorktree: info.path)
                WorktreeTaskStore.shared.set(task, forWorktree: info.path)
                if reuseEnv, let currentPath { WorktreeCreator.copyEnvironmentFiles(from: currentPath, to: info.path) }
                if let agentCommandLine = agentType.launchCommand(withTask: task) {
                    let paneSessionKey = SessionManager.persistentSessionName(for: info.path)
                    let backend = self.runtimeBackend
                    // `zmx run` blocks until the (long-lived) agent exits, so spawn the
                    // session on a detached thread and wait only until it exists —
                    // otherwise handleNewBranch + onComplete below would never run and
                    // the cockpit would spin forever.
                    DispatchQueue.global(qos: .userInitiated).async {
                        SessionManager.createDetachedSession(
                            name: paneSessionKey, backend: backend,
                            cwd: info.path, agentCommandLine: agentCommandLine
                        )
                    }
                    _ = SessionManager.waitUntilSessionExists(
                        name: paneSessionKey, backend: backend, timeoutSeconds: 5.0)
                }
                DispatchQueue.main.async {
                    self.tabCoordinator.handleNewBranch(info: info, repoPath: repoPath)
                    onComplete?(info.path)
                }
            } catch {
                DispatchQueue.main.async {
                    NSSound.beep()
                    onError?(error.localizedDescription)
                    onComplete?(nil)
                }
            }
        }
    }

    /// What `/task` lists and `/task #x` / `/return @branch` resolve against —
    /// every worktree, not just the staffed ones, so an idle tree is still
    /// reachable and still sweepable. Both surfaces read this, which is what
    /// keeps their numbering identical.
    /// Autocomplete data for the Helm command line.
    /// `/` commands · `@` repos and worktrees · `#` pane handles.
    private func helmMenuItems(trigger: Character, query: String) -> [(name: String, desc: String)] {
        let index = fleetIndex()
        let pool: [(name: String, desc: String)]
        switch trigger {
        case "/":
            pool = CommandSpecs.menu
        case "@":
            let repos = index.repos.map { ($0.name, "repo · \($0.path)") }
            let worktrees = index.worktrees.map { wt in
                (String(index.label(for: wt).dropFirst()), "worktree · \(wt.repo)")
            }
            pool = repos + worktrees
        case "#":
            // Stable handles — the same numbers the pane rows and `/status` show.
            pool = index.panes.sorted { $0.handle < $1.handle }.map { pane in
                ("\(pane.handle)", "\(pane.status.icon) \(pane.project)/\(pane.branch) · \(pane.title)")
            }
        default:
            pool = []
        }
        guard !query.isEmpty else { return pool }
        return pool.filter { $0.name.lowercased().contains(query) }
    }

    /// One `/integrate` round for the current repo.
    ///
    /// Snapshotting and merging shell out several times over, so it runs off
    /// the main thread; only the report comes back. Nothing it does before the
    /// final checkout can disturb a worktree, so an interrupted or failed round
    /// simply leaves everything as it was.
    private func runIntegration(mode: IntegrationConflictMode, force: Bool) {
        guard let selected = tabCoordinator.config.selectedWorktreePath,
              let repoPath = WorktreeDiscovery.findRepoRoot(from: selected) else {
            NSSound.beep()
            return
        }
        runIntegration(repoPath: repoPath, mode: mode, force: force)
    }

    private func runIntegration(repoPath: String, mode: IntegrationConflictMode, force: Bool) {
        let integrationPath = IntegrationWorktreeStore.shared.worktreePath(forRepo: repoPath)
            ?? IntegrationWorktree.defaultPath(forRepo: repoPath)
        guard config.integrationEnabled else {
            enqueueIntegrationReport(
                "Integration is turned off in Settings ▸ General ▸ Integration",
                repoPath: repoPath,
                checkoutPath: integrationPath
            )
            return
        }
        let worktrees = tabCoordinator.allWorktrees
            .map(\.info)
            .filter { WorktreeDiscovery.findRepoRoot(from: $0.path) == repoPath }
        let lastPublished = IntegrationWorktreeStore.shared.lastPublishedCommit(forCheckout: integrationPath)

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<IntegrationRunReport, Error>
            do {
                outcome = .success(try IntegrationRunner.run(
                    repoPath: repoPath,
                    integrationPath: integrationPath,
                    worktrees: worktrees,
                    mode: mode,
                    force: force,
                    lastPublished: lastPublished,
                    isBusy: { AgentRegistry.shared.hasRunningPane(inWorktree: $0) }
                ))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                switch outcome {
                case .success(let report):
                    // Record only once the round got far enough to have a
                    // checkout, so a failed first run does not leave the store
                    // pointing at a directory that was never created.
                    IntegrationWorktreeStore.shared.set(report.integrationWorktreePath, forRepo: repoPath)
                    IntegrationStatusStore.shared.set(report.panelState, forWorktree: report.integrationWorktreePath)
                    if case .published(let commit) = report.outcome {
                        IntegrationWorktreeStore.shared.recordPublished(
                            commit, forCheckout: report.integrationWorktreePath)
                    }
                    // A round that published cleanly is meant to be invisible —
                    // the integration worktree is simply current. Only speak up
                    // when something was dropped or held back.
                    if report.needsAttention {
                        self?.enqueueIntegrationReport(
                            report.summary,
                            repoPath: repoPath,
                            checkoutPath: report.integrationWorktreePath,
                            options: report.cardOptions
                        )
                    }
                case .failure(let error):
                    // Recorded as well as reported. A round that threw wrote
                    // nothing here, so First Mate went on showing the last good
                    // round and read as an integration that was still current.
                    IntegrationStatusStore.shared.set(
                        .failed(error.localizedDescription), forWorktree: integrationPath)
                    self?.enqueueIntegrationReport(
                        "Integration failed: \(error.localizedDescription)",
                        repoPath: repoPath,
                        checkoutPath: integrationPath
                    )
                }
            }
        }
    }

    /// The row's "Reset to origin/main": fetch trunk and move the integration
    /// checkout onto it, dropping whatever rounds had folded in. Same rules
    /// as a round's publish — edits or commits made in the checkout by hand
    /// hold it, and the sheet that follows names them; a confirmed reset
    /// comes back through here with `force`.
    private func resetIntegration(checkoutPath: String, force: Bool) {
        guard let repoPath = IntegrationWorktreeStore.shared.repoPath(forCheckout: checkoutPath)
            ?? WorktreeDiscovery.findRepoRoot(from: checkoutPath) else {
            NSSound.beep()
            return
        }
        let expectedHead = IntegrationWorktreeStore.shared.lastPublishedCommit(forCheckout: checkoutPath)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The fetch is the slow part; the forced retry has just done one.
            guard let target = IntegrationWorktree.resetTarget(repoPath: repoPath, fetch: !force) else {
                DispatchQueue.main.async {
                    self?.presentIntegrationResetFailure("Could not find origin/main or origin/master to reset to.")
                }
                return
            }
            let outcome = IntegrationWorktree.reset(
                to: target, at: checkoutPath, force: force, expectedHead: expectedHead)
            DispatchQueue.main.async {
                self?.handleIntegrationReset(outcome, target: target, checkoutPath: checkoutPath)
            }
        }
    }

    private func handleIntegrationReset(
        _ outcome: IntegrationPublishOutcome,
        target: IntegrationWorktree.ResetTarget,
        checkoutPath: String
    ) {
        switch outcome {
        case .published(let commit), .unchanged(let commit):
            // The reset commit is seahelm's own, so the next round does not
            // mistake it for work that arrived by hand.
            IntegrationWorktreeStore.shared.recordPublished(commit, forCheckout: checkoutPath)
            IntegrationStatusStore.shared.set(
                IntegrationPanelState(
                    line: "integration · reset to \(target.ref)",
                    included: [], excluded: [], conflictedPaths: [], isHeld: false
                ),
                forWorktree: checkoutPath
            )
            // A held-round card was about the state that was just discarded.
            tabCoordinator.pendingOrders.resolveWorktree(path: checkoutPath)
        case .held(let reason, _):
            guard let window else { return }
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Reset integration to \(target.ref)?"
            alert.informativeText = reason.lossDescription
            alert.addButton(withTitle: "Reset")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.resetIntegration(checkoutPath: checkoutPath, force: true)
            }
        case .failed(let message):
            presentIntegrationResetFailure(message)
        }
    }

    private func presentIntegrationResetFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Failed to reset integration worktree"
        alert.informativeText = message
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// One card per checkout, keyed by the checkout rather than the repo so the
    /// manual path and the automatic one address the same card instead of
    /// stacking two. `upsert` because a later round supersedes an earlier one —
    /// `enqueue` would leave the card reading whatever the first round said.
    private func enqueueIntegrationReport(
        _ message: String,
        repoPath: String,
        checkoutPath: String,
        options: [String]? = nil
    ) {
        tabCoordinator.pendingOrders.upsert(
            FirstMateAction(
                kind: .integrationReport,
                zone: .red,
                worktreePath: checkoutPath,
                branch: "",
                project: tabCoordinator.repoName(forWorktree: repoPath),
                terminalID: "",
                message: message,
                payload: repoPath,
                options: options
            )
        )
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
    /// completes — `.navigated` for a new worktree, `.presented` for return
    /// cards, `.failed` on error. Synchronous commands run immediately and
    /// return `false`.
    @discardableResult
    func submitBridgeCommand(_ text: String, onOutcome: ((HelmCommandOutcome) -> Void)? = nil) -> Bool {
        enum Kind { case new, sweep, other }
        var kind = Kind.other
        if case .success(let line) = CommandParser.parse(text, index: fleetIndex()) {
            switch line.command {
            case .new: kind = .new
            case .returnAll: kind = .sweep
            default: break
            }
        }
        var replies = 0
        commandExecutor.run(text, surface: .desktop) { [weak self] reply in
            guard let self else { return }
            replies += 1
            // The dashboard is the desktop's listing; text replies are for the
            // surfaces that have nothing else to show.
            if reply.showsOverview { self.tabCoordinator.switchToTab(0) }
            if reply.isError { NSSound.beep() }
            if !reply.text.isEmpty { NSLog("[Helm] \(reply.text)") }
            if reply.presentsOnDesktop { self.presentCommandReply(reply) }
            switch kind {
            case .new:
                if reply.isError { onOutcome?(.failed) } else if replies >= 2 { onOutcome?(.navigated) }
            case .sweep:
                onOutcome?(reply.isError ? .failed : .presented)
            case .other:
                if reply.isError { onOutcome?(.failed) }
            }
        }
        return kind != .other
    }

    /// The desktop has no chat to read replies in; an outcome that carries
    /// something to act on — a PR link, a worktree held back — gets a sheet.
    private func presentCommandReply(_ reply: CommandReply) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = reply.isError ? .warning : .informational
        alert.messageText = reply.isError ? "Return did not finish" : "Return"
        alert.informativeText = reply.text
        let prLink = reply.text.split(whereSeparator: \.isWhitespace).map(String.init)
            .first { $0.hasPrefix("https://github.com/") && $0.contains("/pull/") }
        if prLink != nil { alert.addButton(withTitle: "Open PR") }
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { response in
            guard let prLink, response == .alertFirstButtonReturn, let url = URL(string: prLink) else { return }
            NSWorkspace.shared.open(url)
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
                collapsed: config.sidebarCollapsed,
                activePane: ChromeLeftPane(rawValue: config.sidebarActivePane) ?? .firstMate
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
        let collapseChanged = state.isCollapsed != chromeState.isCollapsed
        let paneChanged = state.activePane != chromeState.activePane
        chromeState = state
        persistChromeLayout()
        positionStandardWindowButtons()
        if collapseChanged || paneChanged {
            dashboardVC?.adoptChromeCollapse(state.isCollapsed, activePane: state.activePane)
            if collapseChanged {
                }
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
        // Panes load / auto-select land here — keep Files/Changes enablement in sync.
        refreshChromeWorktreeContextEnabled()
        refreshRegionAvailability()
    }

    /// Worktrees with no agent interaction for longer than this are treated as
    /// idle for the card-grid expander (overview navigator does not collapse them).
    private static let tabIdleCollapseInterval: TimeInterval = 8 * 3600

    private func refreshIdleWorktreePaths() {
        let selectedPath = tabCoordinator.selectedPane?.worktreePath
        let now = Date()
        var idle: Set<String> = []
        for entry in tabCoordinator.allWorktrees {
            let path = entry.info.path
            let isSelected = path == selectedPath
            let agent = AgentRegistry.shared.pane(forWorktree: path)
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

    /// Click→title fast path: the clicked pane's live OSC title goes straight to
    /// the chrome header, synchronously with the focus click. The resolver path
    /// below still runs afterwards (via the focus delegate) and repaints with the
    /// full fallback chain, but it reads AgentRegistry snapshots that trail the 2s
    /// poll — without this the title visibly lagged rapid pane switching.
    @objc private func handlePaneDidAcquireFocus(_ note: Notification) {
        guard let station = note.object as? Station else { return }
        let path = tabCoordinator.selectedPane?.worktreePath ?? ""
        // Prefer the live OSC title; on a fresh launch it hasn't arrived yet, so
        // fall back to the pane's persisted (last-known) title instead of leaving
        // the header stale.
        let persisted = station.persistedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = PaneTitleResolver.displayOscTitle(station.oscTitle, worktreePath: path,
                                                      pwd: station.pwd)
            ?? (persisted?.isEmpty == false ? persisted : nil)
        guard let title else { return }
        windowChrome?.updateTerminalTitle(repo: "", pane: title)
    }

    /// Drive the terminal chrome header: `Repo · pane title`.
    private func updateChromeTitle() {
        guard let agent = tabCoordinator.selectedPane else {
            windowChrome?.updateTerminalTitle(repo: "", pane: "")
            return
        }
        let path = agent.worktreePath
        let info = AgentRegistry.shared.pane(forWorktree: path)
        let repo = (info?.project).flatMap { $0.isEmpty ? nil : $0 }
            ?? tabCoordinator.repoName(forWorktree: path)

        let paneTitle: String
        let worktreePanes = AgentRegistry.shared.panes(forWorktree: path)
        if let info, !worktreePanes.isEmpty {
            // Current (focused) pane, or the most-recently-active pane otherwise.
            let tree = terminalCoordinator.stationManager.tree(forPath: path)
            let focusedPane = PaneTitleResolver.representativePane(
                focusedStationId: PaneTitleResolver.focusedStationId(in: tree),
                among: worktreePanes,
                fallback: info
            )
            paneTitle = PaneTitleResolver.title(for: focusedPane)
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
        windowChrome?.updateWorktreeContext(Self.worktreeContext(repo: repo, pane: agent))
        refreshHeaderMemory(sessionKey: focusedPaneSessionKey(worktreePath: path))
    }

    // MARK: - Header memory readout

    private static let headerMemoryTTL: TimeInterval = 5
    private let headerMemoryQueue = DispatchQueue(label: "seahelm.header-memory", qos: .utility)
    private var headerMemoryCache: [String: UInt64] = [:]
    private var headerMemoryProbedAt: [String: Date] = [:]
    private var headerMemoryInFlight: Set<String> = []

    private func focusedPaneSessionKey(worktreePath: String) -> String? {
        let tree = terminalCoordinator.stationManager.tree(forPath: worktreePath)
        guard let stationId = PaneTitleResolver.focusedStationId(in: tree) else { return nil }
        return StationRegistry.shared.station(forId: stationId)?.paneSessionKey
    }

    /// Paint the cached figure at once, then re-probe at most every
    /// `headerMemoryTTL` seconds. The probe forks `zmx list` and `ps`, so it runs
    /// off the main thread and is rate-limited — this is called on every title
    /// refresh, which includes the 5s chrome tick and every focus change.
    private func refreshHeaderMemory(sessionKey: String?) {
        guard let sessionKey, !sessionKey.isEmpty else {
            windowChrome?.updateTerminalMemory(nil)
            return
        }
        windowChrome?.updateTerminalMemory(headerMemoryCache[sessionKey])

        let last = headerMemoryProbedAt[sessionKey] ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.headerMemoryTTL,
              !headerMemoryInFlight.contains(sessionKey) else { return }
        headerMemoryInFlight.insert(sessionKey)
        headerMemoryProbedAt[sessionKey] = Date()

        headerMemoryQueue.async { [weak self] in
            let bytes = ProcessRunner.output([ZmxLocator.executable(), "list"]).flatMap {
                ProcessProbe.sessionResidentBytes(paneSessionKey: sessionKey, zmxListOutput: $0)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.headerMemoryInFlight.remove(sessionKey)
                guard let bytes else { return }
                self.headerMemoryCache[sessionKey] = bytes
                // Focus may have moved while the probe ran; painting then would
                // label the new pane with the old pane's number.
                guard let agent = self.tabCoordinator.selectedPane,
                      self.focusedPaneSessionKey(worktreePath: agent.worktreePath) == sessionKey
                else { return }
                self.windowChrome?.updateTerminalMemory(bytes)
            }
        }
    }

    /// `repo · branch`, skipping either half when it is missing or would repeat the
    /// other — the fleet row builds its branch label the same way.
    static func worktreeContext(repo: String, pane: WorktreeRowInfo) -> String {
        let branch = pane.thread.isEmpty ? pane.name : pane.thread
        let parts = [repo, branch]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(NSOrderedSet(array: parts)).compactMap { $0 as? String }.joined(separator: " · ")
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
        // In edit mode the terminal split is presented as tabs, so spatial focus
        // movement becomes tab cycling: horizontal walks the terminal tabs, and
        // vertical walks the preview tabs on the right.
        if let dashboard = tabCoordinator.dashboardVC, dashboard.isEditModeActive {
            if axis == .horizontal {
                dashboard.editModeCycleTerminalTab(forward: positive)
            } else {
                dashboard.editModeCyclePreviewTab(forward: positive)
            }
            return
        }
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
        // Cycle in the order the fleet list is actually showing, so ⌃⇥ agrees with
        // the eye under every `WorktreeGroupingMode`. Discovery order is the fallback
        // for before the overview has rendered.
        let displayed = tabCoordinator.dashboardVC?.cruiseOrderPaths ?? []
        let paths = displayed.isEmpty ? tabCoordinator.allWorktrees.map(\.info.path) : displayed
        let current = tabCoordinator.selectedPane?.worktreePath
        guard let path = WorktreePathNavigation.adjacentPath(
            paths: paths, from: current, forward: forward
        ) else { return }
        tabCoordinator.cycleTab(toWorktree: path)
    }

}

// MARK: - NSPopoverDelegate

extension MainWindowController: NSPopoverDelegate {
    /// The create form is gone — let the fleet repaint with whatever landed while
    /// it was held.
    func popoverDidClose(_ notification: Notification) {
        dashboardVC?.setFleetRenderPaused(false)
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

    func windowDidChangeScreen(_ notification: Notification) {
        // Dragging between displays with different backing scales. The
        // view-level viewDidChangeBackingProperties handles visible panes,
        // but panes not yet in the hierarchy may miss it — resync all.
        for station in StationRegistry.shared.allStations() {
            station.syncContentScale()
            station.syncSize()
        }
    }

    func windowDidChangeEffectiveAppearance(_ notification: Notification) {
        applyWindowBackgroundStyle()
    }


    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return QuitConfirmation.shouldQuit(for: sender)
    }

    func windowWillClose(_ notification: Notification) {
        closeAuxiliaryWindows()
        usageSummaryStore.stop()
        statusPublisher.stop()
        tabCoordinator.branchRefreshTimer?.invalidate()
        tabCoordinator.branchRefreshTimer = nil
        tabCoordinator.teardownRemoteBackends()
        terminalCoordinator.cleanup()
    }

    /// Settings and pairing are separate windows, so they keep the app alive past
    /// the main window's close — `applicationShouldTerminateAfterLastWindowClosed`
    /// only fires on the *last* one. Leaving them up strands a config editor over
    /// an app whose coordinators this very method is about to tear down.
    private func closeAuxiliaryWindows() {
        settingsWindowController?.close()
        settingsWindowController = nil
        pairingWindowController?.close()
        pairingWindowController = nil
    }

    func startGmailMailChannel(config gmailConfig: GmailMailConfig?) {
        gmailMailPoller?.stop()
        gmailMailPoller = nil
        // Mail runs its lines through the same executor as the Helm line and
        // Telegram; wired here, once both coordinators exist.
        tabCoordinator.commandRoute = { [weak self] text, surface, reply in
            self?.commandExecutor.run(text, surface: surface, reply: reply)
        }
        guard let gmailConfig, gmailConfig.enabled, gmailConfig.validationError == nil else { return }
        let poller = GmailMailPoller(client: GmailRESTMailClient(accountEmail: gmailConfig.accountEmail))
        poller.onAcceptedMessage = { [weak self] message in
            DispatchQueue.main.async { self?.tabCoordinator.routeMail(message: message) }
        }
        poller.onStateChange = { code in NSLog("[App] Gmail mail channel state: \(code.rawValue)") }
        poller.start(config: gmailConfig)
        gmailMailPoller = poller
    }

    func cleanupBeforeTermination() {
        gmailMailPoller?.stop()
        gmailMailPoller = nil
        usageSummaryStore.stop()
        statusPublisher.stop()
        tabCoordinator.branchRefreshTimer?.invalidate()
        tabCoordinator.branchRefreshTimer = nil
        // Flush a debounced First Mate preview so the saved selection matches
        // the highlighted row, then persist selection + chrome layout.
        dashboardVC?.flushPendingPreviewForPersistence()
        tabCoordinator.saveSelectedWorktree()
        config.selectedWorktreePath = tabCoordinator.config.selectedWorktreePath
        config.sidebarCollapsed = chromeState.isCollapsed
        config.sidebarWidth = chromeState.width
        if let pane = chromeState.activePane {
            config.sidebarActivePane = pane.rawValue
        }
        // Capture the latest per-pane titles before tearing down the stations,
        // so restored panes show their real titles instead of the branch name.
        terminalCoordinator.saveAllSplitLayouts()
        saveConfig()
        // Debounced Config.save may not flush before process exit — force it.
        config.saveNow()
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

    func chromeDidToggleEditMode() {
        tabCoordinator.dashboardVC?.toggleEditMode()
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
            showWorktreeCleanupAlert(title: "No worktrees to clean", message: "There are no linked worktrees in the current project list.")
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

    func dashboardDidRequestDeleteWorktree(path: String) {
        tabCoordinator.dashboardDidRequestDeleteWorktree(path: path, window: window)
    }

    /// The row's Return is the command itself, so the sidebar and every chat
    /// surface stay one behavior.
    func dashboardDidRequestReturnWorktree(path: String) {
        let index = fleetIndex()
        guard let wt = index.worktree(path: path) else {
            NSSound.beep()
            return
        }
        pendingReturnPath = wt.path
        dashboardVC?.setWorktreePending(path: wt.path, pending: true)
        submitBridgeCommand("/return \(index.label(for: wt))") { [weak self] outcome in
            if case .failed = outcome { self?.clearPendingReturn() }
        }
    }

    private func clearPendingReturn() {
        guard let path = pendingReturnPath else { return }
        pendingReturnPath = nil
        dashboardVC?.setWorktreePending(path: path, pending: false)
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
        // Paint from cached state immediately, then force a poll so a pane whose
        // title changed since the last cycle refreshes on click rather than in ~2s.
        updateChromeTitle()
        statusPublisher.refreshNow()
    }

    func splitContainer(_ view: SplitContainerView, didRequestSplit axis: SplitAxis) {
        splitFocusedPane(axis: axis)
    }

    func splitContainer(_ view: SplitContainerView, didRequestClosePane leafId: String) {
        closeFocusedPane()
    }

    func splitContainer(_ view: SplitContainerView, didRequestSleepPane leafId: String) {
        guard let stationId = view.tree?.root.findLeaf(id: leafId)?.stationId else { return }
        _ = terminalCoordinator.sleepPane(targetStationId: stationId)
    }

    func splitContainer(_ view: SplitContainerView, didRequestWakePane leafId: String) {
        guard let stationId = view.tree?.root.findLeaf(id: leafId)?.stationId else { return }
        _ = terminalCoordinator.wakePane(targetStationId: stationId)
    }

    func splitContainer(_ view: SplitContainerView, didRequestPreview url: URL) {
        dashboardVC?.openFile(path: url.path)
    }

    func splitContainer(_ view: SplitContainerView, didRequestPRPreview owner: String, repo: String, number: Int) {
        guard let dashboardVC else { return }
        let token = resolvedGitHubToken
        if token.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "GitHub Token Required"
            alert.informativeText = "No GitHub token found. Options:\n\n"
                + "1. Add to project .env file:\n   GITHUB_TOKEN=ghp_xxx\n\n"
                + "2. Set local git config:\n   cd <repo> && git config github.token ghp_xxx\n\n"
                + "3. Install gh CLI and login:\n   brew install gh && gh auth login\n\n"
                + "4. Store in system keychain:\n   git credential-store store <<EOF\n   protocol=https\n   host=github.com\n   username=token\n   password=ghp_xxx\n   EOF\n\n"
                + "5. Set environment variable:\n   export GITHUB_TOKEN=ghp_xxx"
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let service = GitHubPRService(token: token, owner: owner, repo: repo)
        let coordinator = PRReviewCoordinator(service: service, dashboard: dashboardVC)
        coordinator.show()
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

    func paneStatusDidChange(worktreePath: String, paneIndex: Int, oldStatus: AgentStatus, newStatus: AgentStatus, lastMessage: String) {
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
        model.onRevealSuggestion = { [weak self] order in
            self?.revealSuggestionPane(order)
        }
        model.onDismissOrder = { [weak self] order in
            self?.tabCoordinator.pendingOrders.resolve(id: order.id)
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
        // tabCoordinatorRequestUpdateTitleBar. The timer is only a slow
        // fallback for async stragglers (e.g. title resolution finishing
        // later). Notification history no longer feeds the island.
        islandRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refreshIsland()
        }
        refreshIsland()
    }

    /// Jump to the pane that raised `order` without resolving the suggestion.
    /// Used when the user taps blank area on an Island suggestion card.
    private func revealSuggestionPane(_ order: PendingOrder) {
        let path = order.action.worktreePath
        tabCoordinator.handleNavigateToWorktree(worktreePath: path, paneIndex: nil)
        let terminalID = order.action.terminalID
        // Embed/layout of the split container is deferred; focus after it lands.
        if !terminalID.isEmpty {
            DispatchQueue.main.async { [weak self] in
                _ = self?.terminalCoordinator.focusPane(targetStationId: terminalID)
            }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Surface new suggestions in the First Mate sidebar while Seahelm is frontmost
    /// AND the card belongs to the worktree on screen — dropping a panel over the
    /// notch you are already looking at reads as a glitch, and the sidebar is where
    /// that card lives anyway. A card from any other worktree goes to the island
    /// instead (`openForEvent(targetVisible:)`), which is the only surface that can
    /// show it without navigating the window out from under the user.
    /// Registered independently of the island so it still works with it disabled.
    private func setupSuggestionReveal() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        tabCoordinator.pendingOrders.addObserver { [weak self] in
            self?.revealFirstMateForNewSuggestions()
        }
        revealFirstMateForNewSuggestions()
    }

    private func revealFirstMateForNewSuggestions() {
        let suggestions = tabCoordinator.pendingOrders.all()
            .filter { $0.action.kind == .suggestNextOrder }
        let fresh = revealedSuggestions.absorb(suggestions)
        // Only while frontmost: in the background the island already pops, and
        // re-opening the sidebar on a suggestion the user never saw arrive would
        // rearrange the window behind their back. And only for a card this
        // sidebar can actually show — a suggestion from another worktree is the
        // island's job, so revealing the current worktree's First Mate tab for
        // it would rearrange the window and still not show the card.
        guard NSApp.isActive else { return }
        guard fresh.contains(where: { tabCoordinator.isWorktreeVisible($0.action.worktreePath) }) else { return }
        guard chromeState.isCollapsed || chromeState.activePane != .firstMate else { return }
        // Layout only — first responder stays in the terminal so the reveal never
        // eats a keystroke mid-sentence.
        chromeState.setActivePane(.firstMate)
        applyChromeState(animated: true)
    }

    /// Non-nil only for the states the app cannot resolve by itself —
    /// `ControlSocketServer` silently reclaims a vanished or stale socket path
    /// on its own, and telling the user to restart for something already being
    /// fixed would train them to ignore this.
    fileprivate func controlChannelWarning() -> String? {
        guard let server = tabCoordinator.terminalCoordinator?.controlSocketServer else {
            return nil  // never started (e.g. the screenshot instance stands down)
        }
        switch server.state {
        case .listening:
            return nil
        case .standby:
            return "Another Seahelm instance owns the control channel. Agent hooks and the seahelm CLI are inactive in this window — quit the other instance to take it back."
        case .stopped:
            return "The control channel could not start. Agent hooks and the seahelm CLI are unavailable — restarting Seahelm usually clears it."
        }
    }

    fileprivate func refreshIsland() {
        guard config.islandEnabled else { return }
        let model = islandController.model

        // Aggregate per-worktree: the highest-urgency pane wins the row.
        // The island only shows worktrees with activity in the last 24 hours —
        // it is a "what's happening now" surface, not the full fleet list.
        let activityCutoff = Date().addingTimeInterval(-24 * 60 * 60)
        var byWorktree: [String: IslandAgentRow] = [:]
        for pane in AgentRegistry.shared.allPanes() {
            let lastActivity = statusAggregator.lastActivity(for: pane.worktreePath) ?? pane.startedAt
            guard let lastActivity, lastActivity >= activityCutoff else { continue }
            // Same resolver as the dashboard cards, but via the shared TTL
            // cache — a direct resolve() reads session JSONL from disk, and
            // this runs on main for every pane on every island refresh.
            // Warm the cache off-main; the next tick picks up the result.
            WorktreeTitleCache.shared.title(
                worktreePath: pane.worktreePath,
                lastUserPrompt: pane.lastUserPrompt,
                branch: pane.branch
            ) { _ in }
            let cachedTitle = WorktreeTitleCache.shared.cachedTitle(worktreePath: pane.worktreePath)
            let row = IslandAgentRow(
                id: pane.worktreePath,
                project: pane.project,
                branch: pane.branch,
                status: pane.status,
                message: pane.lastAssistantMessage.isEmpty ? pane.lastMessage : pane.lastAssistantMessage,
                // The island row already renders the branch separately — drop a
                // title that is just the branch fallback.
                title: (cachedTitle == pane.branch ? "" : cachedTitle) ?? pane.lastUserPrompt
            )
            if let existing = byWorktree[pane.worktreePath] {
                if Self.notificationPriorityScoreForIsland(row.status) > Self.notificationPriorityScoreForIsland(existing.status) {
                    byWorktree[pane.worktreePath] = row
                }
            } else {
                byWorktree[pane.worktreePath] = row
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
        let orders = IslandModel.newestSuggestions(from: tabCoordinator.pendingOrders.all())
        if model.orders != orders { model.orders = orders }

        // A dead control channel is invisible everywhere else: the hooks fail
        // their `[ -S ]` guard and drop events without a word, so the island
        // just goes quiet — indistinguishable from a fleet with nothing to say.
        let channelWarning = controlChannelWarning()
        if model.controlChannelWarning != channelWarning {
            model.controlChannelWarning = channelWarning
        }

        // A new suggestion is actionable — expand so the card is visible
        // without hovering. Nothing else opens the island: status changes are
        // Notification Center's job. Frontmost, this yields to the First Mate
        // sidebar only for a card that sidebar is actually showing — a
        // suggestion raised in a worktree that isn't on screen pops here.
        publishCardsToChat(tabCoordinator.pendingOrders.all())

        let fresh = islandSeenSuggestions.absorb(orders)
        if IslandModel.shouldOpen(for: fresh), !model.isOpened {
            let targetVisible = fresh.allSatisfy {
                tabCoordinator.isWorktreeVisible($0.action.worktreePath)
            }
            islandController.openForEvent(targetVisible: targetVisible)
        }
        islandController.updateVisibility()
    }

    private static func notificationPriorityScoreForIsland(_ status: AgentStatus) -> Int {
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
    func settings(_ settings: SettingsViewController, connectGmailAccount email: String) {
        let coordinator = GmailOAuthCoordinator()
        gmailOAuthCoordinator = coordinator
        coordinator.connect(accountEmail: email) { [weak self] result in
            guard let self else { return }
            self.gmailOAuthCoordinator = nil
            switch result {
            case .success:
                settings.setGmailConnectionStatus("Connected. Gmail credentials are stored in Keychain.")
                if self.config.gmailMail == nil {
                    self.config.gmailMail = GmailMailConfig(accountEmail: email,
                                                            inboundAlias: GmailMailConfig(accountEmail: email).derivedInboundAlias)
                    self.saveConfig()
                }
            case .failure(let error):
                NSLog("[Gmail] OAuth failed: %@", error.localizedDescription)
                settings.setGmailConnectionStatus("Connection failed: \(error.localizedDescription)")
            }
        }
    }
    func settingsPairingContext(_ settings: SettingsViewController) -> (secret: Data, mqtt: PairingIdentity)? {
        mintPairingContext()
    }

    func settingsPairingCode(_ settings: SettingsViewController) -> String {
        currentPairingCode()
    }

    func settingsRefreshPairingCode(_ settings: SettingsViewController) -> String {
        refreshPairingCode()
    }

    func settingsRevokeAllRemotes(_ settings: SettingsViewController) {
        revokeAllRemotes()
    }

    func settingsHostGatewayListening(_ settings: SettingsViewController) -> Bool {
        tabCoordinator.hostGatewayIsListening
    }

    /// Ensure an 8-digit code exists on the live config (and LivePairingCode if Gateway is up).
    @discardableResult
    private func currentPairingCode() -> String {
        if let live = tabCoordinator.pairingCodeLive {
            return live.current()
        }
        var store = PairingCodeStore(code: config.hostGateway?.pairCode)
        let code = store.ensureCode()
        if config.hostGateway == nil { config.hostGateway = HostGatewayConfig() }
        config.hostGateway?.pairCode = code
        config.saveNow()
        return code
    }

    @discardableResult
    private func refreshPairingCode() -> String {
        if let live = tabCoordinator.pairingCodeLive {
            return live.refresh()
        }
        var store = PairingCodeStore(code: config.hostGateway?.pairCode)
        let code = store.refresh()
        if config.hostGateway == nil { config.hostGateway = HostGatewayConfig() }
        config.hostGateway?.pairCode = code
        config.saveNow()
        return code
    }

    /// Rotate root secret and pairing code so every remembered browser must re-pair.
    private func revokeAllRemotes() {
        if config.pairing == nil { config.pairing = PairingIdentity() }
        config.pairing?.rootSecret = PairingCrypto.base64url(PairingCrypto.newRootSecret())
        _ = refreshPairingCode()
        config.saveNow()
        tabCoordinator.applyMqttRootSecret(config.pairing?.rootSecret ?? "")
    }

    /// Live panes, so a rule's target is picked from what exists rather than
    /// recalled from memory.
    func settingsPaneTargets(_ settings: SettingsViewController) -> [PaneSnapshot] {
        tabCoordinator.mqttDataSource?.snapshotPanes() ?? []
    }

    /// Session names the live panes are attached to, so the monitor can mark a
    /// kill that would take an agent down with it.
    func settingsActiveSessionNames(_ settings: SettingsViewController) -> Set<String> {
        activePaneSessionNamesForCleanup()
    }

    /// Session names that currently exist as pane leaves in the live UI trees.
    /// Orphan cleanup treats this set as authoritative.
    func activePaneSessionNamesForCleanup() -> Set<String> {
        tabCoordinator.livePaneSessionNames()
    }

    func settingsDidUpdateConfig(_ settings: SettingsViewController, config: Config) {
        let oldPaths = Set(self.config.workspacePaths)
        let oldTelegram = self.config.telegram
        let oldGmail = self.config.gmailMail
        let oldGateway = self.config.hostGateway ?? HostGatewayConfig()
        // Preserve split layouts — SettingsVC doesn't track them
        var merged = config
        merged.splitLayouts = terminalCoordinator.config.splitLayouts
        self.config = merged
        tabCoordinator.config = merged
        terminalCoordinator.config = merged
        updateCoordinator.config = merged
        dashboardVC?.integrationEnabled = merged.integrationEnabled
        normalizeBackendAvailabilityIfNeeded()

        let newPaths = Set(config.workspacePaths)
        if oldPaths != newPaths {
            tabCoordinator.loadWorkspaces()
        }

        // Host Gateway: restart only on what the listener is actually built from.
        // `public_url` feeds the pair link and nothing else, so typing one must
        // not drop the browser sessions already attached.
        let newGateway = config.hostGateway ?? HostGatewayConfig()
        if oldGateway.resolvedEnabled != newGateway.resolvedEnabled
            || oldGateway.resolvedPort != newGateway.resolvedPort
            || oldGateway.webRoot != newGateway.webRoot {
            tabCoordinator.reloadHostGateway()
        }

        // Hot-reload the mail channel too. The poller captures its config when
        // it starts, so without this an edited sender whitelist (or account, or
        // alias) sat in config.json doing nothing until the next launch, while
        // inbound mail was rejected against the values from startup.
        if oldGmail != config.gmailMail {
            startGmailMailChannel(config: config.gmailMail)
        }

        // Hot-reload the Telegram bridge on config change. Not while the setup
        // wizard is pairing: that bridge is holding the bot's single poll slot,
        // and its own teardown brings the configured one back.
        if oldTelegram != config.telegram, telegramPairingChannel == nil {
            restartTelegramBridge()
        }
    }

    /// Tear the Telegram bridge down and stand it back up from `config`.
    ///
    /// `disconnect()` rather than a bare release: the old poller is parked in a
    /// `getUpdates` that Telegram holds open for twenty seconds, and a
    /// successor that starts while it is still in flight is the 409 the error
    /// text blames on "a second seahelm running".
    private func restartTelegramBridge() {
        AgentRegistry.shared.unregisterChannel(telegramChannel?.channelId ?? "telegram")
        telegramChannel?.disconnect()
        telegramChannel = nil
        // A fresh save deserves a fresh alert, even for the same mistake.
        lastTelegramError = nil

        guard let telegramConfig = config.telegram, telegramConfig.resolvedAutoConnect else { return }
        let channel = TelegramChannel(config: telegramConfig)
        channel.onStateChange = { [weak self] state in
            // A rejected token or a bot polled elsewhere is something only the
            // user can fix, so a failure has to be said out loud — otherwise
            // the channel is just silently dead.
            if case .error(let msg) = state { self?.presentTelegramError(msg) }
        }
        AgentRegistry.shared.registerChannel(channel)
        channel.connect()
        telegramChannel = channel
        NSLog("[Settings] Telegram bridge reconnecting")
    }

    func settings(_ settings: SettingsViewController,
                  beginTelegramPairing token: String,
                  session: TelegramPairingSession,
                  onPaired: @escaping (TelegramPairingResult) -> Void) {
        // One poller per bot. Whatever is live has to go first, or Telegram
        // answers 409 and the QR on screen never resolves.
        AgentRegistry.shared.unregisterChannel(telegramChannel?.channelId ?? "telegram")
        telegramChannel?.disconnect()
        telegramChannel = nil
        telegramPairingChannel?.disconnect()

        // The token is not in the saved config yet — the wizard writes it only
        // when it finishes — so this bridge runs on a config that lives exactly
        // as long as the pairing. Empty allowlist and no rules on purpose:
        // until someone claims the code this bot obeys nobody, and a stray
        // message must not trip a trigger. A zero backfill keeps a stale
        // `/start` from before the wizard opened out of the pairing.
        var pairingConfig = config.telegram ?? TelegramConfig()
        pairingConfig.botToken = token
        pairingConfig.allowedUsers = []
        pairingConfig.rules = []
        pairingConfig.backfillSeconds = 0

        let channel = TelegramChannel(config: pairingConfig)
        channel.armPairing(session)
        channel.onPaired = onPaired
        channel.onStateChange = { [weak self] state in
            if case .error(let msg) = state { self?.presentTelegramError(msg) }
        }
        // Deliberately not registered with AgentRegistry: this bridge exists to
        // receive one `/start`, and a registered channel could carry orders
        // from a bot nobody has been allowed on yet.
        telegramPairingChannel = channel
        lastTelegramError = nil
        channel.connect()
        NSLog("[Settings] Telegram pairing bridge up")
    }

    func settingsEndTelegramPairing(_ settings: SettingsViewController) {
        guard let channel = telegramPairingChannel else { return }
        channel.armPairing(nil)
        channel.disconnect()
        telegramPairingChannel = nil
        // Back to whatever is saved. On the wizard's success path this is the
        // pre-pairing config and the save that follows immediately restarts the
        // bridge again with the new one; on cancel it is the only restart.
        restartTelegramBridge()
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

// MARK: - NSMenuItemValidation

extension MainWindowController: NSMenuItemValidation {
    /// Sparkle disables "Check for Updates..." while a check is already in flight.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) {
            return updateCoordinator.validateMenuItem(item)
        }
        return true
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
        // Sweep the worktree's cards before the UI drops it: deleting a worktree
        // takes every pane with it, so worktree-scoped cards are stale too.
        tabCoordinator.pendingOrders.resolveWorktree(path: info.path)
        worktreeDidDelete(info)
    }

    func terminalCoordinator(_ coordinator: TerminalCoordinator, didClosePane terminalID: String) {
        tabCoordinator.pendingOrders.resolvePane(terminalID: terminalID)
        // Every conversation bound to the pane is told, and a mail thread's
        // attachments go with it.
        for session in tabCoordinator.commandSessions.close(paneId: terminalID) where session.surface == "mail" {
            if let account = config.gmailMail?.accountEmail {
                EmailAttachmentStore().remove(threadID: session.id, account: account)
            }
        }
    }
}

// MARK: - Bridge Actions

extension MainWindowController {
    /// Routes a suggestion chip tap. `integrationReport` chips run or decline the
    /// discard; all other kinds forward the option text to the agent terminal.
    func handleSuggestionTapped(order: PendingOrder, optionText: String) {
        if order.action.kind == .integrationReport {
            // The card is the only place the discard is offered, and it is the
            // one irreversible step in the feature — so the option that takes
            // it says so, and anything else just clears the card.
            tabCoordinator.pendingOrders.resolve(id: order.id)
            guard IntegrationRunReport.isDiscardOption(optionText) else { return }
            // The repo travels on the card: its worktreePath is the checkout.
            guard let repoPath = order.action.payload
                ?? IntegrationWorktreeStore.shared.repoPath(forCheckout: order.action.worktreePath) else {
                NSSound.beep()
                return
            }
            runIntegration(repoPath: repoPath, mode: .excludeConflicting, force: true)
        } else if order.action.payload == FirstMateAction.screenChoicePayload {
            // Permission prompts discovered from the viewport are not guaranteed
            // to support digit shortcuts (Codex advertises y/p/esc). Drive the
            // visible list relative to its current selected row instead.
            if let idx = order.action.options?.firstIndex(of: optionText) {
                let selectedIndex = StationRegistry.shared.station(forId: order.action.terminalID)
                    .flatMap { $0.readViewportText() }
                    .flatMap { ChoiceOptionParser.parse($0).firstIndex(where: \.selected) } ?? 0
                AgentRegistry.shared.answerChoiceByArrows(
                    to: order.action.terminalID, index: idx, from: selectedIndex)
            }
        } else if order.action.payload == FirstMateAction.askUserQuestionPayload {
            // AskUserQuestion TUI selects by digit; typing the label text would
            // land in the free-form field instead. Send the option's number —
            // sendCommand follows with a Return that confirms the selection.
            // opencode's question TUI has no digit shortcuts (a digit would land
            // in the custom-answer field), so drive it with arrow keys instead.
            if let idx = order.action.options?.firstIndex(of: optionText) {
                if AgentRegistry.shared.pane(for: order.action.terminalID)?.agentType == .openCode {
                    AgentRegistry.shared.answerChoiceByArrows(to: order.action.terminalID, index: idx)
                } else {
                    AgentRegistry.shared.sendCommand(to: order.action.terminalID, command: "\(idx + 1)")
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
            AgentRegistry.shared.sendCommand(to: order.action.terminalID, command: optionText)
        }
        tabCoordinator.pendingOrders.resolve(id: order.id)
    }

}

// MARK: - CommandHost

extension MainWindowController: CommandHost {
    /// The fleet as the command language sees it, with every pane's stable
    /// handle minted on sight.
    func fleetIndex() -> FleetIndex {
        let registry = PaneHandleRegistry.shared
        let panes = AgentRegistry.shared.allPanes().map { pane -> PaneRef in
            let sessionKey = pane.station?.paneSessionKey ?? ""
            let key = PaneHandleRegistry.key(sessionKey: sessionKey, paneId: pane.id)
            return PaneRef(handle: registry.handle(for: key), handleKey: key, id: pane.id, sessionKey: sessionKey,
                           project: pane.project, branch: pane.branch, worktreePath: pane.worktreePath,
                           type: pane.agentType.displayName, title: PaneTitleResolver.title(for: pane),
                           // `displayStatus`, the same field the dashboard
                           // draws — a pane whose agent is idle while its
                           // background work runs reads as busy on both. The
                           // raw `status` is for edges and notifications; using
                           // it here made `/status` on a phone disagree with
                           // the fleet on screen, which is the one thing a
                           // remote listing must not do.
                           status: pane.displayStatus,
                           // The assistant's own prose where there is any; a screen
                           // scan makes poor reading in a chat or a mail.
                           lastMessage: pane.lastAssistantMessage.isEmpty ? pane.lastMessage : pane.lastAssistantMessage)
        }
        let worktrees = tabCoordinator.allWorktrees.map {
            WorktreeRef(repo: tabCoordinator.repoName(forWorktree: $0.info.path),
                        branch: $0.info.branch, path: $0.info.path, isMain: $0.info.isMainWorktree)
        }
        let repos = tabCoordinator.config.workspacePaths.map {
            RepoRef(name: URL(fileURLWithPath: $0).lastPathComponent, path: $0)
        }
        return FleetIndex(panes: panes, worktrees: worktrees, repos: repos)
    }

    /// The desktop talks to the selected worktree's pane.
    var desktopBoundPaneKey: String? {
        guard let path = dashboardVC?.lastCommittedWorktreePath,
              let pane = AgentRegistry.shared.pane(forWorktree: path) else { return nil }
        return PaneHandleRegistry.key(sessionKey: pane.station?.paneSessionKey ?? "", paneId: pane.id)
    }

    var integrationEnabled: Bool { config.integrationEnabled }

    func createWorktree(task: String, repoPath: String, completion: @escaping (String?) -> Void) {
        performWorktreeCreate(task: task, repoPath: repoPath, agentType: .claudeCode, reuseEnv: false,
                              onComplete: completion)
    }

    func selectWorktree(path: String) {
        dashboardVC?.commitWorktreeSelection(path: path)
    }

    func sendText(paneId: String, text: String) -> Bool {
        guard AgentRegistry.shared.pane(for: paneId) != nil else { return false }
        AgentRegistry.shared.sendCommand(to: paneId, command: text)
        return true
    }

    func transcript(paneSessionKey: String) -> String? {
        ZmxChannel(paneSessionKey: paneSessionKey).recentTranscript(lines: 60)
    }

    /// Recent tool activity for one pane, as plain lines.
    func activity(paneId: String) -> [String] {
        guard let pane = AgentRegistry.shared.pane(for: paneId) else { return [] }
        return pane.activityEvents.map {
            "\($0.isError ? "✕ " : "")\($0.tool)\($0.detail.isEmpty ? "" : " — \($0.detail)")"
        }
    }

    func isIntegrationCheckout(worktreePath: String) -> Bool {
        IntegrationWorktreeStore.shared.isIntegrationWorktree(worktreePath)
    }

    /// Git subprocesses plus one network round trip (the fetch, and a PR
    /// lookup when origin is GitHub) — off the main thread, with every piece
    /// of main-thread state read first.
    func assessReturn(worktreePath path: String, completion: @escaping (WorktreeReturnFacts) -> Void) {
        let info = tabCoordinator.allWorktrees.first { $0.info.path == path }?.info
        let running = AgentRegistry.shared.hasRunningPane(inWorktree: path)
        let task = WorktreeTaskStore.shared.task(forWorktree: path)
        let recordedBase = WorktreeBaseBranchStore.shared.baseBranch(forWorktree: path)
        let isIntegration = IntegrationWorktreeStore.shared.isIntegrationWorktree(path)
        let repoCache = tabCoordinator.worktreeRepoCache
        let tokenRepoPath = tabCoordinator.config.selectedWorktreePath
        DispatchQueue.global(qos: .userInitiated).async {
            let repoPath = repoCache[path] ?? WorktreeDiscovery.findRepoRoot(from: path) ?? path
            var facts = WorktreeReturnAssessor.assess(
                worktreePath: path, repoPath: repoPath, branch: info?.branch ?? "",
                isMain: info?.isMainWorktree ?? false, isDetached: info?.isDetached ?? false,
                recordedBase: recordedBase)
            facts.agentRunning = running
            facts.isIntegration = isIntegration
            facts.taskDescription = task
            if case .github(let owner, let repo) = facts.remote {
                let token = Self.resolveGitHubToken(repoPath: tokenRepoPath)
                facts.hasGitHubToken = !token.isEmpty
                if !token.isEmpty, !facts.branch.isEmpty {
                    let client = GitHubReturnPRClient(
                        service: GitHubPRService(token: token, owner: owner, repo: repo), owner: owner)
                    facts.existingPRURL = client.openPRURL(branch: facts.branch)
                }
            }
            DispatchQueue.main.async { completion(facts) }
        }
    }

    /// Commit, push and PR run on a background queue; the delete goes through
    /// the coordinator so the panes and sessions come down with the tree.
    func performReturn(_ plan: WorktreeReturnPlan, worktree: WorktreeRef,
                       completion: @escaping (WorktreeReturnOutcome) -> Void) {
        let path = worktree.path
        let branch = worktree.branch
        let task = WorktreeTaskStore.shared.task(forWorktree: path)
        let tokenRepoPath = tabCoordinator.config.selectedWorktreePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var pr: WorktreeReturnPRClient?
            if let url = GitProcess.run(["remote", "get-url", "origin"], in: path),
               let remote = GitRemote.parse(url), case .github(let owner, let repo) = remote.kind {
                let token = Self.resolveGitHubToken(repoPath: tokenRepoPath)
                if !token.isEmpty {
                    pr = GitHubReturnPRClient(
                        service: GitHubPRService(token: token, owner: owner, repo: repo), owner: owner)
                }
            }
            let outcome = WorktreeReturnRunner.run(plan, branch: branch, task: task,
                                                   git: WorktreeReturnGitProcess(worktreePath: path), pr: pr)
            DispatchQueue.main.async {
                guard let self else { return }
                if outcome.deletesWorktree {
                    // Row pending through the tear-down; clears when git finishes.
                    self.pendingReturnPath = nil
                    self.terminalCoordinator.deleteWorktreeWithoutConfirm(
                        path: path, branch: branch, deleteBranch: outcome.deletesBranch, force: true
                    ) { [weak self] pending in
                        self?.dashboardVC?.setWorktreePending(path: path, pending: pending)
                    }
                } else {
                    self.clearPendingReturn()
                }
                completion(outcome)
            }
        }
    }

    /// lastPathComponent is what the parser matched, so it is also the tab's
    /// displayName. Kills sessions, leaves every worktree on disk.
    func forgetRepo(path: String) {
        tabCoordinator.performCloseRepo(projectName: URL(fileURLWithPath: path).lastPathComponent)
    }

    func integrate(mode: IntegrationConflictMode, force: Bool,
                   completion: @escaping (String, Bool) -> Void) {
        guard let selected = tabCoordinator.config.selectedWorktreePath,
              let repoPath = WorktreeDiscovery.findRepoRoot(from: selected) else {
            completion("No repo selected.", false)
            return
        }
        let worktrees = tabCoordinator.allWorktrees
            .map(\.info)
            .filter { WorktreeDiscovery.findRepoRoot(from: $0.path) == repoPath }
        let integrationPath = IntegrationWorktreeStore.shared.worktreePath(forRepo: repoPath)
            ?? IntegrationWorktree.defaultPath(forRepo: repoPath)
        let lastPublished = IntegrationWorktreeStore.shared.lastPublishedCommit(forCheckout: integrationPath)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<IntegrationRunReport, Error>
            do {
                outcome = .success(try IntegrationRunner.run(
                    repoPath: repoPath,
                    integrationPath: integrationPath,
                    worktrees: worktrees,
                    mode: mode,
                    force: force,
                    lastPublished: lastPublished,
                    // A busy worktree comes in at HEAD rather than as a
                    // half-written file that reads as a conflict it is not.
                    isBusy: { AgentRegistry.shared.hasRunningPane(inWorktree: $0) }
                ))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                switch outcome {
                case .success(let report):
                    IntegrationWorktreeStore.shared.set(report.integrationWorktreePath, forRepo: repoPath)
                    IntegrationStatusStore.shared.set(report.panelState, forWorktree: report.integrationWorktreePath)
                    if case .published(let commit) = report.outcome {
                        IntegrationWorktreeStore.shared.recordPublished(commit, forCheckout: report.integrationWorktreePath)
                    }
                    // The desktop learns of a round that needs a decision from
                    // its card, whichever surface asked for the round.
                    if report.needsAttention {
                        self?.enqueueIntegrationReport(report.summary, repoPath: repoPath,
                                                       checkoutPath: report.integrationWorktreePath,
                                                       options: report.cardOptions)
                    }
                    completion(report.summary, report.isHeld)
                case .failure(let error):
                    IntegrationStatusStore.shared.set(
                        .failed(error.localizedDescription), forWorktree: integrationPath)
                    completion("Integration failed: \(error.localizedDescription)", false)
                }
            }
        }
    }

    func addIdea(text: String, source: String) -> String {
        IdeaStore.shared.add(text: text, project: "external", source: source, tags: []).text
    }

    func openIssue(title: String) {
        openGitHubIssue(title: title)
    }

    func addRepo() {
        tabCoordinator.addRepoViaOpenPanel(window: window)
    }

    /// The desktop's `/yes`: one sheet, same wording as the chat question.
    func confirm(_ summary: String, completion: @escaping (Bool) -> Void) {
        // A confirmation sheet replaces the row spinner as feedback.
        clearPendingReturn()
        guard let window else {
            completion(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = summary
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Go ahead")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
    }

    /// Telegram delivery for a pane-status banner. Bound chats hear only their
    /// pane; the default / last-order chat hears the whole fleet while unbound.
    ///
    /// `fleetSilenced` drops the fleet-wide listeners for this one event — the
    /// desktop already showed it. Chats bound to the pane are never dropped.
    private func notifyTelegramSessions(terminalID: String, text: String, fleetSilenced: Bool = false) {
        let paneKey: String?
        if !terminalID.isEmpty, let pane = AgentRegistry.shared.pane(for: terminalID) {
            paneKey = PaneHandleRegistry.key(sessionKey: pane.station?.paneSessionKey ?? "",
                                             paneId: pane.id)
        } else {
            paneKey = nil
        }
        var fleet: [String] = []
        if !fleetSilenced {
            if let chat = config.telegram?.resolvedDefaultChatId { fleet.append(chat) }
            if let chat = telegramChannel?.fleetNotifyChatId, !fleet.contains(chat) {
                fleet.append(chat)
            }
        }
        let chats = tabCoordinator.commandSessions.telegramChatsToNotify(
            paneKey: paneKey, fleetListenerChatIds: fleet)
        for chatId in chats {
            AgentRegistry.shared.pushToChannel("telegram", message: OutboundMessage(
                channelId: "telegram", targetChatId: chatId, content: text, format: .markdown)
            ) { [weak self] messageId in
                // Remembered so an agent's next-step options, which land a beat
                // after this, can be added to it as buttons.
                guard !terminalID.isEmpty, let messageId else { return }
                DispatchQueue.main.async {
                    self?.rememberNotice(terminalID: terminalID, chatId: chatId, messageId: messageId)
                }
            }
        }
    }
}


// MARK: - Chat cards

extension MainWindowController {
    /// One message per card, and only when there is something to say.
    ///
    /// Both kinds of card carry options, but they earn their place on a phone
    /// differently:
    ///
    ///   - A **question** is a stop. The pane sits at its prompt until someone
    ///     picks, and until this existed the only place to pick was this Mac,
    ///     which made every approval a walk back to the desk. It gets a message
    ///     of its own.
    ///   - A **suggestion** is an offer, and its words have already been sent:
    ///     the card's summary and the completion notice are both the agent's
    ///     final prose. So it gets no message — its options are added to that
    ///     notice as buttons. No notice, no buttons: if the completion was
    ///     never worth telling the phone about, neither are its next steps.
    ///
    /// A suggestion whose notice has not come back with an id yet is left out
    /// of the seen set rather than dropped, so the next pass picks it up.
    func publishCardsToChat(_ orders: [PendingOrder]) {
        retireVanishedCardButtons(live: Set(orders.map(\.id)))

        let attachable = orders.filter { order in
            guard !(order.action.options ?? []).isEmpty else { return false }
            return FirstMateAction.isQuestionPayload(order.action.payload)
                || !noticeBook.recent(pane: order.action.terminalID).isEmpty
        }
        for order in chatSeenCards.absorb(attachable) {
            if FirstMateAction.isQuestionPayload(order.action.payload) {
                sendCardToChat(order)
            } else {
                attachOptionsToNotice(order)
            }
        }
    }

    /// Add a suggestion's options to the completion notice they belong under.
    private func attachOptionsToNotice(_ order: PendingOrder) {
        let targets = noticeBook.recent(pane: order.action.terminalID)
        guard !targets.isEmpty else { return }
        let buttons = optionButtons(for: order)
        for target in targets {
            AgentRegistry.shared.setButtons(channelId: "telegram", chatId: target.chatId,
                                            messageId: target.messageId, buttons: buttons)
        }
        cardButtonMessages[order.id] = targets
    }

    func rememberNotice(terminalID: String, chatId: String, messageId: String) {
        noticeBook.record(pane: terminalID, chatId: chatId, messageId: messageId)
    }

    /// Take the buttons off cards that have left the queue, and forget notices
    /// too old to attach to. Runs on the island's refresh, which is the only
    /// place that sees the queue as a whole.
    private func retireVanishedCardButtons(live: Set<String>) {
        for orderId in cardButtonMessages.keys where !live.contains(orderId) {
            retireCardButtons(orderId)
        }
        noticeBook.prune()
    }

    /// Take one card's buttons down everywhere they were drawn — answering it
    /// in one chat must not leave it on offer in another.
    private func retireCardButtons(_ orderId: String) {
        for ref in cardButtonMessages.removeValue(forKey: orderId) ?? [] {
            AgentRegistry.shared.setButtons(channelId: "telegram", chatId: ref.chatId,
                                            messageId: ref.messageId, buttons: [])
        }
    }

    /// The card's options as buttons. `dismissable` adds a way to clear a card
    /// without answering it — worth offering on a question, which otherwise
    /// sits there, and not on a suggestion, where not tapping *is* declining.
    private func optionButtons(for order: PendingOrder, dismissable: Bool = false) -> [MessageButton] {
        // Minted once and shared by every chat the card reaches: a token says
        // what the button means, not who tapped it.
        var buttons = (order.action.options ?? []).enumerated().map { index, label in
            MessageButton(label: label, token: ChatCallbackRegistry.shared.mint(
                .suggestionOption(orderId: order.id, index: index)))
        }
        if dismissable {
            buttons.append(MessageButton(label: "Leave it waiting",
                                         token: ChatCallbackRegistry.shared.mint(
                                            .dismissSuggestion(orderId: order.id))))
        }
        return buttons
    }

    private func sendCardToChat(_ order: PendingOrder) {
        let pane = AgentRegistry.shared.pane(for: order.action.terminalID)
        let paneKey = pane.map {
            PaneHandleRegistry.key(sessionKey: $0.station?.paneSessionKey ?? "", paneId: $0.id)
        }
        // Unlike a completion notice, a card is not silenced by `/go`. Binding
        // says "route my conversation to #12"; it does not say "don't tell me
        // when the fleet stops". A blocked agent is the one thing that never
        // resolves itself, and a chat bound to another pane is still the only
        // way its owner can answer this one without walking back to the Mac.
        var chats = Set(tabCoordinator.commandSessions.telegramChatsToNotify(
            paneKey: paneKey, fleetListenerChatIds: []))
        if let chat = config.telegram?.resolvedDefaultChatId { chats.insert(chat) }
        if let chat = telegramChannel?.fleetNotifyChatId { chats.insert(chat) }
        guard !chats.isEmpty else { return }

        let buttons = optionButtons(for: order, dismissable: true)
        let text = Self.questionCardText(
            handle: paneKey.map { PaneHandleRegistry.shared.handle(for: $0) },
            project: order.action.project, branch: order.action.branch,
            message: order.action.message, options: order.action.options ?? [])
        for chatId in chats {
            AgentRegistry.shared.pushToChannel("telegram", message: OutboundMessage(
                channelId: "telegram", targetChatId: chatId, content: text,
                format: .markdown, buttons: buttons)
            ) { [weak self] messageId in
                guard let messageId else { return }
                DispatchQueue.main.async {
                    self?.cardButtonMessages[order.id, default: []].append(
                        ChatNoticeBook.Ref(chatId: chatId, messageId: messageId))
                }
            }
        }
    }


    /// The card as a chat message. Pure, so its shape is testable.
    ///
    /// The options are spelled out in the text as well as drawn as buttons: a
    /// button label is trimmed to fit a phone's width, and the difference
    /// between two options is often in the part that gets trimmed.
    static func questionCardText(handle: Int?, project: String, branch: String,
                                 message: String, options: [String]) -> String {
        let target = [project, branch].filter { !$0.isEmpty }.joined(separator: " / ")
        let head = [handle.map { "#\($0)" }, target.isEmpty ? nil : target]
            .compactMap { $0 }.joined(separator: " · ")
        var lines = ["\(AgentStatus.waiting.icon) **Waiting on you**"]
        if !head.isEmpty { lines.append(head) }
        let prompt = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { lines.append("\n\(prompt)") }
        if !options.isEmpty {
            lines.append("")
            for (index, option) in options.enumerated() {
                lines.append("\(index + 1). \(option)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Someone tapped a button in a chat.
    ///
    /// A token that no longer resolves is not an error: the tokens live only as
    /// long as the run, and a card's message sits in the chat's history forever,
    /// so a tap can arrive from last week or from before a relaunch. Say so and
    /// change nothing — replaying it against a fleet that has moved on is how a
    /// stale button ends up typing into somebody else's pane.
    func handleChatCallback(_ callback: InboundCallback) {
        guard let action = ChatCallbackRegistry.shared.action(for: callback.token) else {
            replyToChat(callback, "That card has already been answered — or it is from before seahelm last started.")
            return
        }
        switch action {
        case .command(let line):
            // A line's buttons are a listing's shortcuts — `/go #7` beside each
            // pane — and stay tappable: picking one is not answering anything.
            let surface = CommandSurface(
                sessionKey: CommandSession.key(surface: "telegram", id: callback.chatId),
                isDesktop: false, commander: callback.senderId)
            commandExecutor.run(line, surface: surface) { [weak self] reply in
                guard !reply.text.isEmpty else { return }
                self?.replyToChat(callback, reply.text)
            }
            return
        case .suggestionOption(let orderId, let index):
            guard let order = tabCoordinator.pendingOrders.all().first(where: { $0.id == orderId }),
                  let options = order.action.options, index < options.count else {
                replyToChat(callback, "That card is gone — the agent moved on.")
                return
            }
            let option = options[index]
            // Retire first: answering the card re-enqueues the next question of
            // a multi-part ask under the same id, and its fresh tokens must not
            // be swept away by the resolve that follows.
            ChatCallbackRegistry.shared.retire(orderId: orderId)
            handleSuggestionTapped(order: order, optionText: option)
            replyToChat(callback, "Picked **\(option)**.")
        case .dismissSuggestion(let orderId):
            tabCoordinator.pendingOrders.resolve(id: orderId)
            replyToChat(callback, "Left it. The agent is still waiting — answer it on the Mac when you get there.")
        }
        // The card has been dealt with; its buttons must stop offering options
        // in a message that stays in the chat's history for good — in *every*
        // chat that was shown it, not only the one that answered. (A `.command`
        // button returned above; nothing was answered.)
        let orderId = Self.orderId(of: action)
        let tapped = ChatNoticeBook.Ref(chatId: callback.chatId, messageId: callback.messageId)
        if let orderId {
            // Matched on the message, not the whole ref: `at` is "now" here and
            // would never equal the moment the card was sent, so an identity
            // comparison would book the same message twice and edit it twice.
            let known = cardButtonMessages[orderId]?.contains {
                $0.chatId == tapped.chatId && $0.messageId == tapped.messageId
            } ?? false
            if !known { cardButtonMessages[orderId, default: []].append(tapped) }
            retireCardButtons(orderId)
        } else {
            AgentRegistry.shared.setButtons(channelId: callback.channelId, chatId: callback.chatId,
                                            messageId: callback.messageId, buttons: [])
        }
    }

    /// Which card a tap belongs to, when it belongs to one.
    private static func orderId(of action: ChatCallbackAction) -> String? {
        switch action {
        case .command: return nil
        case .suggestionOption(let orderId, _): return orderId
        case .dismissSuggestion(let orderId): return orderId
        }
    }

    private func replyToChat(_ callback: InboundCallback, _ markdown: String) {
        AgentRegistry.shared.pushToChannel(callback.channelId, message: OutboundMessage(
            channelId: callback.channelId, targetChatId: callback.chatId,
            content: markdown, format: .markdown))
    }
}
