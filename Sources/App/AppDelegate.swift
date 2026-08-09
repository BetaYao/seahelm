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

        // WeCom and WeChat are retired — their channels still compile but nothing
        // constructs them any more. iMessage is the phone-side transport now.
        if let imessageConfig = config.imessage, imessageConfig.resolvedAutoConnect {
            let channel = IMessageChannel(config: imessageConfig)
            ShipLog.shared.registerChannel(channel)
            channel.connect()
            NSLog("[App] iMessage bridge connecting (\(imessageConfig.allowedHandles.count) allowed handles)")
        }

        GhosttyBridge.shared.initialize()

        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
        mainWindowController?.startGmailMailChannel(config: config.gmailMail)
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
    /// call; only sessions not attached to current panes are eligible.
    private func cleanOrphanZmxSessions() {
        // The live-pane set is walked off `allWorktrees` and its split trees,
        // which the main thread mutates on discovery/create/delete — so snapshot
        // it here (both callers are already on main) and send only the zmx
        // probing to the background queue.
        guard let controller = mainWindowController else {
            NSLog("[App] Skipping orphan zmx cleanup — main window not ready")
            return
        }
        let activeSessionNames = controller.activePaneSessionNamesForCleanup()
        guard !activeSessionNames.isEmpty else {
            // During startup/teardown there may be no attached panes yet; an
            // empty set would match everything and is too risky to sweep.
            NSLog("[App] Skipping orphan zmx cleanup — no live pane sessions")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            guard ZmxLocator.isAvailable else { return }
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
