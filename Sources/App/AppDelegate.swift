import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindowController: MainWindowController?
    private var onboardingController: OnboardingWindowController?

    /// Periodically sweeps zmx sessions whose worktree no longer exists.
    private var orphanCleanupTimer: Timer?
    /// How often to clean up orphan zmx sessions (5 minutes).
    private let orphanCleanupInterval: TimeInterval = 300

    /// True when the process is hosting XCTest. The unit tests exercise types
    /// directly and never need the real app (window, Ghostty, git discovery,
    /// hook installers). Skipping bootstrap keeps them hermetic and prevents the
    /// test runner from hanging when git on an external volume stalls at launch.
    static var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningUnitTests else { return }
        // Register bundled JetBrains Mono before any view builds its fonts.
        AppFont.registerBundledFonts()

        // Categories / delegate only — permission is requested in onboarding or later.
        _ = NotificationManager.shared

        let config = Config.load()
        NotificationManager.shared.cooldown = config.notifications.cooldown
        NotificationManager.shared.stabilityDelay = config.notifications.stabilityDelay
        NotificationManager.shared.soundPreference = config.notificationSound

        cleanOrphanZmxSessions()
        scheduleOrphanZmxCleanup()

        let mode = ThemeMode(rawValue: config.themeMode) ?? .system
        ThemeMode.applyAppearance(mode)
        NSAppearance.current = NSApp.effectiveAppearance

        // `--render-onboarding <dir>` renders the wizard steps to PNGs and
        // exits — headless design iteration.
        if let idx = CommandLine.arguments.firstIndex(of: "--render-onboarding"),
           CommandLine.arguments.count > idx + 1 {
            OnboardingWindowController.renderSnapshots(to: CommandLine.arguments[idx + 1])
            exit(0)
        }

        // `--show-onboarding` forces the wizard for design iteration without
        // resetting config (finishing it still saves normally).
        if !config.onboardingCompleted || CommandLine.arguments.contains("--show-onboarding") {
            let wizard = OnboardingWindowController(config: config)
            wizard.onComplete = { [weak self] updated in
                self?.onboardingController = nil
                self?.bootstrapMainApp(config: updated)
            }
            onboardingController = wizard
            wizard.show()
            return
        }

        bootstrapMainApp(config: config)
    }

    /// Hooks, stores, channels, Ghostty, and main window — after onboarding (or immediately).
    private func bootstrapMainApp(config: Config) {
        OnboardingHookInstaller.installForLaunch(config: config)
        NSAppearance.current = NSApp.effectiveAppearance

        TodoStore.shared.load()
        IdeaStore.shared.load()
        NotificationHistory.shared.load()

        // Existing users who skipped the wizard still need a permission prompt once.
        if config.onboardingCompleted {
            NotificationManager.shared.requestPermission()
        }

        if let wecomConfig = config.wecomBot, wecomConfig.resolvedAutoConnect {
            let channel = WeComBotChannel(config: wecomConfig)
            ShipLog.shared.registerChannel(channel)
            channel.connect()
            NSLog("[App] WeCom bot auto-connecting: \(wecomConfig.resolvedName)")
        }

        if let wechatConfig = config.wechat, wechatConfig.resolvedAutoConnect {
            let channel = WeChatChannel(config: wechatConfig)
            channel.onAuthExpired = { [weak self] in
                self?.mainWindowController?.promptWeChatReauth()
            }
            ShipLog.shared.registerChannel(channel)
            channel.connect()
            NSLog("[App] WeChat auto-connecting")
        }

        GhosttyBridge.shared.initialize()

        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
    }

    /// Schedule periodic cleanup of zmx sessions whose worktree no longer exists.
    private func scheduleOrphanZmxCleanup() {
        orphanCleanupTimer?.invalidate()
        orphanCleanupTimer = Timer.scheduledTimer(
            withTimeInterval: orphanCleanupInterval,
            repeats: true
        ) { [weak self] _ in
            self?.cleanOrphanZmxSessions()
        }
    }

    /// Sweep orphan zmx sessions on a background queue. Config is reloaded each
    /// call so newly added/removed worktrees and split layouts are reflected.
    private func cleanOrphanZmxSessions() {
        DispatchQueue.global(qos: .utility).async {
            guard ZmxLocator.isAvailable else { return }
            let config = Config.load()
            let discovered = config.workspacePaths.map { repoPath in
                WorktreeDiscovery.discover(repoPath: repoPath).map(\.path)
            }
            // A repo always has at least its main worktree, so an empty result
            // for ANY repo means discovery failed transiently (git lock, timing,
            // unmounted volume) — not that the repo has no sessions. Proceeding
            // would classify that repo's live sessions as orphans and force-kill
            // attached panes (agents included). Skip the whole sweep this round.
            guard !discovered.contains(where: \.isEmpty) else {
                if !config.workspacePaths.isEmpty {
                    NSLog("[App] Skipping orphan zmx cleanup — worktree discovery incomplete")
                }
                return
            }
            let worktreePaths = discovered.flatMap { $0 }
            let activeSessionNames = SessionManager.expectedSessionNames(
                config: config,
                discoveredWorktreePaths: worktreePaths
            )
            let cleaned = SessionManager.cleanupOrphanZmxSessions(activeSessionNames: activeSessionNames)
            if !cleaned.isEmpty {
                NSLog("[App] Cleaned %d orphan zmx session(s)", cleaned.count)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // Prevent macOS from trying to create a new window via NSDocumentController
        // when the app is activated (e.g. from notification click)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Prevent macOS from creating a new window on reactivation (e.g. notification click)
        if let window = mainWindowController?.window {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else if let window = onboardingController?.window {
            window.makeKeyAndOrderFront(nil)
        }
        return false
    }

    /// Block the default File > New Window action that macOS may invoke on activation
    @objc func newDocument(_ sender: Any?) {
        // Bring existing window to front instead of creating a new one
        if let window = mainWindowController?.window {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else if let window = onboardingController?.window {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Covers Cmd+Q and the menu item. The close-button path also lands here,
        // but QuitConfirmation has already latched the answer by then.
        return QuitConfirmation.shouldQuit(for: mainWindowController?.window) ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        orphanCleanupTimer?.invalidate()
        orphanCleanupTimer = nil
        mainWindowController?.cleanupBeforeTermination()
        GhosttyBridge.shared.shutdown()
    }
}
