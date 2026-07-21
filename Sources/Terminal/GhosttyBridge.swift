import AppKit

/// Singleton wrapper for the Ghostty application instance.
/// Manages global Ghostty lifecycle and runtime callbacks.
class GhosttyBridge {
    static let shared = GhosttyBridge()

    private(set) var app: ghostty_app_t?
    /// Owned config kept alive for soft `reload_config` (light/dark theme swap).
    private var config: ghostty_config_t?
    private var isInitialized = false
    private var appearanceObservation: NSKeyValueObservation?

    /// Nested live-resize sessions (chrome divider / window resize). While > 0,
    /// GhosttyNSView defers `ghostty_surface_set_size` so the PTY isn't flooded
    /// with SIGWINCH (which makes shells like starship reprint blank prompts).
    private var liveResizeDepth = 0
    /// Chrome sidebar drag is horizontal-only — pin surface height so layout
    /// jitter can't change rows (each row change also redraws the prompt).
    private(set) var liveResizePinsHeight = false
    /// After a chrome sidebar drag, keep skipping PTY `set_size` until the next
    /// real window resize. Otherwise a post-drag layout pass re-enters sync and
    /// still injects a blank starship prompt line.
    private(set) var suppressSurfaceGridResize = false
    var isLiveResizing: Bool { liveResizeDepth > 0 }

    private init() {}

    func beginLiveResize(pinHeight: Bool = false) {
        if !pinHeight {
            // Window resize is allowed to change the grid again.
            suppressSurfaceGridResize = false
        }
        if liveResizeDepth == 0 {
            liveResizePinsHeight = pinHeight
        } else {
            liveResizePinsHeight = liveResizePinsHeight || pinHeight
        }
        liveResizeDepth += 1
    }

    func endLiveResize() {
        guard liveResizeDepth > 0 else { return }
        liveResizeDepth -= 1
        guard liveResizeDepth == 0 else { return }
        let pinHeight = liveResizePinsHeight
        liveResizePinsHeight = false
        if pinHeight {
            suppressSurfaceGridResize = true
        }
        for station in StationRegistry.shared.allStations() {
            station.view?.flushDeferredSurfaceSize(pinHeight: pinHeight)
        }
    }

    /// Allow PTY grid sync again (e.g. after a real window live-resize ends).
    func clearSurfaceGridResizeSuppression() {
        suppressSurfaceGridResize = false
    }

    func initialize() {
        guard !isInitialized else { return }

        // Point libghostty at bundled themes before config load / finalize.
        Self.configureResourcesEnvironment()
        // Route zmx-spawned shells through Ghostty's OSC 133 shell integration.
        Self.configureShellIntegrationEnvironment()

        // Initialize Ghostty runtime
        let argc = CommandLine.argc
        let argv = CommandLine.unsafeArgv
        let result = ghostty_init(UInt(argc), argv)
        guard result == GHOSTTY_SUCCESS else {
            NSLog("Failed to initialize Ghostty: \(result)")
            return
        }

        // Create and configure config
        guard let config = ghostty_config_new() else {
            NSLog("Failed to create Ghostty config")
            return
        }
        ghostty_config_load_default_files(config)

        // Keep terminal typography consistent with the rest of Seahelm. The
        // bundled config resets any font families inherited from Ghostty's
        // global config before selecting the JetBrains Mono faces registered
        // by AppFont at launch.
        Self.loadBundledTerminalDefaults(into: config)

        // Load Seahelm-specific user overrides last so users can still adjust
        // the bundled terminal defaults (e.g. font size or copy-on-select).
        let seahelmConfigPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/seahelm/ghostty.conf").path
        if FileManager.default.fileExists(atPath: seahelmConfigPath) {
            ghostty_config_load_file(config, seahelmConfigPath)
        }

        // Dual light/dark themes last so `ghostty_*_set_color_scheme` can swap
        // palettes even when ~/.config/ghostty only names a single dark theme.
        // Prefer `theme = light:…,dark:…` in seahelm/ghostty.conf if you want a
        // custom pair — set both sides there and comment out this override later
        // if needed; for now Seahelm owns appearance-toggle correctness.
        if let dualThemePath = Self.writeDualThemeOverride() {
            ghostty_config_load_file(config, (dualThemePath as NSString).fileSystemRepresentation)
        }

        ghostty_config_finalize(config)

        // Set up runtime callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = { userData in
            guard let userData else { return }
            let bridge = Unmanaged<GhosttyBridge>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                bridge.tick()
            }
        }
        runtimeConfig.action_cb = { app, target, action in
            return GhosttyBridge.handleAction(app: app, target: target, action: action)
        }
        runtimeConfig.read_clipboard_cb = { userData, clipboard, state in
            return GhosttyBridge.readClipboard(userData: userData, clipboard: clipboard, state: state)
        }
        runtimeConfig.confirm_read_clipboard_cb = { userData, text, state, request in
            GhosttyBridge.confirmReadClipboard(userData: userData, text: text, state: state)
        }
        runtimeConfig.write_clipboard_cb = { userData, clipboard, content, contentLen, confirm in
            guard let content, contentLen > 0 else { return }
            let items = UnsafeBufferPointer(start: content, count: Int(contentLen))

            // Prefer text/plain MIME type, fall back to first item with data
            var bestText: String?
            var fallbackText: String?
            for item in items {
                guard let data = item.data else { continue }
                let str = String(cString: data)
                if let mime = item.mime {
                    if String(cString: mime) == "text/plain" {
                        bestText = str
                        break
                    }
                }
                if fallbackText == nil { fallbackText = str }
            }

            if let text = bestText ?? fallbackText {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }
        runtimeConfig.close_surface_cb = { userData, processAlive in
            NotificationCenter.default.post(name: .ghosttySurfaceCloseRequested, object: nil)
        }

        // Create the app
        guard let ghosttyApp = ghostty_app_new(&runtimeConfig, config) else {
            NSLog("Failed to create Ghostty app")
            ghostty_config_free(config)
            return
        }

        // Keep config for soft reload when the color scheme flips. libghostty
        // asks the embedder to `reload_config`; without this the palette never swaps.
        self.config = config
        self.app = ghosttyApp
        self.isInitialized = true

        // Follow the system light/dark appearance so `theme = light:...,dark:...`
        // configs switch automatically. libghostty only learns about appearance
        // changes when the host tells it.
        syncColorScheme()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.syncColorScheme() }
        }
    }

    /// The Ghostty color scheme matching the current system appearance.
    var currentColorScheme: ghostty_color_scheme_e {
        let isDark = NSApp.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    /// Matches bundled Catppuccin Mocha / Latte `background` — used for immersive
    /// terminal chrome (title strip) so it blends with the Ghostty surface.
    var terminalChromeBackground: NSColor {
        switch currentColorScheme {
        case GHOSTTY_COLOR_SCHEME_LIGHT:
            return NSColor(srgbRed: 0xef/255, green: 0xf1/255, blue: 0xf5/255, alpha: 1) // Latte
        default:
            return NSColor(srgbRed: 0x1e/255, green: 0x1e/255, blue: 0x2e/255, alpha: 1) // Mocha
        }
    }

    var terminalChromeForeground: NSColor {
        switch currentColorScheme {
        case GHOSTTY_COLOR_SCHEME_LIGHT:
            return NSColor(srgbRed: 0x4c/255, green: 0x4f/255, blue: 0x69/255, alpha: 1)
        default:
            return NSColor(srgbRed: 0xcd/255, green: 0xd6/255, blue: 0xf4/255, alpha: 1)
        }
    }

    /// Push the current app appearance to Ghostty and every live surface.
    /// Call after theme toggles so light/dark terminal palettes apply immediately.
    func refreshColorScheme() {
        syncColorScheme()
        NotificationCenter.default.post(name: .ghosttyColorSchemeDidChange, object: self)
    }

    /// Push the current system appearance to the app and every live surface.
    private func syncColorScheme() {
        guard let app else { return }
        let scheme = currentColorScheme
        // Surfaces first: `ghostty_app_update_config` fans `change_config` out to
        // every surface using each surface's own conditional state. If app-level
        // set_color_scheme runs first, that fan-out still sees the old theme.
        for station in StationRegistry.shared.allStations() {
            guard let surface = station.surface else { continue }
            station.ghosttyLock.lock()
            ghostty_surface_set_color_scheme(surface, scheme)
            station.ghosttyLock.unlock()
        }
        ghostty_app_set_color_scheme(app, scheme)
        // Explicit soft reload so a live palette swap doesn't depend solely on
        // the RELOAD_CONFIG action callback (stale ghostty.h has dropped it).
        if let config {
            ghostty_app_update_config(app, config)
        }
    }

    /// Soft-reload config so `theme = light:…,dark:…` resolves to the active scheme.
    private func reloadConfig(target: ghostty_target_s, soft: Bool) {
        guard let config else { return }
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            guard let app else { return }
            if soft {
                ghostty_app_update_config(app, config)
            } else if let rebuilt = Self.buildConfig() {
                ghostty_app_update_config(app, rebuilt)
                ghostty_config_free(config)
                self.config = rebuilt
            }
        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return }
            if soft {
                ghostty_surface_update_config(surface, config)
            } else if let rebuilt = Self.buildConfig() {
                ghostty_surface_update_config(surface, rebuilt)
                ghostty_config_free(rebuilt)
            }
        default:
            break
        }
        NotificationCenter.default.post(name: .ghosttyColorSchemeDidChange, object: self)
    }

    /// Rebuild the same config stack used at initialize (for hard reload).
    private static func buildConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        loadBundledTerminalDefaults(into: config)
        let seahelmConfigPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/seahelm/ghostty.conf").path
        if FileManager.default.fileExists(atPath: seahelmConfigPath) {
            ghostty_config_load_file(config, seahelmConfigPath)
        }
        if let dualThemePath = Self.writeDualThemeOverride() {
            ghostty_config_load_file(config, (dualThemePath as NSString).fileSystemRepresentation)
        }
        ghostty_config_finalize(config)
        return config
    }

    private static func loadBundledTerminalDefaults(into config: ghostty_config_t) {
        if let path = Bundle.main.path(forResource: "ghostty", ofType: "conf") {
            ghostty_config_load_file(config, path)
        }
    }

    /// `GHOSTTY_RESOURCES_DIR` → `Bundle/.../Resources/ghostty` (contains `themes/`).
    private static func configureResourcesEnvironment() {
        guard let dir = bundledResourcesURL()?.path,
              FileManager.default.fileExists(atPath: dir) else { return }
        setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
    }

    /// Inject Ghostty's OSC 133 shell integration into the shells zmx spawns, so
    /// command boundaries emit `COMMAND_FINISHED` (real exit code + duration).
    ///
    /// The pane process is `zmx attach`, not a shell, so libghostty's own shell
    /// integration never runs (it only wraps a shell it exec's directly). But
    /// zmx's daemon `forkpty`'s the login shell inheriting *this* process's
    /// environment, so setting `ZDOTDIR` here reaches the zsh it starts — the
    /// same ZDOTDIR trick Ghostty uses (termio/shell_integration.zig `setupZsh`).
    /// The bundled `.zshenv` restores the user's real `ZDOTDIR` from
    /// `GHOSTTY_ZSH_ZDOTDIR` and chains to their config, so this is
    /// non-destructive. Only affects zsh; bash/fish ignore `ZDOTDIR` (no-op).
    /// Existing persisted zmx sessions keep their already-running shell — the
    /// integration lands on newly created panes.
    private static func configureShellIntegrationEnvironment() {
        guard ProcessInfo.processInfo.environment["SEAHELM_DISABLE_SHELL_INTEGRATION"] == nil else { return }
        guard let dir = bundledResourcesURL()?
            .appendingPathComponent("shell-integration/zsh").path,
              FileManager.default.fileExists(atPath: dir + "/.zshenv") else { return }

        let current = ProcessInfo.processInfo.environment["ZDOTDIR"]
        // Nesting guard: Seahelm launched from inside a Seahelm pane already has
        // our ZDOTDIR — don't re-wrap (would clobber the preserved real one).
        if current == dir { return }

        if let current, !current.isEmpty {
            setenv("GHOSTTY_ZSH_ZDOTDIR", current, 1)
        }
        setenv("ZDOTDIR", dir, 1)
    }

    private static func bundledResourcesURL() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("ghostty")
    }

    /// Writes a tiny conf that pins absolute light/dark theme paths from the bundle.
    private static func writeDualThemeOverride() -> String? {
        guard let themes = bundledResourcesURL()?.appendingPathComponent("themes") else { return nil }
        let light = themes.appendingPathComponent("Catppuccin Latte").path
        let dark = themes.appendingPathComponent("Catppuccin Mocha").path
        guard FileManager.default.fileExists(atPath: light),
              FileManager.default.fileExists(atPath: dark) else {
            NSLog("Ghostty dual themes missing under %@", themes.path)
            return nil
        }
        let conf = "theme = light:\(light),dark:\(dark)\n"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-ghostty-dual-theme.conf")
        do {
            try conf.write(to: tmp, atomically: true, encoding: .utf8)
            return tmp.path
        } catch {
            NSLog("Failed to write Ghostty dual-theme override: %@", "\(error)")
            return nil
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func shutdown() {
        if let app {
            ghostty_app_free(app)
            self.app = nil
        }
        if let config {
            ghostty_config_free(config)
            self.config = nil
        }
        isInitialized = false
    }

    // MARK: - Static callback helpers

    /// Resolve the Station owning an action's target surface, if any.
    private static func station(for target: ghostty_target_s) -> Station? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return nil }
        return StationRegistry.shared.station(forSurface: surface)
    }

    private static func handleAction(app: ghostty_app_t?, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        // TEMP PROBE: verify OSC 133 injection makes command_finished auto-fire.
        if action.tag == GHOSTTY_ACTION_COMMAND_FINISHED {
            let cf = action.action.command_finished
            let line = "command_finished surface=\(station(for: target)?.id.prefix(8) ?? "?") exit=\(cf.exit_code) duration_ns=\(cf.duration)\n"
            if let d = line.data(using: .utf8) {
                let u = URL(fileURLWithPath: "/tmp/seahelm_probe.log")
                if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? d.write(to: u) }
            }
        }
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let station = station(for: target),
               let cstr = action.action.set_title.title {
                station.setOscTitle(String(cString: cstr))
            }
            return true
        case GHOSTTY_ACTION_PWD:
            if let station = station(for: target),
               let cstr = action.action.pwd.pwd {
                station.setPwd(String(cString: cstr))
            }
            return true
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            if let station = station(for: target) {
                let r = action.action.progress_report
                // Encode as ConEmu-style "state;percent" so manifest osc_progress
                // rules can match (e.g. "^4;0" = done). state 0=remove,1=set,2=error…
                let percent = r.progress < 0 ? "" : String(r.progress)
                station.setOscProgress("\(r.state.rawValue);\(percent)")
            }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            // Required for light/dark `theme = light:…,dark:…` to take effect.
            // libghostty flips conditional state then asks the embedder to reload.
            GhosttyBridge.shared.reloadConfig(target: target, soft: action.action.reload_config.soft)
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            return true
        case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS,
             GHOSTTY_ACTION_CLOSE_TAB,
             GHOSTTY_ACTION_CLOSE_WINDOW:
            return true
        case GHOSTTY_ACTION_START_SEARCH,
             GHOSTTY_ACTION_SEARCH_TOTAL,
             GHOSTTY_ACTION_SEARCH_SELECTED:
            return true
        default:
            return false
        }
    }

    private static func readClipboard(userData: UnsafeMutableRawPointer?, clipboard: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        // Called by Ghostty core when a terminal app requests clipboard content
        // (e.g., via OSC 52 or paste keybinding). Must return true if handled,
        // false otherwise — Ghostty uses this to manage the state pointer's lifetime.
        guard let view = NSApp.keyWindow?.firstResponder as? GhosttyNSView,
              let surface = view.surface else { return false }

        let pasteboard = NSPasteboard.general
        guard let str = pasteboard.string(forType: .string), !str.isEmpty else { return false }

        str.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }
        return true
    }

    private static func confirmReadClipboard(userData: UnsafeMutableRawPointer?, text: UnsafePointer<CChar>?, state: UnsafeMutableRawPointer?) {
        // Auto-confirm clipboard read requests
        guard let text,
              let view = NSApp.keyWindow?.firstResponder as? GhosttyNSView,
              let surface = view.surface else { return }

        ghostty_surface_complete_clipboard_request(surface, text, state, true)
    }

}

// MARK: - Notifications

extension Notification.Name {
    static let ghosttySurfaceCloseRequested = Notification.Name("ghosttySurfaceCloseRequested")
    static let ghosttyColorSchemeDidChange = Notification.Name("ghosttyColorSchemeDidChange")
}
