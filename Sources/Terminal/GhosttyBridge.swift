import AppKit

/// Singleton wrapper for the Ghostty application instance.
/// Manages global Ghostty lifecycle and runtime callbacks.
class GhosttyBridge {
    static let shared = GhosttyBridge()

    private(set) var app: ghostty_app_t?
    private var isInitialized = false

    private init() {}

    func initialize() {
        guard !isInitialized else { return }

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

        // Load seahelm-specific overrides (e.g. copy-on-select = false)
        let seahelmConfigPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/seahelm/ghostty.conf").path
        if FileManager.default.fileExists(atPath: seahelmConfigPath) {
            ghostty_config_load_file(config, seahelmConfigPath)
        }

        ghostty_config_finalize(config)

        // Always free config — ghostty_app_new copies what it needs
        defer { ghostty_config_free(config) }

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
            return
        }

        self.app = ghosttyApp
        self.isInitialized = true

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
        isInitialized = false
    }

    // MARK: - Static callback helpers

    /// Resolve the Station owning an action's target surface, if any.
    private static func station(for target: ghostty_target_s) -> Station? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return nil }
        return StationRegistry.shared.station(forSurface: surface)
    }

    private static func handleAction(app: ghostty_app_t?, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let station = station(for: target),
               let cstr = action.action.set_title.title {
                station.setOscTitle(String(cString: cstr))
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
}
