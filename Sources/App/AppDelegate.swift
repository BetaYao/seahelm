import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindowController: MainWindowController?

    /// Periodically sweeps seahelmd sessions whose worktree no longer exists.
    private var orphanCleanupTimer: Timer?
    /// How often to clean up orphan seahelmd sessions (5 minutes).
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

        // Categories / delegate only — permission is requested in bootstrap below.
        _ = NotificationManager.shared

        var config = Config.load()
        NotificationManager.shared.cooldown = config.notifications.cooldown
        NotificationManager.shared.stabilityDelay = config.notifications.stabilityDelay
        NotificationManager.shared.soundPreference = config.notificationSound

        cleanOrphanSeahelmdSessions()
        scheduleOrphanSeahelmdCleanup()

        let mode = ThemeMode(rawValue: config.themeMode) ?? .system
        ThemeMode.applyAppearance(mode)
        NSAppearance.current = NSApp.effectiveAppearance

        // Watch workspace volumes so an abrupt external-disk disconnect fences
        // path I/O before the main thread beachballs on a stale mount.
        VolumePresenceMonitor.shared.start(workspacePaths: config.workspacePaths)
        VolumePresenceMonitor.shared.onVolumeRecovered = { [weak self] _ in
            self?.mainWindowController?.tabCoordinator.startBranchRefreshTimer()
        }

        Analytics.initialize()
        Analytics.trackAppStarted(worktreeCount: Analytics.knownWorktreeCount(from: config))

        // There is no first-launch wizard: a fresh config opens straight on the
        // main window. The one choice the wizard used to ask for — which agent a
        // new worktree starts — is taken from what is on PATH instead. (Not under
        // a UI-test config, which is not the file this would write.)
        if !config.onboardingCompleted, !CommandLine.arguments.contains("-UITestConfig") {
            config.defaultAgent = AgentDetector
                .preferredDefault(from: AgentDetector.scan()).rawValue
            config.onboardingCompleted = true
            config.saveNow()
        }

        bootstrapMainApp(config: config)
    }

    /// Hooks, stores, channels, Ghostty, and main window.
    private func bootstrapMainApp(config: Config) {
        AgentHookInstaller.installForLaunch(config: config)
        NSAppearance.current = NSApp.effectiveAppearance

        TodoStore.shared.load()
        IdeaStore.shared.load()
        NotificationHistory.shared.load()

        NotificationManager.shared.requestPermission()

        // Telegram is the phone-side remote-control transport.
        if let telegramConfig = config.telegram, telegramConfig.resolvedAutoConnect {
            let channel = TelegramChannel(config: telegramConfig)
            AgentRegistry.shared.registerChannel(channel)
            channel.connect()
            NSLog("[App] Telegram bridge connecting (\(telegramConfig.allowedUsers.count) allowed users)")
        }

        GhosttyBridge.shared.initialize()

        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
        mainWindowController?.startGmailMailChannel(config: config.gmailMail)
    }

    /// Schedule periodic cleanup of seahelmd sessions whose worktree no longer exists.
    private func scheduleOrphanSeahelmdCleanup() {
        orphanCleanupTimer?.invalidate()
        orphanCleanupTimer = Timer.scheduledTimer(
            withTimeInterval: orphanCleanupInterval,
            repeats: true
        ) { [weak self] _ in
            self?.cleanOrphanSeahelmdSessions()
        }
    }

    /// Sweep orphan seahelmd sessions on a background queue. Config is reloaded each
    /// call; only sessions not attached to current panes are eligible.
    private func cleanOrphanSeahelmdSessions() {
        // The live-pane set is walked off `allWorktrees` and its split trees,
        // which the main thread mutates on discovery/create/delete — so snapshot
        // it here (both callers are already on main) and send only the seahelmd
        // probing to the background queue.
        guard let controller = mainWindowController else {
            NSLog("[App] Skipping orphan session cleanup — main window not ready")
            return
        }
        let activeSessionNames = controller.activePaneSessionNamesForCleanup()
        guard !activeSessionNames.isEmpty else {
            // During startup/teardown there may be no attached panes yet; an
            // empty set would match everything and is too risky to sweep.
            NSLog("[App] Skipping orphan session cleanup — no live pane sessions")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            guard SeahelmdLocator.isAvailable else { return }
            let cleaned = SessionManager.cleanupOrphanSeahelmdSessions(activeSessionNames: activeSessionNames)
            if !cleaned.isEmpty {
                NSLog("[App] Cleaned %d orphan session(s)", cleaned.count)
            }
            // Volume-drop corpses: unreachable daemons whose start_dir is gone
            // or wedged, plus attach clients still spinning under a live parent.
            let wedged = SessionManager.cleanupWedgedVolumeSessions()
            if !wedged.isEmpty {
                NSLog("[App] Cleaned %d volume-wedged session(s)", wedged.count)
            }
            // Separate from the session sweep above: these are client processes,
            // not sessions. They survive the app that spawned them and spin at
            // 20-70% CPU indefinitely, so each restart adds a few more.
            // `cleanupWedgedVolumeSessions` already reaps wedged attaches; this
            // pass catches ppid==1 orphans from prior app instances.
            let clients = SessionManager.cleanupOrphanSeahelmdClients()
            if !clients.isEmpty {
                NSLog("[App] Killed %d orphan attach client process(es)", clients.count)
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
        }
        return false
    }

    /// Block the default File > New Window action that macOS may invoke on activation
    @objc func newDocument(_ sender: Any?) {
        // Bring existing window to front instead of creating a new one
        if let window = mainWindowController?.window {
            window.deminiaturize(nil)
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
