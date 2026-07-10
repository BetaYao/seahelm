import AppKit

protocol StationDelegate: AnyObject {
    /// Called when a stale session was detected and the station was recreated.
    /// The delegate should re-embed `station.view` into the appropriate container.
    func stationDidRecover(_ station: Station)
}

/// Manages a single Ghostty terminal surface (NSView + PTY + Metal renderer).
/// Each worktree gets one Station instance.
class Station {
    /// Unique identifier for this terminal instance (used as primary key in ShipLog)
    let id: String = UUID().uuidString

    /// The NSView that Ghostty renders into (layer-backed, Metal)
    private(set) var view: GhosttyNSView!
    private(set) var surface: ghostty_surface_t?
    private weak var containerView: NSView?

    /// Latest OSC signals Ghostty surfaced for this pane, fed to the detection
    /// engine's osc_title / osc_progress regions. Written from Ghostty's action
    /// callback thread, read from the status-poll thread — guarded by oscLock.
    private let oscLock = NSLock()
    private var _oscTitle = ""
    private var _oscProgress = ""
    var oscTitle: String { oscLock.lock(); defer { oscLock.unlock() }; return _oscTitle }
    var oscProgress: String { oscLock.lock(); defer { oscLock.unlock() }; return _oscProgress }
    func setOscTitle(_ t: String) { oscLock.lock(); _oscTitle = t; oscLock.unlock() }
    func setOscProgress(_ p: String) { oscLock.lock(); _oscProgress = p; oscLock.unlock() }

    /// Session name for persistence backend (nil = direct shell)
    var sessionName: String?
    /// Persistence backend for the sessionName above.
    var backend: String = "zmx"
    /// Agent resume ref, if this pane runs a recognized agent. When a *fresh*
    /// backend session must be created (restore into a missing session, or zmx
    /// recovery), the session is seeded with the agent's resume command instead
    /// of a plain shell. Populated from Config on restore and from live hook
    /// events mid-session.
    var agentSessionRef: AgentSessionRef?
    /// Delegate notified when a stale session is recovered.
    weak var delegate: StationDelegate?

    private var recoveryTimer: DispatchWorkItem?
    private static let recoveryDelay: TimeInterval = 3.0

    /// Serializes Ghostty C API access across threads.
    /// Background polling (readViewportText) and main-thread input (key/mouse)
    /// must not call into the same ghostty_surface_t concurrently.
    let ghosttyLock = NSLock()

    /// Create the terminal surface and add it to the given container view.
    /// If sessionName is provided, the surface runs inside a persistent backend session.
    func create(in container: NSView, workingDirectory: String? = nil, sessionName: String? = nil, completion: (() -> Void)? = nil) -> Bool {
        guard let app = GhosttyBridge.shared.app else {
            NSLog("GhosttyBridge not initialized")
            return false
        }

        if let sessionName {
            if backend == "zmx" {
                // If this pane runs an agent and the backend session no longer
                // exists (e.g. reboot lost the zmx daemon), seed a fresh session
                // running the agent's resume command before attaching, instead
                // of attaching into an empty shell. Seeding needs blocking
                // process calls, so defer to a background thread and attach on
                // main.
                if let resumeCmd = agentSessionRef?.resumeCommandLine(), let cwd = workingDirectory {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        ZmxSessionRecovery.seedSessionIfMissing(name: sessionName, cwd: cwd, agentCommandLine: resumeCmd)
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.attachZmx(app: app, container: container, workingDirectory: workingDirectory, sessionName: sessionName)
                            completion?()
                        }
                    }
                    return true  // Surface creation is deferred
                }
                attachZmx(app: app, container: container, workingDirectory: workingDirectory, sessionName: sessionName)
                return surface != nil
            }
        }

        _createWithCommand(app: app, container: container, workingDirectory: workingDirectory, command: nil)
        return surface != nil
    }

    /// Attach to a zmx session and schedule the post-attach health check.
    private func attachZmx(app: ghostty_app_t, container: NSView, workingDirectory: String?, sessionName: String) {
        let zmxCommand = "\(ShellEscape.singleQuote(ZmxLocator.executable())) attach \(sessionName)"
        _createWithCommand(app: app, container: container, workingDirectory: workingDirectory, command: zmxCommand)
        if surface != nil {
            scheduleZmxHealthCheck(sessionName: sessionName, container: container, workingDirectory: workingDirectory)
        }
    }

    private func _createWithCommand(app: ghostty_app_t, container: NSView, workingDirectory: String?, command: String?) {
        let termView = GhosttyNSView(frame: container.bounds)
        termView.wantsLayer = true

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(termView).toOpaque()
        config.scale_factor = Double(container.window?.backingScaleFactor ?? 2.0)

        // Use a flat closure that receives C pointers directly.
        // Pointers are only valid within the withCString scope,
        // so _createSurface must be called inside the innermost closure.
        let create = { [self] (wdPtr: UnsafePointer<CChar>?, cmdPtr: UnsafePointer<CChar>?) in
            if let wdPtr { config.working_directory = wdPtr }
            if let cmdPtr { config.command = cmdPtr }
            self._createSurface(app: app, config: &config, view: termView, container: container)
        }

        switch (workingDirectory, command) {
        case let (wd?, cmd?):
            wd.withCString { wdPtr in cmd.withCString { cmdPtr in create(wdPtr, cmdPtr) } }
        case let (wd?, nil):
            wd.withCString { wdPtr in create(wdPtr, nil) }
        case let (nil, cmd?):
            cmd.withCString { cmdPtr in create(nil, cmdPtr) }
        case (nil, nil):
            create(nil, nil)
        }
    }

    private func _createSurface(app: ghostty_app_t, config: inout ghostty_surface_config_s, view: GhosttyNSView, container: NSView) {
        guard let s = ghostty_surface_new(app, &config) else {
            NSLog("Failed to create Ghostty surface")
            return
        }
        self.surface = s
        self.view = view
        self.containerView = container
        view.surface = s
        view.station = self

        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Set initial size — Ghostty expects pixel (framebuffer) dimensions, not points
        let size = container.bounds.size
        let scale = container.window?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(s, Double(scale), Double(scale))
        ghostty_surface_set_size(s, UInt32(size.width * scale), UInt32(size.height * scale))
        ghostty_surface_set_focus(s, false)  // Start unfocused; focus set via makeFirstResponder
    }

    /// Reparent this terminal's view to a different container
    func reparent(to container: NSView) {
        guard let view, let surface else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        CATransaction.commit()

        self.containerView = container

        // Force size sync after constraints resolve — need TWO deferred
        // passes because the first run loop resolves constraints (setting frame)
        // and the second one is needed for Ghostty to recalculate the grid
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.view, let surface = self.surface else { return }
            self.syncContentScale()
            self.syncSize()
            // Restore AppKit first responder so keyboard events reach the terminal.
            // Only grab focus if no other terminal already has it (e.g. in a split pane
            // where showTerminal() already focused the correct leaf).
            if !(view.window?.firstResponder is GhosttyNSView) {
                view.window?.makeFirstResponder(view)
            }
            view.needsDisplay = true
        }
    }

    /// Sync the surface size with the current container bounds
    func syncSize() {
        guard let view else { return }
        // Reset the debounce so syncSurfaceSize() will run even if the
        // same size was already synced through setFrameSize.
        view.resetLastSyncedSize()
        view.syncSurfaceSize()
    }

    /// Sync the content scale (Retina vs non-Retina)
    func syncContentScale() {
        guard let surface, let view, let window = view.window else { return }
        let scale = Double(window.backingScaleFactor)
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    /// Check if the process has exited
    var processExited: Bool {
        // Read `surface` inside the lock: destroy() frees it under the same
        // lock, so a pointer captured before locking could dangle.
        ghosttyLock.lock()
        defer { ghosttyLock.unlock() }
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    /// Read visible terminal text from the viewport
    /// Type text into the terminal (e.g. an initial agent command). Include a
    /// trailing "\r" to run it. Mirrors the paste path's `ghostty_surface_text`.
    func sendText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    /// Send a real Return key press+release (not a `\r` via the text path). Agent
    /// TUIs (Claude Code, codex) treat a `\r` arriving through text/paste as a
    /// literal newline, but a genuine Enter key event as submit. Used to send a
    /// command after `sendText` so it actually executes.
    func sendEnterKey() {
        guard let surface else { return }
        let returnKeycode: UInt32 = 36  // macOS kVK_Return
        var press = ghostty_input_key_s()
        press.action = GHOSTTY_ACTION_PRESS
        press.keycode = returnKeycode
        press.mods = GHOSTTY_MODS_NONE
        "\r".withCString { cStr in
            press.text = cStr
            _ = ghostty_surface_key(surface, press)
        }
        var release = ghostty_input_key_s()
        release.action = GHOSTTY_ACTION_RELEASE
        release.keycode = returnKeycode
        release.mods = GHOSTTY_MODS_NONE
        _ = ghostty_surface_key(surface, release)
    }

    func readViewportText() -> String? {
        // Hold ghosttyLock only for the C calls plus a raw byte copy. Building
        // the String (UTF-8 validation + allocation over a full viewport) used
        // to happen inside the lock, stalling main-thread input that contends
        // for it during every background status poll. `surface` must be read
        // inside the lock — destroy() frees it under the same lock.
        var bytes: [UInt8]?
        ghosttyLock.lock()
        guard let surface else {
            ghosttyLock.unlock()
            return nil
        }
        let size = ghostty_surface_size(surface)
        if size.rows > 0, size.columns > 0 {
            var selection = ghostty_selection_s()
            selection.top_left = ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            )
            selection.bottom_right = ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: UInt32(size.columns - 1),
                y: UInt32(size.rows - 1)
            )
            selection.rectangle = false

            var text = ghostty_text_s()
            if ghostty_surface_read_text(surface, selection, &text) {
                if let ptr = text.text, text.text_len > 0 {
                    ptr.withMemoryRebound(to: UInt8.self, capacity: Int(text.text_len)) {
                        bytes = Array(UnsafeBufferPointer(start: $0, count: Int(text.text_len)))
                    }
                }
                ghostty_surface_free_text(surface, &text)
            }
        }
        ghosttyLock.unlock()

        guard var buf = bytes else { return nil }
        // Match String(cString:) semantics: the buffer is NUL-terminated and
        // text_len may include the terminator.
        if let nul = buf.firstIndex(of: 0) { buf.removeSubrange(nul...) }
        guard !buf.isEmpty else { return nil }
        return String(decoding: buf, as: UTF8.self)
    }

    /// True when a live ghostty surface exists. Background dashboard cards that
    /// were never opened have no surface, so `readViewportText()` returns nil and
    /// status scanning must fall back to `readBackendText()`.
    var hasLiveSurface: Bool { surface != nil }

    /// Capture the current backend session frame for status scanning when there
    /// is no live surface to read (e.g. an overview card never selected). zmx
    /// `history` includes the live rendered frame — alt-screen TUIs like Claude
    /// Code included — so the agent's status line ("esc to interrupt", prompts)
    /// is present. Returns the last `lines` rows to approximate a viewport (keeps
    /// bottom-anchored detection rules honest and bounds scrollback false matches).
    /// Runs a subprocess — call off the main thread only. Returns nil when there
    /// is a live surface (use `readViewportText()` instead) or no backend session.
    func readBackendText(lines: Int = 60) -> String? {
        guard surface == nil, backend == "zmx", let sessionName else { return nil }
        return ZmxChannel(sessionName: sessionName).readOutput(lines: lines)
    }

    /// Get the process status for status detection
    var processStatus: ProcessStatus {
        ghosttyLock.lock()
        defer { ghosttyLock.unlock() }
        guard let surface else { return .unknown }
        if ghostty_surface_process_exited(surface) {
            // We don't have the exit code from ghostty, so assume exited
            return .exited
        }
        return .running
    }

    // MARK: - Zmx Session Recovery

    /// Schedule a health check after zmx attach. If the surface has no content
    /// after the delay, the session is presumed stale — kill it and recreate.
    private func scheduleZmxHealthCheck(sessionName: String, container: NSView, workingDirectory: String?) {
        recoveryTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.checkZmxHealth(sessionName: sessionName, container: container, workingDirectory: workingDirectory)
        }
        recoveryTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recoveryDelay, execute: work)
    }

    private func checkZmxHealth(sessionName: String, container: NSView, workingDirectory: String?) {
        // If the surface was already destroyed, nothing to do.
        guard surface != nil else { return }
        guard ZmxSessionRecovery.shouldRecover(processExited: processStatus == .exited) else { return }

        NSLog("Station: zmx session '%@' attach exited — recovering", sessionName)
        recoverZmxSession(sessionName: sessionName, container: container, workingDirectory: workingDirectory)
    }

    private func recoverZmxSession(sessionName: String, container: NSView, workingDirectory: String?) {
        let resumeCmd = agentSessionRef?.resumeCommandLine()
        // 1. Kill the stale session in the background
        DispatchQueue.global(qos: .utility).async {
            ZmxSessionRecovery.forceKillSession(sessionName)

            // 1b. If this pane runs an agent, seed a fresh session with the
            // agent's resume command so recovery brings the agent back instead
            // of a bare shell.
            if let resumeCmd, let cwd = workingDirectory {
                ZmxSessionRecovery.seedSessionIfMissing(name: sessionName, cwd: cwd, agentCommandLine: resumeCmd)
            }

            // 2. Recreate on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let app = GhosttyBridge.shared.app else { return }

                // Tear down old surface
                self.destroy()

                // Recreate with a fresh zmx attach
                let zmxCommand = "\(ShellEscape.singleQuote(ZmxLocator.executable())) attach \(sessionName)"
                self._createWithCommand(app: app, container: container, workingDirectory: workingDirectory, command: zmxCommand)
                self.delegate?.stationDidRecover(self)
            }
        }
    }

    /// Destroy the surface and clean up
    func destroy() {
        recoveryTimer?.cancel()
        recoveryTimer = nil
        view?.surface = nil
        view?.removeFromSuperview()
        // Free under ghosttyLock so the background status poll can't be mid-read
        // on this surface. Freeing (not just request_close) is what tears down
        // the PTY and renderer — request_close only fires the host callback.
        ghosttyLock.lock()
        if let surface {
            ghostty_surface_free(surface)
        }
        surface = nil
        ghosttyLock.unlock()
        view = nil
        containerView = nil
    }

    deinit {
        destroy()
    }
}
