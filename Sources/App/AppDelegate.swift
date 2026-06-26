import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindowController: MainWindowController?

    /// Periodically sweeps zmx sessions whose worktree no longer exists.
    private var orphanCleanupTimer: Timer?
    /// How often to clean up orphan zmx sessions (5 minutes).
    private let orphanCleanupInterval: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register bundled JetBrains Mono before any view builds its fonts.
        AppFont.registerBundledFonts()

        // Ensure notification delegate is set before any notification response arrives
        _ = NotificationManager.shared

        // Force dark appearance globally BEFORE any views are created.
        // Must set BOTH NSApp.appearance AND NSAppearance.current so that
        // NSColor(name:) dynamic colors resolve correctly even for views
        // not yet added to a window (e.g. during init/setup).
        let config = Config.load()
        cleanOrphanZmxSessions()
        scheduleOrphanZmxCleanup()
        let mode = ThemeMode(rawValue: config.themeMode) ?? .dark
        ThemeMode.applyAppearance(mode)

        // Ensure supported CLI hook integrations are configured
        if config.webhook.enabled {
            ClaudeHooksSetup.ensureHooksConfigured(port: config.webhook.port)
            ClaudeStatuslineBridgeInstaller.ensureInstalled()
            CodexHooksSetup.ensureHooksConfigured(port: config.webhook.port)
            SeahelmSuggestInstaller.ensureInstalled(port: config.webhook.port)
        }
        NSAppearance.current = NSApp.effectiveAppearance

        // Load TODO and Ideas stores
        TodoStore.shared.load()
        IdeaStore.shared.load()

        // Auto-connect WeCom bot if configured
        if let wecomConfig = config.wecomBot, wecomConfig.resolvedAutoConnect {
            let channel = WeComBotChannel(config: wecomConfig)
            ShipLog.shared.registerChannel(channel)
            channel.connect()
            NSLog("[App] WeCom bot auto-connecting: \(wecomConfig.resolvedName)")
        }

        // Auto-connect WeChat if configured
        if let wechatConfig = config.wechat, wechatConfig.resolvedAutoConnect {
            let channel = WeChatChannel(config: wechatConfig)
            ShipLog.shared.registerChannel(channel)
            channel.connect()
            NSLog("[App] WeChat auto-connecting")
        }

        // Initialize GhosttyApp singleton
        GhosttyBridge.shared.initialize()

        // Create and show main window
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
            guard ProcessRunner.commandExists("zmx") else { return }
            let config = Config.load()
            let worktreePaths = config.workspacePaths.flatMap { repoPath in
                WorktreeDiscovery.discover(repoPath: repoPath).map(\.path)
            }
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

    func applicationWillTerminate(_ notification: Notification) {
        orphanCleanupTimer?.invalidate()
        orphanCleanupTimer = nil
        mainWindowController?.cleanupBeforeTermination()
        GhosttyBridge.shared.shutdown()
    }
}
